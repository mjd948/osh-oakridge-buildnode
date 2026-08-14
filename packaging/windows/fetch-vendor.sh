#!/bin/bash
#
# Downloads and checksum-pins the third-party binaries the Windows installer embeds.
#
# Run once on a machine with network access; the artifacts are then build inputs and
# the resulting installer needs no network at install time. Nothing fetched here is
# committed to git - it is ~450 MB of third-party binaries with their own licences.
#
#   ./fetch-vendor.sh            # download, verify against vendor.lock
#   ./fetch-vendor.sh --update   # download and rewrite vendor.lock with new hashes
#
# Version choices, and why:
#
#   PostgreSQL 16.4   EDB publishes a plain binaries zip with no installer, which is
#                     the only practical relocatable PostgreSQL for Windows. 16.4
#                     matches the Linux bundle exactly.
#   PostGIS 3.4.2     The OSGeo bundle is built to be unzipped over an EDB tree.
#                     3.4.3 exists on Linux but was never published for Windows, so
#                     the platforms differ by a patch release within the same minor;
#                     the extension version and on-disk format are identical.
#   WinSW 2.12.0      The current stable line, and WinSW-x64.exe from it is already a
#                     self-contained .NET 6 build - verified by inspecting the binary,
#                     which embeds .NETCoreApp,Version=v6.0 and System.Private.CoreLib
#                     and references no .NETFramework version. So there is no framework
#                     prerequisite to preflight, and no reason to reach for the v3
#                     alpha to get one. The 18 MB is the embedded runtime.
#   Temurin 21 JRE    Matches the Java the node is built and tested against.
#
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
VENDOR_DIR="${VENDOR_DIR:-$SCRIPT_DIR/vendor}"
LOCKFILE="$SCRIPT_DIR/vendor.lock"
UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1

PG_VERSION=16.4-1
POSTGIS_BUNDLE=postgis-bundle-pg16-3.4.2x64
WINSW_VERSION=v2.12.0
JRE_FEATURE=21

declare -A URLS=(
    [postgresql-win-x64.zip]="https://get.enterprisedb.com/postgresql/postgresql-${PG_VERSION}-windows-x64-binaries.zip"
    [postgis-bundle-win-x64.zip]="https://download.osgeo.org/postgis/windows/pg16/archive/${POSTGIS_BUNDLE}.zip"
    [winsw-x64.exe]="https://github.com/winsw/winsw/releases/download/${WINSW_VERSION}/WinSW-x64.exe"
)

mkdir -p "$VENDOR_DIR"

# Adoptium's download URL embeds the exact build number, so resolve it via the API
# rather than guessing, then pin the result.
resolve_jre_url() {
    # The response lists the .msi installer before the .zip archive, and formats the
    # JSON with a space after the colon. Match the archive explicitly.
    curl -sSL --max-time 60 \
        "https://api.adoptium.net/v3/assets/latest/${JRE_FEATURE}/hotspot?os=windows&architecture=x64&image_type=jre" \
        | grep -oE '"link"[[:space:]]*:[[:space:]]*"[^"]*\.zip"' \
        | head -1 \
        | sed -E 's/.*"link"[[:space:]]*:[[:space:]]*"//; s/"$//'
}

echo "==> Resolving Temurin ${JRE_FEATURE} JRE for Windows x64"
JRE_URL=$(resolve_jre_url)
[ -n "$JRE_URL" ] || { echo "Could not resolve a JRE download URL from the Adoptium API." >&2; exit 1; }
URLS[jre-win-x64.zip]="$JRE_URL"
echo "    $JRE_URL"

echo "==> Downloading into $VENDOR_DIR"
for name in "${!URLS[@]}"; do
    target="$VENDOR_DIR/$name"
    if [ -f "$target" ]; then
        echo "    $name (already present, $(du -h "$target" | cut -f1))"
        continue
    fi
    echo "    $name ..."
    curl -sSL --fail --max-time 1800 -o "$target.part" "${URLS[$name]}"
    mv "$target.part" "$target"
    echo "      $(du -h "$target" | cut -f1)"
done

echo "==> Verifying checksums"
if [ "$UPDATE" -eq 1 ] || [ ! -f "$LOCKFILE" ]; then
    {
        echo "# Pinned third-party build inputs for the OSCAR Windows installer."
        echo "# Regenerate with ./fetch-vendor.sh --update"
        echo "# postgresql=$PG_VERSION postgis=$POSTGIS_BUNDLE winsw=$WINSW_VERSION"
        echo "# jre=$JRE_URL"
        for name in $(printf '%s\n' "${!URLS[@]}" | sort); do
            printf '%s  %s\n' "$(sha256sum "$VENDOR_DIR/$name" | cut -d' ' -f1)" "$name"
        done
    } > "$LOCKFILE"
    echo "    wrote $LOCKFILE"
    sed 's/^/      /' "$LOCKFILE"
else
    fail=0
    while read -r expected name; do
        case "$expected" in '#'*|'') continue ;; esac
        actual=$(sha256sum "$VENDOR_DIR/$name" 2>/dev/null | cut -d' ' -f1)
        if [ "$actual" != "$expected" ]; then
            echo "    MISMATCH $name" >&2
            echo "      expected $expected" >&2
            echo "      actual   ${actual:-<missing>}" >&2
            fail=1
        else
            echo "    ok $name"
        fi
    done < "$LOCKFILE"
    [ "$fail" -eq 0 ] || { echo "Checksum verification failed." >&2; exit 1; }
fi

echo
echo "Vendored inputs ready: $(du -sh "$VENDOR_DIR" | cut -f1)"
