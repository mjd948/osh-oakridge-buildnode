# Builder for OSCAR's embedded PostgreSQL + PostGIS bundle.
#
# The base image is the same one the current Docker-based deployment runs, so the
# bundled binaries are the exact build OSCAR's database has been running on in
# production. That is deliberate for this first iteration: it removes the Docker
# runtime requirement without simultaneously changing the database build.
#
# Consequence: the bundle inherits this image's glibc (Debian 11 / 2.31), which is
# its minimum-host floor. That covers Debian 11+, Ubuntu 20.04+ and RHEL 9+, but
# NOT RHEL 8 (glibc 2.28). Building PostgreSQL and PostGIS from source on an older
# base is the follow-on that lowers the floor; see packaging plan Phase 2.
ARG BASE_IMAGE=postgis/postgis:16-3.4
FROM ${BASE_IMAGE}

ARG BASE_IMAGE
ENV BASE_IMAGE=${BASE_IMAGE}

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends patchelf binutils file; \
    rm -rf /var/lib/apt/lists/*

COPY build-bundle.sh /build-bundle.sh
RUN chmod +x /build-bundle.sh

VOLUME /out
ENTRYPOINT ["/build-bundle.sh"]
