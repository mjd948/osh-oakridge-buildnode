#!/bin/bash
#
# Stages a Docker-free OSCAR install (node jars + embedded PostgreSQL bundle) and
# exercises oscarctl against it in a clean container.
#
# The container image supplies a JRE only. Bundling the JRE is Phase 2; until then
# the test uses eclipse-temurin, which still has no PostgreSQL and no Docker.
#
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
TEST_IMAGE="${TEST_IMAGE:-eclipse-temurin:21-jre}"
STAGE="${STAGE:-/tmp/oscar-stage}"

DIST_ZIP=$(ls "$REPO_ROOT"/build/distributions/oscar-*.zip 2>/dev/null | head -1 || true)
BUNDLE=$(ls "$REPO_ROOT"/packaging/postgres-dist/out/postgres-*-linux-x64.tar.gz 2>/dev/null | head -1 || true)

[ -n "$DIST_ZIP" ] || { echo "No distribution zip - run ./gradlew relDistZip first." >&2; exit 1; }
[ -n "$BUNDLE" ]   || { echo "No postgres bundle - run packaging/postgres-dist/make-bundle.sh first." >&2; exit 1; }

echo "==> Staging install tree at $STAGE"
rm -rf "$STAGE"
mkdir -p "$STAGE/opt/oscar"

# Node jars. Only lib/ is needed to exercise oscarctl.
tmp=$(mktemp -d)
unzip -q "$DIST_ZIP" -d "$tmp"
NODE_DIR=$(find "$tmp" -maxdepth 2 -type d -name osh-node-oscar | head -1)
cp -a "$NODE_DIR/lib" "$STAGE/opt/oscar/lib"
cp -a "$NODE_DIR/config.json" "$STAGE/opt/oscar/config.template.json"
rm -rf "$tmp"

# Embedded PostgreSQL.
tar -xzf "$BUNDLE" -C "$STAGE/opt/oscar"

# Launcher wrappers, exactly as the installer lays them down.
cp -a "$REPO_ROOT/packaging/linux/bin" "$STAGE/opt/oscar/bin"
chmod +x "$STAGE/opt/oscar/bin/"*

echo "    lib/:   $(ls "$STAGE/opt/oscar/lib" | wc -l) jars"
echo "    pgsql/: $(du -sh "$STAGE/opt/oscar/pgsql" | cut -f1)"

echo "==> Running oscarctl on $TEST_IMAGE"
docker run --rm \
    -v "$STAGE/opt/oscar:/opt/oscar" \
    -v "$SCRIPT_DIR/test-oscarctl-inside.sh:/tmp/test-inside.sh:ro" \
    "$TEST_IMAGE" \
    bash /tmp/test-inside.sh
