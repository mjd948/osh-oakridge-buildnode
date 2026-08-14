#!/bin/bash
#
# Removes OSCAR's services and program files.
#
# The data directory - which holds the observation database, recorded video and the
# node's configuration - is preserved unless it is explicitly requested for deletion.
# Removing a package should never be capable of destroying a site's recorded data by
# accident.
#
#   sudo ./uninstall.sh                 # services and program files
#   sudo ./uninstall.sh --purge-data    # also delete the database and recordings
#
set -euo pipefail

PREFIX=/opt/oscar
CONFIG_DIR=/etc/oscar
DATA_DIR=/var/lib/oscar
LOG_DIR=/var/log/oscar
SERVICE_USER=oscar
PURGE_DATA=0
PURGE_CONFIG=0
REMOVE_USER=0
ASSUME_YES=0

usage() {
    cat <<EOF
Usage: sudo ./uninstall.sh [options]

  --prefix DIR       Program directory (default: $PREFIX)
  --data-dir DIR     Data directory (default: $DATA_DIR)
  --config-dir DIR   Configuration directory (default: $CONFIG_DIR)
  --purge-data       Delete the database, recordings and node state. Irreversible.
  --purge-config     Delete $CONFIG_DIR
  --remove-user      Remove the '$SERVICE_USER' service account
  --yes              Do not prompt for confirmation
  -h, --help         This message
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        --data-dir) DATA_DIR="$2"; shift 2 ;;
        --config-dir) CONFIG_DIR="$2"; shift 2 ;;
        --purge-data) PURGE_DATA=1; shift ;;
        --purge-config) PURGE_CONFIG=1; shift ;;
        --remove-user) REMOVE_USER=1; shift ;;
        --yes) ASSUME_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "This uninstaller must run as root." >&2; exit 1; }

echo "==> Stopping services"
# Node first, so it releases the database before the database goes away.
for unit in oscar-node.service oscar-postgres.service; do
    systemctl stop "$unit" 2>/dev/null || true
    systemctl disable "$unit" 2>/dev/null || true
done

echo "==> Removing systemd units"
rm -f /etc/systemd/system/oscar-node.service \
      /etc/systemd/system/oscar-postgres.service \
      /etc/systemd/system/oscar.target
systemctl daemon-reload

echo "==> Removing program files"
rm -rf "$PREFIX"

if [ "$PURGE_DATA" -eq 1 ]; then
    SIZE=$(du -sh "$DATA_DIR" 2>/dev/null | cut -f1 || echo unknown)
    if [ "$ASSUME_YES" -eq 0 ]; then
        echo
        echo "About to permanently delete $DATA_DIR ($SIZE)."
        echo "This includes the observation database, recorded video and all node state."
        read -r -p "Type DELETE to confirm: " CONFIRM
        [ "$CONFIRM" = "DELETE" ] || { echo "Aborted; data left in place."; exit 1; }
    fi
    echo "==> Deleting $DATA_DIR ($SIZE)"
    rm -rf "$DATA_DIR" "$LOG_DIR"
else
    echo "==> Data preserved at $DATA_DIR"
    echo "    (re-run with --purge-data to delete it)"
fi

if [ "$PURGE_CONFIG" -eq 1 ]; then
    echo "==> Deleting $CONFIG_DIR"
    rm -rf "$CONFIG_DIR"
else
    echo "==> Configuration preserved at $CONFIG_DIR"
fi

if [ "$REMOVE_USER" -eq 1 ] && id -u "$SERVICE_USER" >/dev/null 2>&1; then
    if [ "$PURGE_DATA" -eq 0 ]; then
        echo "==> Keeping '$SERVICE_USER': it still owns the preserved data directory"
    else
        echo "==> Removing service account '$SERVICE_USER'"
        userdel "$SERVICE_USER" 2>/dev/null || true
    fi
fi

echo
echo "OSCAR removed."
