#!/bin/bash
#
# Full Docker-free install test. Runs INSIDE a clean container.
#
# Exercises the real payload end to end: embedded PostgreSQL, oscarctl bootstrap and
# the actual OSH node, then queries the live API.
#
# systemd is not available in a plain container, so the unit files are not exercised
# here - they are verified separately with systemd-analyze and on a real VM. What this
# proves is that the *payload* works with no Docker and no system PostgreSQL.
#
set -euo pipefail

export OSCAR_HOME=/opt/oscar/current
export OSCAR_CONFIG=/etc/oscar
export OSCAR_DATA=/var/lib/oscar
export OSCAR_LOG_DIR=/var/log/oscar
export OSCAR_ADMIN_PASSWORD='e2e-test-password'
export OSCAR_JAVA
OSCAR_JAVA=$(command -v java)

HTTP_PORT=8282

echo "--- machine ---"
. /etc/os-release
echo "distro:           $PRETTY_NAME"
echo "postgres on PATH: $(command -v postgres || echo none)"
echo "docker present:   $(command -v docker || echo none)"
echo "systemd present:  $(command -v systemctl || echo none)"

echo
echo "=== unpacking distribution ==="
mkdir -p /opt/oscar/3.5.0
tar -xzf /tmp/oscar-linux.tar.gz -C /tmp
mv /tmp/oscar-linux-x64-3.5.0/* /opt/oscar/3.5.0/
ln -sfn /opt/oscar/3.5.0 /opt/oscar/current
echo "  installed $(cat $OSCAR_HOME/VERSION)"

useradd --system --home-dir "$OSCAR_DATA" --shell /sbin/nologin oscar
mkdir -p "$OSCAR_DATA/node" "$OSCAR_CONFIG" "$OSCAR_LOG_DIR"
cp "$OSCAR_HOME/config.json" "$OSCAR_CONFIG/config.template.json"
# Written by install.sh on a real install; created here so sync-web's publishing of
# the viewer's runtime endpoint configuration is actually exercised.
cat > "$OSCAR_CONFIG/viewer-config.json" <<JSON
{
  "node": {
    "name": "Local Node",
    "address": "localhost",
    "port": $HTTP_PORT,
    "oshPathRoot": "/sensorhub",
    "csAPIEndpoint": "/api",
    "isSecure": false
  }
}
JSON
printf '%s\n' "$OSCAR_ADMIN_PASSWORD" > "$OSCAR_CONFIG/admin-password"
chmod 600 "$OSCAR_CONFIG/admin-password"
chown -R oscar:oscar "$OSCAR_DATA" "$OSCAR_LOG_DIR"
chown -R root:oscar "$OSCAR_CONFIG"

as_oscar() {
    su oscar -s /bin/bash -c "OSCAR_HOME='$OSCAR_HOME' OSCAR_CONFIG='$OSCAR_CONFIG' \
        OSCAR_DATA='$OSCAR_DATA' OSCAR_LOG_DIR='$OSCAR_LOG_DIR' OSCAR_JAVA='$OSCAR_JAVA' \
        OSCAR_ADMIN_PASSWORD='$OSCAR_ADMIN_PASSWORD' HOME='$OSCAR_DATA' $*"
}

echo
echo "=== bootstrap: the ExecStartPre chain from oscar-postgres.service ==="
as_oscar "$OSCAR_HOME/bin/oscarctl init-db"
as_oscar "$OSCAR_HOME/bin/oscarctl start-db"

echo
echo "=== bootstrap: the ExecStartPre chain from oscar-node.service ==="
as_oscar "$OSCAR_HOME/bin/oscarctl wait-db --timeout 60"
as_oscar "$OSCAR_HOME/bin/oscarctl ensure-extensions"
as_oscar "$OSCAR_HOME/bin/oscarctl render-config"
as_oscar "$OSCAR_HOME/bin/oscarctl sync-web"

echo
echo "=== starting the OSH node ==="
as_oscar "$OSCAR_HOME/bin/oscar-node" > /var/log/oscar/node.out 2>&1 &
NODE_WAIT=180
echo -n "  waiting for HTTP on :$HTTP_PORT "
for i in $(seq 1 $NODE_WAIT); do
    if curl -fsS -o /dev/null "http://localhost:$HTTP_PORT/sensorhub/admin" \
            -u "admin:$OSCAR_ADMIN_PASSWORD" 2>/dev/null; then
        echo " up after ${i}s"
        break
    fi
    if [ "$i" -eq "$NODE_WAIT" ]; then
        echo " TIMED OUT"
        echo "--- last 60 lines of node output ---"
        tail -60 /var/log/oscar/node.out
        exit 1
    fi
    sleep 1
done

echo
echo "=== querying the live API ==="
API="http://localhost:$HTTP_PORT/sensorhub"
AUTH="-u admin:$OSCAR_ADMIN_PASSWORD"

echo -n "  admin console:            "
curl -fsS -o /dev/null -w '%{http_code}\n' $AUTH "$API/admin"

echo -n "  Connected Systems API:    "
curl -fsS -o /dev/null -w '%{http_code}\n' $AUTH "$API/api/systems"

echo -n "  viewer served at root:    "
curl -fsS -o /dev/null -w '%{http_code}\n' $AUTH "http://localhost:$HTTP_PORT/"

echo -n "  viewer runtime config:    "
curl -fsS -w ' %{http_code}\n' $AUTH "http://localhost:$HTTP_PORT/oscar-config.json" \
    | tr -d '\n ' | sed 's/$/\n/'

echo
echo "=== confirming the node is really using the embedded PostGIS ==="
echo -n "  tables created by OSH:    "
as_oscar "$OSCAR_HOME/pgsql/usr/lib/postgresql/16/bin/psql \
    -h $OSCAR_DATA/run -U postgres -d gis -tAc \
    \"SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema')\""

echo -n "  postgis in use:           "
as_oscar "$OSCAR_HOME/pgsql/usr/lib/postgresql/16/bin/psql \
    -h $OSCAR_DATA/run -U postgres -d gis -tAc \"SELECT postgis_version()\""

echo
echo "=== doctor ==="
as_oscar "$OSCAR_HOME/bin/oscarctl doctor"

echo
echo "=== shutting down ==="
pkill -f SensorHubWrapper || true
sleep 5
as_oscar "$OSCAR_HOME/bin/oscarctl stop-db"

echo
echo "PASS: the OSH node started against the embedded PostgreSQL/PostGIS, served its"
echo "      API and viewer, and stored data - on a machine with no Docker, no system"
echo "      PostgreSQL and nothing installed beyond the distribution tarball."
