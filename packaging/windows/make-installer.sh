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

if ! docker start -a "$CID" | tail -3; then
    echo "Inno Setup compilation failed." >&2
    exit 1
fi

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
echo "Checksum:  $(cat "$INSTALLER.sha256" | cut -d' ' -f1)"
echo
echo "It is unsigned, so SmartScreen will warn on first run until a code-signing"
echo "certificate is procured and SignTool is configured in oscar.iss."
