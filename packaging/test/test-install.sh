#!/bin/bash
#
# Installs the Linux distribution tarball in a clean container and drives the whole
# stack: embedded PostgreSQL, oscarctl bootstrap, the real OSH node and its API.
#
# The container image provides a JRE and curl only. Bundling the JRE is Phase 2.
#
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
TEST_IMAGE="${TEST_IMAGE:-eclipse-temurin:21-jre}"

TARBALL=$(ls "$REPO_ROOT"/build/distributions/oscar-linux-x64-*.tar.gz 2>/dev/null | head -1 || true)
[ -n "$TARBALL" ] || { echo "No Linux tarball - run ./gradlew linuxX64DistTar first." >&2; exit 1; }

echo "==> Installing $(basename "$TARBALL") ($(du -h "$TARBALL" | cut -f1)) on $TEST_IMAGE"

# --memory bounds the container so the heap-sizing logic is exercised against a real
# cgroup limit rather than the host's memory.
docker run --rm \
    --memory=4g \
    -v "$TARBALL:/tmp/oscar-linux.tar.gz:ro" \
    -v "$SCRIPT_DIR/test-install-inside.sh:/tmp/test-inside.sh:ro" \
    "$TEST_IMAGE" \
    bash -c 'apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq curl procps >/dev/null 2>&1; bash /tmp/test-inside.sh'
