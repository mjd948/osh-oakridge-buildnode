#!/bin/bash
#
# Builds the Windows desktop client the installer embeds.
#
# electron-builder's Windows targets need wine, which this build node does not have on
# the host, so it runs in the container image electron-builder itself publishes for the
# purpose - the same arrangement make-installer.sh uses for the Inno Setup compiler.
#
# The output is the unpacked application tree, not an installer: oscar.iss lays the
# client down as a component of OSCARSetup-<version>-x64.exe, so electron-builder's own
# NSIS target would be a second installer for the same product.
#
# Prerequisites:
#   npm --prefix ../../web/oscar-viewer run build     the exported viewer
#
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
STAGING="${STAGING:-$SCRIPT_DIR/staging}"
OUT="$STAGING/client"
BUILDER_IMAGE="${BUILDER_IMAGE:-electronuserland/builder:wine}"
UNPACKED="$REPO_ROOT/electron/dist/win-unpacked"

log() { printf '  %s\n' "$*"; }

[ -d "$REPO_ROOT/web/oscar-viewer/web" ] || {
    echo "No exported viewer at web/oscar-viewer/web - run 'npm --prefix web/oscar-viewer run build' first." >&2
    exit 1
}
command -v docker >/dev/null 2>&1 || { echo "docker is required to run electron-builder for Windows." >&2; exit 1; }

VERSION=$(node -p "require('$REPO_ROOT/electron/package.json').version")

# Delete the previous tree before building rather than after. electron-builder leaves
# win-unpacked in place when it fails partway, and a stale tree that still looks
# plausible is exactly how a 3.5.0 client would end up inside a 3.6.0 installer.
echo "==> Building the Windows client $VERSION"
rm -rf "$OUT" "$UNPACKED"

# The electron and electron-builder caches are bind-mounted so a rebuild does not
# re-download the ~110 MB Electron binary. node_modules is deliberately NOT reinstalled
# inside the container: it is shared with the host, whose binaries are native.
docker run --rm \
    -v "$REPO_ROOT:/project" \
    -v "${HOME}/.cache/electron:/root/.cache/electron" \
    -v "${HOME}/.cache/electron-builder:/root/.cache/electron-builder" \
    -w /project/electron \
    "$BUILDER_IMAGE" \
    npx electron-builder --win --x64 --publish never

[ -d "$UNPACKED" ] || { echo "electron-builder produced no $UNPACKED." >&2; exit 1; }

echo "==> Staging"
mkdir -p "$STAGING"
cp -a "$UNPACKED/." "$OUT/"

# ISCC runs as an unprivileged user inside the compiler container against a read-only
# bind mount. Modes without the world-read bit make wine abort partway through packing
# with "Access denied" - the same hazard the JRE spec in build.gradle guards against.
chmod -R a+rX "$OUT"

# Recorded so the staging step can refuse a client that does not match the release being
# built, which no version check covered before: checkVersions validates the sources, not
# the artefact.
printf '%s\n' "$VERSION" > "$OUT/VERSION"

echo "==> Verifying the tree"
fail=0
check() {
    printf '  %-52s ' "$1"
    if [ -e "$2" ]; then echo present; else echo MISSING; fail=1; fi
}
check "client executable"        "$OUT/OSCAR.exe"
check "application bundle"       "$OUT/resources/app.asar"
check "exported viewer"          "$OUT/resources/web/index.html"
check "runtime config placeholder" "$OUT/resources/web/oscar-config.json"

# The asar header lists the packaged files in plaintext at the head of the archive.
# proxy.js is what makes the client serve the viewer and the API from one origin; a
# bundle without it is a pre-3.6 build that would reintroduce the cross-origin problem.
printf '  %-52s ' "same-origin proxy in bundle"
if head -c 4096 "$OUT/resources/app.asar" | strings | grep -q 'proxy\.js'; then
    echo present
else
    echo MISSING
    fail=1
fi

[ "$fail" -eq 0 ] || { echo "Verification failed." >&2; exit 1; }

echo
echo "Windows client ready: $(du -sh "$OUT" | cut -f1) at $OUT"
