#!/bin/bash
#
# Produces a relocatable PostgreSQL + PostGIS tree that OSCAR can ship and run
# without Docker and without a system PostgreSQL install.
#
# Runs INSIDE the builder container (see Dockerfile). Do not run on a host.
#
# Layout note: Debian splits PostgreSQL across /usr/lib/postgresql/$PG_MAJOR/{bin,lib}
# and /usr/share/postgresql/$PG_MAJOR. PostgreSQL locates its share directory at
# runtime with make_relative_path(), which reproduces the *configured* bin->share
# relationship starting from the real path of the running binary. Preserving the
# "usr/..." shape inside the bundle is therefore not cosmetic: it is what makes
# relocation work at all. Flattening this tree breaks initdb.
#
set -euo pipefail

PG_MAJOR="${PG_MAJOR:-16}"
OUT="${OUT:-/out}"
PREFIX="$OUT/pgsql"
PRIVATE_LIB="$PREFIX/usr/lib/oscar-private"

SRC_BIN="/usr/lib/postgresql/$PG_MAJOR/bin"
SRC_LIB="/usr/lib/postgresql/$PG_MAJOR/lib"
SRC_SHARE="/usr/share/postgresql/$PG_MAJOR"

# Binaries OSCAR actually needs: run the server, initialise a cluster, check
# readiness, apply SQL, and take/restore backups. The rest of Debian's bin
# directory is developer tooling.
KEEP_BINS=(
    postgres initdb pg_ctl pg_isready psql
    pg_dump pg_dumpall pg_restore createdb vacuumdb
    pg_controldata pg_resetwal
)

# Excluded from pkglibdir. These are the only large native dependencies in the
# tree, and none of them is used by OSCAR - verified against the live database,
# whose pg_extension holds only btree_gin, btree_gist, fuzzystrmatch, pg_trgm,
# plpgsql, postgis, postgis_tiger_geocoder and postgis_topology.
#   llvmjit         -> pulls libLLVM (95 MB) + libz3 (22 MB); JIT is disabled anyway
#   postgis_raster  -> pulls libgdal, libspatialite, libx265, libaom (~50 MB)
#   postgis_sfcgal  -> pulls libSFCGAL + CGAL (~10 MB)
EXCLUDE_LIB_PATTERNS=(
    'llvmjit*'
    'postgis_raster*'
    'postgis_sfcgal*'
)

# Libraries that must come from the host. Mixing a bundled libc with the host's
# dynamic loader is the classic way to produce an unrunnable tarball, so the
# glibc core stays external and sets our minimum-glibc floor instead.
HOST_LIB_ALLOWLIST='^(ld-linux.*|libc|libm|libdl|libpthread|librt|libresolv|libutil|libnsl|libnss_.*|libanl)\.so'

log() { printf '  %s\n' "$*"; }

rm -rf "$PREFIX"
mkdir -p "$PREFIX/usr/lib/postgresql/$PG_MAJOR/bin" \
         "$PREFIX/usr/lib/postgresql/$PG_MAJOR/lib" \
         "$PREFIX/usr/share/postgresql" \
         "$PRIVATE_LIB"

echo "==> Copying binaries"
for b in "${KEEP_BINS[@]}"; do
    if [ -f "$SRC_BIN/$b" ]; then
        cp -a "$SRC_BIN/$b" "$PREFIX/usr/lib/postgresql/$PG_MAJOR/bin/"
    else
        echo "ERROR: expected binary $SRC_BIN/$b not found" >&2
        exit 1
    fi
done
log "$(ls "$PREFIX/usr/lib/postgresql/$PG_MAJOR/bin" | wc -l) binaries"

echo "==> Copying extension libraries"
find_args=()
for pat in "${EXCLUDE_LIB_PATTERNS[@]}"; do
    find_args+=( -not -name "$pat" )
done
find "$SRC_LIB" -maxdepth 1 -type f "${find_args[@]}" -exec cp -a {} "$PREFIX/usr/lib/postgresql/$PG_MAJOR/lib/" \;
# bitcode directory belongs to the JIT we just dropped
rm -rf "$PREFIX/usr/lib/postgresql/$PG_MAJOR/lib/bitcode"
log "$(find "$PREFIX/usr/lib/postgresql/$PG_MAJOR/lib" -type f | wc -l) library files"

echo "==> Copying share directory (extension SQL, timezone data, initdb templates)"
cp -a "$SRC_SHARE" "$PREFIX/usr/share/postgresql/$PG_MAJOR"
# Debian keeps postgresql.conf.sample one level up and symlinks it into the
# versioned directory, so copying only .../16 leaves initdb with a dangling link
# and "file postgresql.conf.sample does not exist". Bring the parent files along.
find "$(dirname "$SRC_SHARE")" -maxdepth 1 -type f -exec cp -a {} "$PREFIX/usr/share/postgresql/" \;

echo "==> Flattening absolute symlinks"
# Debian registers the extension control files through the alternatives system, so
# e.g. postgis.control is a symlink into /etc/alternatives. That directory does not
# exist on a target machine, so every such link would dangle and CREATE EXTENSION
# would report the extension as simply "not available". Replace them with real files.
flattened=0
while IFS= read -r link; do
    [ -n "$link" ] || continue
    target=$(readlink -f "$link" 2>/dev/null || true)
    if [ -z "$target" ] || [ ! -e "$target" ]; then
        echo "ERROR: cannot resolve $link -> $(readlink "$link")" >&2
        exit 1
    fi
    rm -f "$link"
    cp -aL "$target" "$link"
    flattened=$((flattened + 1))
done < <(find "$PREFIX" -type l -lname '/*')
log "$flattened absolute symlinks replaced with their targets"

echo "==> Dropping share files for excluded extensions"
# Their libraries are not in the bundle, so leaving the SQL and control files behind
# would advertise extensions that cannot actually load.
for ext in postgis_raster postgis_sfcgal; do
    find "$PREFIX/usr/share/postgresql/$PG_MAJOR/extension" -name "${ext}*" -delete 2>/dev/null || true
done
log "removed postgis_raster and postgis_sfcgal definitions"

echo "==> Resolving shared-library closure"
# Iterate to a fixed point: a dependency's own dependencies must come along too.
collect_deps() {
    local f
    while read -r f; do
        ldd "$f" 2>/dev/null | awk '/=> \//{print $3} /^\t\/lib/{print $1}'
    done | sort -u
}

: > /tmp/closure.txt
mapfile -t roots < <(
    find "$PREFIX/usr/lib/postgresql/$PG_MAJOR/bin" -type f
    find "$PREFIX/usr/lib/postgresql/$PG_MAJOR/lib" -type f -name '*.so'
)
printf '%s\n' "${roots[@]}" > /tmp/frontier.txt

while [ -s /tmp/frontier.txt ]; do
    collect_deps < /tmp/frontier.txt > /tmp/deps.txt || true
    : > /tmp/next.txt
    while read -r dep; do
        [ -n "$dep" ] || continue
        base=$(basename "$dep")
        # Skip the glibc core; it stays on the host.
        if echo "$base" | grep -Eq "$HOST_LIB_ALLOWLIST"; then continue; fi
        if grep -qxF "$dep" /tmp/closure.txt 2>/dev/null; then continue; fi
        echo "$dep" >> /tmp/closure.txt
        echo "$dep" >> /tmp/next.txt
    done < /tmp/deps.txt
    mv /tmp/next.txt /tmp/frontier.txt
done

while read -r lib; do
    [ -n "$lib" ] || continue
    cp -aL "$lib" "$PRIVATE_LIB/" 2>/dev/null || true
done < /tmp/closure.txt
log "$(find "$PRIVATE_LIB" -type f | wc -l) private libraries, $(du -sh "$PRIVATE_LIB" | cut -f1)"

echo "==> Rewriting RPATHs"
# bin/ and lib/ sit at the same depth (usr/lib/postgresql/$PG_MAJOR/{bin,lib}),
# so both reach the private lib dir by the same relative path.
for f in "$PREFIX/usr/lib/postgresql/$PG_MAJOR/bin"/* \
         "$PREFIX/usr/lib/postgresql/$PG_MAJOR/lib"/*.so; do
    [ -f "$f" ] || continue
    patchelf --set-rpath '$ORIGIN/../../../oscar-private' "$f" 2>/dev/null || true
done
for f in "$PRIVATE_LIB"/*; do
    [ -f "$f" ] || continue
    patchelf --set-rpath '$ORIGIN' "$f" 2>/dev/null || true
done

echo "==> Verifying every dependency resolves inside the bundle"
fail=0
for f in "$PREFIX/usr/lib/postgresql/$PG_MAJOR/bin"/* \
         "$PREFIX/usr/lib/postgresql/$PG_MAJOR/lib"/*.so \
         "$PRIVATE_LIB"/*; do
    [ -f "$f" ] || continue
    file "$f" | grep -q ELF || continue
    while read -r name arrow path rest; do
        case "$name" in linux-vdso.so*|/*) continue ;; esac
        if [ "$arrow" != "=>" ]; then continue; fi
        if [ "$path" = "not" ]; then
            echo "  UNRESOLVED: $(basename "$f") needs $name" >&2
            fail=1
            continue
        fi
        # Anything outside the bundle must be on the glibc allowlist.
        case "$path" in
            "$PREFIX"/*) : ;;
            *) if ! echo "$name" | grep -Eq "$HOST_LIB_ALLOWLIST"; then
                   echo "  ESCAPES BUNDLE: $(basename "$f") -> $name ($path)" >&2
                   fail=1
               fi ;;
        esac
    done < <(ldd "$f" 2>/dev/null)
done
[ "$fail" -eq 0 ] || { echo "Verification failed." >&2; exit 1; }
log "all dependencies resolve inside the bundle or against the glibc core"

echo "==> Verifying no symlink dangles"
# A dangling symlink is invisible to `ls` but fatal at runtime, and the tree carries
# ~700 of them (PostGIS templated upgrade scripts, Debian's config samples).
dangling=$(find "$PREFIX" -xtype l -printf '%p -> %l\n' || true)
if [ -n "$dangling" ]; then
    echo "$dangling" | sed 's/^/  DANGLING: /' >&2
    echo "Verification failed: bundle contains dangling symlinks." >&2
    exit 1
fi
log "$(find "$PREFIX" -type l | wc -l) symlinks, all resolving inside the bundle"

echo "==> Verifying nothing points outside the bundle by absolute path"
abs=$(find "$PREFIX" -type l -lname '/*' -printf '%p -> %l\n' || true)
if [ -n "$abs" ]; then
    echo "$abs" | sed 's/^/  ABSOLUTE: /' >&2
    echo "Verification failed: absolute symlinks will not survive relocation." >&2
    exit 1
fi
log "no absolute symlinks"

echo "==> Recording provenance"
GLIBC_VER=$(ldd --version | head -1 | awk '{print $NF}')
# `postgres --version` prints e.g. "postgres (PostgreSQL) 16.4 (Debian 16.4-1.pgdg110+2)".
# Field 3 is the upstream version; the rest is packaging detail that has no business
# in a file name.
PG_VER_FULL=$("$PREFIX/usr/lib/postgresql/$PG_MAJOR/bin/postgres" --version 2>/dev/null || echo unknown)
PG_VER=$(echo "$PG_VER_FULL" | awk '{print $3}')
[ -n "$PG_VER" ] || PG_VER="$PG_MAJOR"
POSTGIS_VER=$(echo "${POSTGIS_VERSION:-unknown}" | sed 's/[+].*//')
cat > "$PREFIX/MANIFEST" <<EOF
bundle:          oscar embedded postgresql
postgresql:      $PG_VER
postgresql_full: $PG_VER_FULL
pg_major:        $PG_MAJOR
postgis:         ${POSTGIS_VERSION:-unknown}
built_from:      ${BASE_IMAGE:-unknown}
build_glibc:     $GLIBC_VER
minimum_glibc:   $GLIBC_VER
excluded:        llvmjit (JIT), postgis_raster, postgis_sfcgal
binaries:        ${KEEP_BINS[*]}
EOF
cat "$PREFIX/MANIFEST"

echo "==> Packaging"
TARBALL="$OUT/postgres-${PG_VER}-postgis-${POSTGIS_VER}-linux-x64.tar.gz"
tar -C "$OUT" -czf "$TARBALL" pgsql
( cd "$OUT" && sha256sum "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256" )
log "$(du -sh "$TARBALL" | cut -f1)  $(basename "$TARBALL")"
log "uncompressed: $(du -sh "$PREFIX" | cut -f1)"
echo "Done."
