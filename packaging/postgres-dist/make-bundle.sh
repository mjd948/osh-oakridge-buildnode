#!/bin/bash
#
# Host-side wrapper: builds the container and drops the relocatable PostgreSQL +
# PostGIS bundle into ./out.
#
# Docker is required to BUILD the bundle. It is not required to RUN it - that is
# the entire point of the exercise.
#
#   ./make-bundle.sh                                  # default base image
#   BASE_IMAGE=oscar-postgis:latest ./make-bundle.sh  # reuse a locally built image
#
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_IMAGE="${BASE_IMAGE:-postgis/postgis:16-3.4}"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/out}"
BUILDER_TAG="oscar-postgres-dist-builder"

command -v docker >/dev/null 2>&1 || { echo "Error: docker is required to build the bundle."; exit 1; }

echo "==> Building builder image from $BASE_IMAGE"
docker build \
    --build-arg "BASE_IMAGE=$BASE_IMAGE" \
    --tag "$BUILDER_TAG" \
    --file "$SCRIPT_DIR/Dockerfile" \
    "$SCRIPT_DIR"

mkdir -p "$OUT_DIR"
echo "==> Producing bundle in $OUT_DIR"
docker run --rm \
    -v "$OUT_DIR:/out" \
    -e "OUT=/out" \
    "$BUILDER_TAG"

echo
echo "Artifacts:"
ls -lh "$OUT_DIR"
