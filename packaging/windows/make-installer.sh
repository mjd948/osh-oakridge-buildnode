#!/bin/bash
#
# Compiles the OSCAR Windows installer from the staged tree.
#
# Inno Setup's compiler is Windows-only, so it runs under wine in a container. That is
# a build-time convenience only - the resulting installer is an ordinary Windows
# executable with no dependency on any of this.
#
# Prerequisites:
#   ./fetch-vendor.sh                        third-party binaries, checksum-pinned
#   ./make-pgsql.sh                          PostgreSQL + PostGIS tree
#   ./make-client.sh                         Electron desktop client
#   ../../gradlew installWinX64Dist          staged payload
#
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
STAGED="${STAGED:-$REPO_ROOT/build/install/oscar-win-x64}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/output}"
ISCC_IMAGE="${ISCC_IMAGE:-amake/innosetup:latest}"
VERSION=$(cat "$STAGED/VERSION" 2>/dev/null | tr -d '[:space:]' || echo 0.0.0)

[ -d "$STAGED" ] || { echo "No staged tree at $STAGED - run ./gradlew installWinX64Dist first." >&2; exit 1; }
# Fails in a second rather than after a twenty-minute compile, and names the cause. The
# staged tree is checked rather than trusted because a tree with no client/ still looks
# entirely plausible - that is how the 3.6.0-rc.1 installer shipped without one.
[ -f "$STAGED/client/OSCAR.exe" ] || {
    echo "Staged tree has no desktop client at $STAGED/client/OSCAR.exe." >&2
    echo "Run ./make-client.sh, then ../../gradlew installWinX64Dist." >&2
    exit 1
}
command -v docker >/dev/null 2>&1 || { echo "docker is required to run the Inno Setup compiler." >&2; exit 1; }

echo "==> Compiling OSCARSetup-$VERSION-x64.exe from $STAGED ($(du -sh "$STAGED" | cut -f1))"

mkdir -p "$OUTPUT_DIR"

# Build to a path inside the container. Writing directly to a bind mount fails under
# wine with "Access denied" while it shuffles its temporary files.
CID=$(docker create \
    -v "$STAGED:/work/staged:ro" \
    -v "$SCRIPT_DIR:/work/pkg" \
    -w /work/pkg \
    "$ISCC_IMAGE" \
    oscar.iss \
    "/DSourceDir=..\\..\\work\\staged" \
    "/DAppVersion=$VERSION" \
    "/DOutputDir=C:\\out")

cleanup() { docker rm -f "$CID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

ISCC_LOG="$OUTPUT_DIR/iscc.log"
if ! docker start -a "$CID" > "$ISCC_LOG" 2>&1; then
    tail -20 "$ISCC_LOG" >&2
    echo "Inno Setup compilation failed - full log at $ISCC_LOG" >&2
    exit 1
fi
tail -3 "$ISCC_LOG"

# ISCC logs a line per file it packs, so this is a direct assertion about the artefact
# rather than about its inputs - the check that no amount of staging can fool.
grep -qi 'client.OSCAR\.exe' "$ISCC_LOG" || {
    echo "The compile log shows no client payload was packed - see $ISCC_LOG." >&2
    exit 1
}

# The wine prefix location varies between image versions, so find the artefact rather
# than hard-coding a path.
echo "==> Extracting the installer"
FOUND=0
for prefix in /home/xclient/.wine /wine /root/.wine; do
    if docker cp "$CID:$prefix/drive_c/out/." "$OUTPUT_DIR/" 2>/dev/null; then
        FOUND=1
        break
    fi
done
[ "$FOUND" -eq 1 ] || { echo "Could not locate the compiled installer inside the container." >&2; exit 1; }

INSTALLER=$(ls "$OUTPUT_DIR"/OSCARSetup-*.exe 2>/dev/null | head -1)
[ -n "$INSTALLER" ] || { echo "No installer produced." >&2; exit 1; }

( cd "$OUTPUT_DIR" && sha256sum "$(basename "$INSTALLER")" > "$(basename "$INSTALLER").sha256" )

echo
echo "Installer: $INSTALLER ($(du -h "$INSTALLER" | cut -f1))"
echo "Client:    $(cat "$STAGED/client/VERSION" 2>/dev/null || echo unknown)"
echo "Checksum:  $(cat "$INSTALLER.sha256" | cut -d' ' -f1)"
echo
echo "It is unsigned, so SmartScreen will warn on first run until a code-signing"
echo "certificate is procured and SignTool is configured in oscar.iss."
