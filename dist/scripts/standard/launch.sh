#!/bin/bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Optional operator configuration. Keeps machine-specific settings (heap size,
# store passwords, log location) out of this script so upgrades don't clobber them.
if [ -f "$SCRIPT_DIR/oscar.env" ]; then
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/oscar.env"
fi

# Make sure all the necessary certificates are trusted by the system.
"$SCRIPT_DIR/load_trusted_certs.sh"

export KEYSTORE="${KEYSTORE:-./osh-keystore.p12}"
export KEYSTORE_TYPE="${KEYSTORE_TYPE:-PKCS12}"
export KEYSTORE_PASSWORD="${KEYSTORE_PASSWORD:-atakatak}"

# Must match the file name load_trusted_certs.sh actually writes ("trustStore.jks").
# This was "./truststore.jks", which exists on no case-sensitive filesystem.
export TRUSTSTORE="${TRUSTSTORE:-./trustStore.jks}"
export TRUSTSTORE_TYPE="${TRUSTSTORE_TYPE:-JKS}"
export TRUSTSTORE_PASSWORD="${TRUSTSTORE_PASSWORD:-changeit}"

export INITIAL_ADMIN_PASSWORD_FILE="${INITIAL_ADMIN_PASSWORD_FILE:-./.s}"

# After copying the default configuration file, also look to see if they
# specified what they want the initial admin user's password to be, either
# as a secret file or by providing it as an environment variable.
if [ -z "$INITIAL_ADMIN_PASSWORD_FILE" ] && [ -z "$INITIAL_ADMIN_PASSWORD" ]; then
  export INITIAL_ADMIN_PASSWORD=admin
fi
"$SCRIPT_DIR/set-initial-admin-password.sh"

# JVM crash dumps go outside the install directory. Without ErrorFile they land in the
# JVM's working directory (osh-node-oscar) and accumulate there unnoticed.
CRASH_DUMP_DIR="${OSCAR_CRASH_DUMP_DIR:-/var/log/oscar}"
if ! mkdir -p "$CRASH_DUMP_DIR" 2>/dev/null || [ ! -w "$CRASH_DUMP_DIR" ]; then
    # Not running as root, or the path isn't writable. Fall back to a directory we
    # know we can write, rather than leaving ErrorFile pointing somewhere unusable.
    CRASH_DUMP_DIR="$SCRIPT_DIR/logs"
    mkdir -p "$CRASH_DUMP_DIR"
fi
# Dumps are named per-PID, so nothing overwrites anything; age them out instead.
find "$CRASH_DUMP_DIR" -maxdepth 1 -name 'hs_err_pid*.log' -mtime +14 -delete 2>/dev/null || true

# Heap sizing. A fixed 6g request made the node refuse to start on any machine with
# less than ~8 GB of RAM. Set OSCAR_HEAP (e.g. OSCAR_HEAP=6g) to pin the heap to a
# specific size; otherwise scale it to a share of the memory actually available.
#
# The obvious -XX:MaxRAMPercentage is NOT safe here. When no cgroup memory limit is
# visible - which is the case in an unprivileged LXC container - the JVM falls back to
# sysconf(_SC_PHYS_PAGES), which reports the *host's* physical memory and bypasses the
# LXCFS-provided /proc/meminfo. On this 8 GB container that produced a 15.5 GB max heap.
# Read the limit ourselves and pass an explicit -Xmx.
if [ -n "$OSCAR_HEAP" ]; then
    HEAP_OPTS="-Xms${OSCAR_HEAP} -Xmx${OSCAR_HEAP}"
else
    MEM_LIMIT_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)

    # A cgroup limit, where one exists, is authoritative and may be lower still.
    for f in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
        [ -r "$f" ] || continue
        v=$(cat "$f" 2>/dev/null)
        case "$v" in
            ''|max|*[!0-9]*) continue ;;
        esac
        v_kb=$((v / 1024))
        # Kernels report "no limit" as an enormous number; ignore those.
        if [ "$v_kb" -gt 0 ] && [ "$v_kb" -lt "${MEM_LIMIT_KB:-0}" ]; then
            MEM_LIMIT_KB=$v_kb
        fi
    done

    if [ -n "$MEM_LIMIT_KB" ] && [ "$MEM_LIMIT_KB" -gt 0 ]; then
        HEAP_MAX_MB=$(( MEM_LIMIT_KB * ${OSCAR_HEAP_MAX_PERCENT:-50} / 100 / 1024 ))
        HEAP_MIN_MB=$(( MEM_LIMIT_KB * ${OSCAR_HEAP_INITIAL_PERCENT:-25} / 100 / 1024 ))
        [ "$HEAP_MAX_MB" -lt 1024 ] && HEAP_MAX_MB=1024
        [ "$HEAP_MIN_MB" -lt 512 ] && HEAP_MIN_MB=512
        HEAP_OPTS="-Xms${HEAP_MIN_MB}m -Xmx${HEAP_MAX_MB}m"
    else
        # Could not determine memory; fall back to a conservative fixed heap.
        HEAP_OPTS="-Xms512m -Xmx2048m"
    fi
fi
echo "Heap: $HEAP_OPTS"

# Start the node.
#
# The javax.net.ssl.* properties are deliberately NOT passed as -D flags: SensorHubWrapper
# reads the KEYSTORE/TRUSTSTORE environment variables above and sets those properties
# itself, which is the whole reason it exists (it keeps the store passwords out of the
# process command line, where `ps` would show them). Passing them here both duplicated
# and defeated that.
java $HEAP_OPTS -Xss256k -XX:ReservedCodeCacheSize=512m -XX:+UseG1GC \
	-XX:+HeapDumpOnOutOfMemoryError \
	-XX:HeapDumpPath="$CRASH_DUMP_DIR" \
	-XX:ErrorFile="$CRASH_DUMP_DIR/hs_err_pid%p.log" \
	-Dlogback.configurationFile=./logback.xml \
	-cp "lib/*" \
	-Djava.system.class.loader="org.sensorhub.utils.NativeClassLoader" \
	com.botts.impl.security.SensorHubWrapper ./config.json ./db
