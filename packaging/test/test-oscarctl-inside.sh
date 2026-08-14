#!/bin/bash
#
# Exercises oscarctl against the real embedded-PostgreSQL bundle, on a machine with
# no PostgreSQL, no PostGIS and no Docker. Runs INSIDE the test container.
#
set -euo pipefail

export OSCAR_HOME=/opt/oscar
export OSCAR_CONFIG=/etc/oscar
export OSCAR_DATA=/var/lib/oscar
export OSCAR_DB_PORT=55432
export OSCAR_ADMIN_PASSWORD='not-the-default-password'

CTL="$OSCAR_HOME/bin/oscarctl"

echo "--- host identity ---"
. /etc/os-release
echo "distro:           $PRETTY_NAME"
echo "java:             $(java -version 2>&1 | head -1)"
echo "postgres on PATH: $(command -v postgres || echo none)"
echo "psql on PATH:     $(command -v psql || echo none)"
echo "docker present:   $(command -v docker || echo none)"

echo
echo "--- resolved paths ---"
$CTL paths

# postgres refuses to run as root.
useradd --system --home-dir "$OSCAR_DATA" --shell /sbin/nologin oscar
mkdir -p "$OSCAR_DATA" "$OSCAR_CONFIG"
chown -R oscar:oscar "$OSCAR_DATA"

# su resets PATH, so the JRE this image provides has to be named explicitly. On a
# real install the bundled runtime at $OSCAR_HOME/jre is found without any of this.
OSCAR_JAVA=$(command -v java)

run_as_oscar() {
    su oscar -s /bin/bash -c "OSCAR_HOME='$OSCAR_HOME' OSCAR_CONFIG='$OSCAR_CONFIG' \
        OSCAR_DATA='$OSCAR_DATA' OSCAR_DB_PORT='$OSCAR_DB_PORT' \
        OSCAR_JAVA='$OSCAR_JAVA' \
        OSCAR_ADMIN_PASSWORD='$OSCAR_ADMIN_PASSWORD' '$CTL' $*"
}

echo
echo "=== init-db ==="
run_as_oscar init-db

echo
echo "=== init-db again (must be idempotent) ==="
run_as_oscar init-db

echo
echo "=== start-db ==="
run_as_oscar start-db

echo
echo "=== wait-db ==="
run_as_oscar wait-db --timeout 60

echo
echo "=== ensure-extensions ==="
run_as_oscar ensure-extensions

echo
echo "=== ensure-extensions again (must be idempotent) ==="
run_as_oscar ensure-extensions

echo
echo "=== render-config (first run: creates config.json) ==="
run_as_oscar render-config
CONFIG="$OSCAR_DATA/node/config.json"
echo -n "  placeholder substituted: "
if grep -q '__INITIAL_ADMIN_PASSWORD__' "$CONFIG"; then echo "NO - still present" >&2; exit 1; else echo yes; fi
echo -n "  password stored hashed:  "
if grep -q 'PBKDF2WithHmacSHA1:' "$CONFIG"; then echo yes; else echo "NO" >&2; exit 1; fi
echo -n "  plaintext absent:        "
if grep -q "$OSCAR_ADMIN_PASSWORD" "$CONFIG"; then echo "NO - password in cleartext" >&2; exit 1; else echo yes; fi

echo
echo "=== render-config again (must preserve operator edits) ==="
# Simulate what OSH itself does at runtime: rewrite config.json with added modules.
su oscar -s /bin/bash -c "printf '\n{\"operator\":\"added-a-module\"}\n' >> $CONFIG"
BEFORE=$(sha256sum "$CONFIG" | cut -d' ' -f1)
run_as_oscar render-config
AFTER=$(sha256sum "$CONFIG" | cut -d' ' -f1)
echo -n "  config.json untouched:   "
if [ "$BEFORE" = "$AFTER" ]; then echo yes; else echo "NO - config was rewritten" >&2; exit 1; fi

echo
echo "=== major-version guard ==="
# Pretend the cluster came from a different major version; init-db must refuse.
su oscar -s /bin/bash -c "echo 15 > $OSCAR_DATA/pgdata/PG_VERSION"
if run_as_oscar init-db 2>/tmp/guard.err; then
    echo "  FAIL: init-db proceeded against a PostgreSQL 15 cluster" >&2
    exit 1
fi
echo "  refused, as it should:"
sed 's/^/    /' /tmp/guard.err | head -4
su oscar -s /bin/bash -c "echo 16 > $OSCAR_DATA/pgdata/PG_VERSION"

echo
echo "=== doctor ==="
run_as_oscar doctor

echo
echo "=== stop-db ==="
run_as_oscar stop-db

echo
echo "PASS: oscarctl initialised a cluster, installed extensions, rendered first-run"
echo "      configuration once, refused to clobber it, refused a mismatched major"
echo "      version, and reported healthy - with no PostgreSQL or Docker installed."
