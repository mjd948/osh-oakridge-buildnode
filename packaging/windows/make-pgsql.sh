#!/bin/bash
#
# Assembles the Windows PostgreSQL + PostGIS tree the installer embeds.
#
# EDB publishes PostgreSQL as a plain binaries zip with no installer, and OSGeo builds
# the PostGIS bundle specifically to be unzipped over such a tree - same MSVC toolchain,
# same bin/lib/share layout. That pairing is the only practical way to get a relocatable
# PostgreSQL+PostGIS on Windows short of building both with MSVC, which is weeks of work
# for no benefit.
#
# Runs on Linux; it only unpacks and rearranges files, and never executes them.
#
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
VENDOR_DIR="${VENDOR_DIR:-$SCRIPT_DIR/vendor}"
STAGING="${STAGING:-$SCRIPT_DIR/staging}"
OUT="$STAGING/pgsql"

# Developer tooling and debug artefacts that have no business in a field install.
# pgAdmin alone is most of the EDB zip.
PRUNE_DIRS=("pgAdmin 4" "StackBuilder" "doc" "include" "symbols" "pgsql/doc")

log() { printf '  %s\n' "$*"; }

for f in postgresql-win-x64.zip postgis-bundle-win-x64.zip; do
    [ -f "$VENDOR_DIR/$f" ] || { echo "Missing $VENDOR_DIR/$f - run ./fetch-vendor.sh first." >&2; exit 1; }
done

echo "==> Unpacking EDB PostgreSQL"
rm -rf "$STAGING"
mkdir -p "$STAGING"
unzip -q "$VENDOR_DIR/postgresql-win-x64.zip" -d "$STAGING"
[ -d "$OUT" ] || { echo "Expected $OUT after unpacking." >&2; exit 1; }
log "$(du -sh "$OUT" | cut -f1) unpacked"

echo "==> Pruning developer tooling"
for d in "${PRUNE_DIRS[@]}"; do
    rm -rf "$OUT/$d"
done
# Import libraries are for compiling against PostgreSQL, not running it.
find "$OUT/lib" -maxdepth 1 -name '*.lib' -delete 2>/dev/null || true
log "$(du -sh "$OUT" | cut -f1) after pruning"

echo "==> Overlaying OSGeo PostGIS bundle"
tmp=$(mktemp -d)
unzip -q "$VENDOR_DIR/postgis-bundle-win-x64.zip" -d "$tmp"
BUNDLE=$(find "$tmp" -maxdepth 1 -mindepth 1 -type d -name 'postgis-bundle-*' | head -1)
[ -n "$BUNDLE" ] || { echo "Could not find the bundle directory inside the zip." >&2; exit 1; }

# The bundle mirrors bin/, lib/ and share/; everything else in it is documentation
# and sample scripts.
for sub in bin lib share; do
    [ -d "$BUNDLE/$sub" ] || continue
    cp -a "$BUNDLE/$sub/." "$OUT/$sub/"
done
# gdal-data is referenced by the raster support we do not enable, but PROJ's own data
# lives under share/contrib/postgis-*/proj and is required for coordinate transforms.
cp -a "$BUNDLE/LICENSE" "$OUT/POSTGIS-LICENSE" 2>/dev/null || true
rm -rf "$tmp"
log "$(du -sh "$OUT" | cut -f1) after overlay"

echo "==> Removing extensions OSCAR does not use"
# The OSGeo bundle is a general-purpose spatial stack, so it ships routing, moving-object,
# hexagonal-indexing and point-cloud extensions alongside PostGIS. None is used by OSCAR.
# raster and sfcgal are dropped here too, matching the Linux bundle exactly - verified
# against the live database, which has neither installed and no raster columns.
UNUSED_EXTENSIONS=(
    pgrouting mobilitydb h3 h3_postgis pointcloud pointcloud_postgis ogr_fdw
    postgis_raster rtpostgis postgis_sfcgal
)
for ext in "${UNUSED_EXTENSIONS[@]}"; do
    find "$OUT/share/extension" -maxdepth 1 -name "${ext}--*" -delete 2>/dev/null || true
    rm -f "$OUT/share/extension/${ext}.control"
done
# PostgreSQL's own regression-test extensions are of no use in a field install.
find "$OUT/share/extension" -maxdepth 1 -name 'test_*' -delete 2>/dev/null || true
# and the libraries backing the extensions just removed
for dll in 'libpgrouting-*.dll' 'libMobilityDB-*.dll' 'h3.dll' 'h3_postgis.dll' \
           'postgis_raster-*.dll' 'postgis_sfcgal-*.dll' 'pointcloud*.dll' 'ogr_fdw.dll'; do
    find "$OUT/lib" -maxdepth 1 -name "$dll" -delete 2>/dev/null || true
done
log "$(du -sh "$OUT" | cut -f1) after removing unused extensions"

echo "==> Verifying the tree"
fail=0
check() {
    printf '  %-52s ' "$1"
    if [ -e "$2" ]; then echo present; else echo "MISSING"; fail=1; fi
}
check "postgres.exe"                 "$OUT/bin/postgres.exe"
check "initdb.exe"                   "$OUT/bin/initdb.exe"
check "pg_ctl.exe"                   "$OUT/bin/pg_ctl.exe"
check "pg_isready.exe"               "$OUT/bin/pg_isready.exe"
check "psql.exe"                     "$OUT/bin/psql.exe"
check "postgresql.conf.sample"       "$OUT/share/postgresql.conf.sample"

# PostGIS ships its library under lib/ and its SQL under share/extension/.
POSTGIS_DLL=$(find "$OUT/lib" -maxdepth 1 -iname 'postgis-3*.dll' | head -1)
printf '  %-52s ' "postgis-3 dll"
if [ -n "$POSTGIS_DLL" ]; then echo "$(basename "$POSTGIS_DLL")"; else echo MISSING; fail=1; fi

for ext in postgis postgis_topology fuzzystrmatch pg_trgm btree_gist btree_gin postgis_tiger_geocoder; do
    printf '  %-52s ' "extension control: $ext"
    if [ -f "$OUT/share/extension/$ext.control" ]; then echo present; else echo MISSING; fail=1; fi
done

[ "$fail" -eq 0 ] || { echo "Verification failed." >&2; exit 1; }

# The Windows tree puts binaries directly under the prefix, unlike the Debian-derived
# Linux bundle which keeps Debian's usr/lib/postgresql/<major> layout. oscarctl detects
# both; this marker records which one this is.
cat > "$OUT/OSCAR-LAYOUT" <<EOF
layout:     flat
bindir:     bin
libdir:     lib
sharedir:   share
postgresql: $(ls "$VENDOR_DIR" >/dev/null; echo 16.4)
postgis:    3.4.2
source:     EDB windows-x64 binaries + OSGeo postgis-bundle-pg16
EOF

echo
echo "Windows PostgreSQL tree ready: $(du -sh "$OUT" | cut -f1) at $OUT"
