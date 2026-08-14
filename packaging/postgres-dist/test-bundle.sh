#!/bin/bash
#
# Proves the bundle is genuinely relocatable and genuinely Docker-free:
#
#   * unpacked to a path that is NOT the one it was built at
#   * on a different distribution, with a NEWER glibc than the build base
#   * in an image with no PostgreSQL, no PostGIS and no OSCAR installed
#   * running as a non-root user, because postgres refuses to run as root
#
# Docker is used here only to supply a clean machine to test on. Nothing in the
# bundle depends on it. The actual test body lives in test-inside.sh.
#
#   ./test-bundle.sh                        # Rocky 9 (RPM distro, glibc 2.34)
#   TEST_IMAGE=debian:12 ./test-bundle.sh   # Debian 12 (glibc 2.36)
#
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
TEST_IMAGE="${TEST_IMAGE:-rockylinux:9}"
BUNDLE=$(ls "$SCRIPT_DIR"/out/postgres-*-linux-x64.tar.gz 2>/dev/null | head -1 || true)
INIT_SQL="$REPO_ROOT/dist/release/postgis/init-extensions.sql"

[ -n "$BUNDLE" ] || { echo "No bundle in $SCRIPT_DIR/out - run make-bundle.sh first." >&2; exit 1; }
[ -f "$INIT_SQL" ] || { echo "Missing $INIT_SQL" >&2; exit 1; }

echo "==> Testing $(basename "$BUNDLE") on $TEST_IMAGE"

docker run --rm \
    -v "$BUNDLE:/tmp/bundle.tar.gz:ro" \
    -v "$INIT_SQL:/tmp/init-extensions.sql:ro" \
    -v "$SCRIPT_DIR/test-inside.sh:/tmp/test-inside.sh:ro" \
    "$TEST_IMAGE" \
    bash /tmp/test-inside.sh
