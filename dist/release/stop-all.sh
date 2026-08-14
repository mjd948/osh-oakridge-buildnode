#!/bin/bash

CONTAINER_NAME="oscar-postgis-container"
SENSORHUB_NAME="com.botts.impl.security.SensorHubWrapper"
STOP_TIMEOUT="${OSCAR_STOP_TIMEOUT:-60}"

# The node must go down before the database it is writing to. Stopping PostGIS
# first pulled the database out from under a running node mid-transaction.
echo "Stopping SensorHubWrapper Java process..."

PID=""

# --- Option 1: Use jps if available ---
if command -v jps >/dev/null 2>&1; then
    PID=$(jps -l | grep "$SENSORHUB_NAME" | awk '{print $1}')
fi

# --- Option 2: fallback to pgrep if PID not found ---
if [ -z "$PID" ]; then
    if command -v pgrep >/dev/null 2>&1; then
        PID=$(pgrep -f "$SENSORHUB_NAME")
    fi
fi

if [ -n "$PID" ]; then
    echo "Stopping SensorHubWrapper with PID(s): $PID"
    # Ask it to shut down cleanly so it can flush module state and commit to the
    # database. Only escalate to SIGKILL if it is still alive after the timeout.
    kill $PID 2>/dev/null
    waited=0
    while [ "$waited" -lt "$STOP_TIMEOUT" ] && kill -0 $PID 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
    done
    if kill -0 $PID 2>/dev/null; then
        echo "Still running after ${STOP_TIMEOUT}s; forcing."
        kill -9 $PID 2>/dev/null
    fi
    echo "SensorHubWrapper stopped."
else
    echo "SensorHubWrapper process not found."
fi

echo
echo "Stopping container: $CONTAINER_NAME..."

# Stop Docker container if it exists
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Container exists. Stopping..."
    docker stop "$CONTAINER_NAME"
    echo "Container stopped."
else
    echo "Container not found. Nothing to stop."
fi

echo
echo "Done."
