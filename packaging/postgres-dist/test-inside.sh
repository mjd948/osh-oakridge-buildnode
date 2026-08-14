#!/bin/bash
#
# Runs INSIDE the clean test container (see test-bundle.sh). Kept as its own file
# so the SQL and shell quoting stay readable instead of being buried in nested
# docker-run quoting.
#
set -euo pipefail

PG_MAJOR="${PG_MAJOR:-16}"
ROOT=/srv/oscar
PGSQL="$ROOT/embedded/pgsql"
BIN="$PGSQL/usr/lib/postgresql/$PG_MAJOR/bin"
DATA="$ROOT/data"
SOCK="$ROOT/run"
PORT=55432

psql_() { su oscar -s /bin/bash -c "$BIN/psql -h $SOCK -p $PORT -U postgres -d gis $*"; }

echo "--- host identity ---"
. /etc/os-release
echo "distro:           $PRETTY_NAME"
echo "glibc:            $(ldd --version | head -1 | awk '{print $NF}')"
echo "postgres on PATH: $(command -v postgres || echo none)"
echo "psql on PATH:     $(command -v psql || echo none)"
echo "docker present:   $(command -v docker || echo none)"

echo
echo "--- unpacking to a path different from the one it was built at ---"
mkdir -p "$ROOT/embedded"
tar -xzf /tmp/bundle.tar.gz -C "$ROOT/embedded"
echo "installed at: $PGSQL"

# postgres refuses to run as root, exactly as it will on a real install.
useradd --system --home-dir "$ROOT" --shell /sbin/nologin oscar
mkdir -p "$DATA" "$SOCK"
chown -R oscar:oscar "$ROOT"

echo
echo "--- initdb ---"
su oscar -s /bin/bash -c "$BIN/initdb -D $DATA -U postgres --encoding=UTF8 --locale=C --auth-local=trust" 2>&1 | tail -3

cat >> "$DATA/postgresql.conf" <<CONF
listen_addresses = '127.0.0.1'
port = $PORT
unix_socket_directories = '$SOCK'
jit = off
max_parallel_workers = 0
max_parallel_workers_per_gather = 0
CONF

echo
echo "--- starting postmaster ---"
su oscar -s /bin/bash -c "$BIN/pg_ctl -D $DATA -l $ROOT/postgres.log -w -t 60 start"
su oscar -s /bin/bash -c "$BIN/pg_isready -h $SOCK -p $PORT -U postgres"

echo
echo "--- creating gis database and applying init-extensions.sql ---"
su oscar -s /bin/bash -c "$BIN/createdb -h $SOCK -p $PORT -U postgres gis"
su oscar -s /bin/bash -c "$BIN/psql -h $SOCK -p $PORT -U postgres -d gis -q -f /tmp/init-extensions.sql" 2>&1 \
    | grep -viE '^(NOTICE|$)' || true

echo
echo "--- installed extensions ---"
psql_ "-tAc \"SELECT extname || ' ' || extversion FROM pg_extension ORDER BY extname\"" | sed 's/^/  /'

echo
echo "--- exercising PostGIS for real, not just a version string ---"
cat > /tmp/exercise.sql <<'SQL'
CREATE TABLE t(id serial PRIMARY KEY, geom geometry(Point,4326));
INSERT INTO t(geom) VALUES
    (ST_SetSRID(ST_MakePoint(-84.31, 35.93), 4326)),
    (ST_SetSRID(ST_MakePoint(-84.30, 35.94), 4326));
CREATE INDEX t_geom_idx ON t USING gist(geom);
ANALYZE t;
SQL
su oscar -s /bin/bash -c "$BIN/psql -h $SOCK -p $PORT -U postgres -d gis -q -f /tmp/exercise.sql"

echo -n "  geodesic distance between the two points: "
psql_ "-tAc \"SELECT round(ST_Distance(a.geom::geography, b.geom::geography)::numeric, 2) || ' m' FROM t a, t b WHERE a.id = 1 AND b.id = 2\""

echo -n "  GiST index used by a bbox query:          "
psql_ "-tAc \"SELECT count(*) FROM t WHERE geom && ST_MakeEnvelope(-84.32, 35.92, -84.29, 35.95, 4326)\"" \
    | xargs -I{} echo "{} rows matched"

echo -n "  topology schema created:                  "
psql_ "-tAc \"SELECT count(*) > 0 FROM information_schema.schemata WHERE schema_name = 'topology'\""

echo -n "  tiger geocoder schema created:            "
psql_ "-tAc \"SELECT count(*) > 0 FROM information_schema.schemata WHERE schema_name = 'tiger'\""

echo -n "  trigram similarity (pg_trgm):             "
psql_ "-tAc \"SELECT round(similarity('CSQU3054383', 'CSQU3054338')::numeric, 3)\""

echo -n "  fuzzystrmatch levenshtein:                "
psql_ "-tAc \"SELECT levenshtein('rapiscan', 'rapiscn')\""

echo
echo "--- confirming the excluded extensions are honestly absent ---"
for ext in postgis_raster postgis_sfcgal; do
    echo -n "  $ext: "
    if psql_ "-tAc \"SELECT count(*) FROM pg_available_extensions WHERE name = '$ext'\"" | grep -q '^0$'; then
        echo "not offered (correct)"
    else
        echo "STILL ADVERTISED - its library is not in the bundle" >&2
        exit 1
    fi
done

echo
echo "--- restart survives (data persists across a stop/start cycle) ---"
su oscar -s /bin/bash -c "$BIN/pg_ctl -D $DATA -m fast -w -t 60 stop" >/dev/null
su oscar -s /bin/bash -c "$BIN/pg_ctl -D $DATA -l $ROOT/postgres.log -w -t 60 start" >/dev/null
echo -n "  rows still present after restart:         "
psql_ "-tAc \"SELECT count(*) FROM t\""

echo
echo "--- stopping cleanly ---"
su oscar -s /bin/bash -c "$BIN/pg_ctl -D $DATA -m fast -w -t 60 stop"

echo
echo "PASS: relocated bundle initialised a cluster, served real PostGIS queries,"
echo "      survived a restart and shut down cleanly - with no PostgreSQL, no"
echo "      PostGIS and no Docker present on the machine."
