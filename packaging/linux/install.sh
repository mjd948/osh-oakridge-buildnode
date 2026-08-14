#!/bin/bash
#
# Installs OSCAR: node, embedded PostgreSQL/PostGIS and viewer, as systemd services.
#
# Requires no Docker, no system PostgreSQL and no Java installed beforehand once the
# bundled JRE is in place. Run from the unpacked distribution directory.
#
#   sudo ./install.sh
#   sudo ./install.sh --admin-password-file /root/pw --http-port 8282 --no-start
#
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

PREFIX=/opt/oscar
CONFIG_DIR=/etc/oscar
DATA_DIR=/var/lib/oscar
LOG_DIR=/var/log/oscar
SERVICE_USER=oscar
ADMIN_PASSWORD=""
ADMIN_PASSWORD_FILE=""
HTTP_PORT=""
START_SERVICES=1
UNATTENDED=0

VERSION=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "0.0.0")

usage() {
    cat <<EOF
Usage: sudo ./install.sh [options]

  --prefix DIR               Program directory (default: $PREFIX)
  --config-dir DIR           Configuration directory (default: $CONFIG_DIR)
  --data-dir DIR             Data directory (default: $DATA_DIR)
  --user NAME                Service account (default: $SERVICE_USER)
  --admin-password PASS      Initial admin password
  --admin-password-file FILE Read the initial admin password from FILE
  --http-port PORT           Node HTTP port (default: leave config as shipped)
  --no-start                 Install but do not start the services
  --unattended               Never prompt
  -h, --help                 This message
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        --config-dir) CONFIG_DIR="$2"; shift 2 ;;
        --data-dir) DATA_DIR="$2"; shift 2 ;;
        --user) SERVICE_USER="$2"; shift 2 ;;
        --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
        --admin-password-file) ADMIN_PASSWORD_FILE="$2"; shift 2 ;;
        --http-port) HTTP_PORT="$2"; shift 2 ;;
        --no-start) START_SERVICES=0; shift ;;
        --unattended) UNATTENDED=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "This installer must run as root." >&2; exit 1; }
command -v systemctl >/dev/null 2>&1 || { echo "systemd is required." >&2; exit 1; }

TARGET="$PREFIX/$VERSION"

echo "==> Installing OSCAR $VERSION"
echo "    program: $TARGET"
echo "    config:  $CONFIG_DIR"
echo "    data:    $DATA_DIR"

# ---------------------------------------------------------------- preflight

# PostgreSQL refuses to run as root, so a dedicated unprivileged account is required
# rather than merely preferred.
if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    echo "==> Creating service account '$SERVICE_USER'"
    useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
else
    echo "==> Service account '$SERVICE_USER' already exists"
fi

# A cluster from a different major version cannot be opened by the bundled server.
# Catch it here, before anything has been changed, rather than at first boot.
if [ -f "$DATA_DIR/pgdata/PG_VERSION" ]; then
    EXISTING=$(cat "$DATA_DIR/pgdata/PG_VERSION")
    BUNDLED=$(basename "$(find "$SCRIPT_DIR/pgsql/usr/lib/postgresql" -maxdepth 1 -mindepth 1 -type d | head -1)")
    if [ "$EXISTING" != "$BUNDLED" ]; then
        echo "Error: existing database at $DATA_DIR/pgdata was created by PostgreSQL $EXISTING," >&2
        echo "       but this release bundles PostgreSQL $BUNDLED. Migrating across major" >&2
        echo "       versions requires pg_upgrade. Refusing to continue." >&2
        exit 1
    fi
    echo "==> Existing PostgreSQL $EXISTING cluster found; it will be reused"
fi

# ------------------------------------------------------------------ layout

echo "==> Laying down program files"
mkdir -p "$TARGET"
# Copy everything except the installer's own scripts and the data it must not own.
tar -C "$SCRIPT_DIR" --exclude=./install.sh --exclude=./uninstall.sh \
    --exclude=./systemd -cf - . | tar -C "$TARGET" -xf -
chmod +x "$TARGET/bin/"* 2>/dev/null || true
find "$TARGET/pgsql" -type f -path '*/bin/*' -exec chmod +x {} \; 2>/dev/null || true

# The `current` symlink is what the units reference, so an upgrade is a symlink flip
# and a rollback is flipping it back.
ln -sfn "$TARGET" "$PREFIX/current"

echo "==> Creating config and data directories"
mkdir -p "$CONFIG_DIR/trusted_certificates" "$DATA_DIR/node" "$LOG_DIR"

# config.template.json is the source for first-run rendering. The live config.json
# lives in the data directory and is never overwritten by an upgrade.
if [ -f "$TARGET/config.json" ] && [ ! -f "$CONFIG_DIR/config.template.json" ]; then
    cp "$TARGET/config.json" "$CONFIG_DIR/config.template.json"
fi

# ------------------------------------------------------------------ secrets

if [ -n "$ADMIN_PASSWORD_FILE" ]; then
    [ -r "$ADMIN_PASSWORD_FILE" ] || { echo "Cannot read $ADMIN_PASSWORD_FILE" >&2; exit 1; }
    ADMIN_PASSWORD=$(head -1 "$ADMIN_PASSWORD_FILE")
fi

if [ ! -f "$DATA_DIR/node/config.json" ] && [ ! -f "$CONFIG_DIR/admin-password" ]; then
    if [ -z "$ADMIN_PASSWORD" ] && [ "$UNATTENDED" -eq 0 ] && [ -t 0 ]; then
        echo
        echo "An initial administrator password is required for the OSCAR web interface."
        read -r -s -p "  Password: " ADMIN_PASSWORD; echo
        read -r -s -p "  Confirm:  " CONFIRM; echo
        [ "$ADMIN_PASSWORD" = "$CONFIRM" ] || { echo "Passwords do not match." >&2; exit 1; }
    fi
    if [ -z "$ADMIN_PASSWORD" ]; then
        # Better a random password the operator must reset than a well-known default
        # baked into every installation.
        ADMIN_PASSWORD=$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 20)
        echo
        echo "  No password supplied. Generated one:"
        echo "      $ADMIN_PASSWORD"
        echo "  Saved to $CONFIG_DIR/admin-password - change it after first login."
        echo
    fi
    printf '%s\n' "$ADMIN_PASSWORD" > "$CONFIG_DIR/admin-password"
    chmod 600 "$CONFIG_DIR/admin-password"
fi

# ------------------------------------------------------------------- config

if [ ! -f "$CONFIG_DIR/oscar.env" ]; then
    cat > "$CONFIG_DIR/oscar.env" <<EOF
# OSCAR installation settings. Read by the service units and by oscarctl.
# Values here override the built-in defaults; anything left commented keeps them.

# Heap. Leave unset to size from the memory this machine actually has.
#OSCAR_HEAP=6g
#OSCAR_HEAP_MAX_PERCENT=50

# Embedded database. It listens on loopback only.
#OSCAR_DB_PORT=5432
#OSCAR_DB_NAME=gis
#OSCAR_DB_MAX_CONNECTIONS=200

# Air-gapped installs: leave these empty to disable outbound calls.
#OSCAR_SENTRY_DSN=
#OSCAR_WEBID_API_ROOT=
EOF
    chmod 640 "$CONFIG_DIR/oscar.env"
fi

if [ ! -f "$CONFIG_DIR/viewer-config.json" ]; then
    PORT_VALUE="${HTTP_PORT:-8282}"
    cat > "$CONFIG_DIR/viewer-config.json" <<EOF
{
  "node": {
    "name": "Local Node",
    "address": "localhost",
    "port": $PORT_VALUE,
    "oshPathRoot": "/sensorhub",
    "csAPIEndpoint": "/api",
    "isSecure": false
  }
}
EOF
fi

echo "$VERSION" > "$TARGET/VERSION"

echo "==> Setting ownership"
chown -R "$SERVICE_USER:$SERVICE_USER" "$DATA_DIR" "$LOG_DIR"
chown -R root:"$SERVICE_USER" "$CONFIG_DIR"
chmod 750 "$CONFIG_DIR"
[ -f "$CONFIG_DIR/admin-password" ] && chown root:"$SERVICE_USER" "$CONFIG_DIR/admin-password"

# ----------------------------------------------------------------- services

echo "==> Installing systemd units"
for unit in oscar-postgres.service oscar-node.service oscar.target; do
    sed -e "s|/opt/oscar/current|$PREFIX/current|g" \
        -e "s|/etc/oscar|$CONFIG_DIR|g" \
        -e "s|/var/lib/oscar|$DATA_DIR|g" \
        -e "s|/var/log/oscar|$LOG_DIR|g" \
        -e "s|^User=oscar$|User=$SERVICE_USER|" \
        -e "s|^Group=oscar$|Group=$SERVICE_USER|" \
        "$SCRIPT_DIR/systemd/$unit" > "/etc/systemd/system/$unit"
done
systemctl daemon-reload
systemctl enable oscar-postgres.service oscar-node.service >/dev/null 2>&1

if [ "$START_SERVICES" -eq 1 ]; then
    echo "==> Starting services"
    systemctl start oscar-postgres.service
    systemctl start oscar-node.service
    echo
    "$TARGET/bin/oscarctl" doctor || true
else
    echo "==> Not starting services (--no-start)"
fi

cat <<EOF

OSCAR $VERSION installed.

  Web interface:  http://localhost:${HTTP_PORT:-8282}/
  Admin console:  http://localhost:${HTTP_PORT:-8282}/sensorhub/admin
  Health check:   $PREFIX/current/bin/oscarctl doctor

  systemctl status oscar-node
  journalctl -u oscar-node -f

EOF
