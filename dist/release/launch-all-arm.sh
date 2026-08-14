#!/bin/bash

HOST=localhost
DB_NAME=gis
DB_USER=postgres
RETRY_MAX=20
RETRY_INTERVAL=5
PROJECT_DIR="$(pwd)" # Store the original directory
CONTAINER_NAME=oscar-postgis-container

#sudo docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

# Create pgdata directory if needed
if [ ! -d "${PROJECT_DIR}/pgdata" ]; then
  echo "Creating pgdata folder..."
  mkdir -p "${PROJECT_DIR}/pgdata"
fi

# Check Docker
if ! command -v docker >/dev/null 2>&1; then
    echo "Error: Docker is not installed. Please install Docker first."
    exit 1
fi

echo "Building PostGIS Docker image..."

cd postgis || { echo "Error: postgis directory not found"; exit 1; }

# Build PostGIS
sudo docker build . \
  --file=Dockerfile-arm64 \
  --tag=oscar-postgis-arm

echo "Starting PostGIS container..."
echo "PROJECT_DIR is set to: ${PROJECT_DIR}"

if docker ps -a --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}$"; then
    # The container exists
    if docker ps --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}$"; then
        echo "Container already running: ${CONTAINER_NAME}"
    else
        echo "Starting existing container: ${CONTAINER_NAME}"
        docker start "${CONTAINER_NAME}"
    fi
else
    echo "Creating new container: ${CONTAINER_NAME}"
    docker run \
      --name $CONTAINER_NAME \
      -e POSTGRES_DB=$DB_NAME \
      -e POSTGRES_USER=$DB_USER \
      -e POSTGRES_PASSWORD=postgres \
      -e DATADIR=/var/lib/postgresql/data \
      -p 5432:5432 \
      -v "$(pwd)/pgdata:/var/lib/postgresql/data" \
      -d \
      oscar-postgis-arm || { echo "Failed to start PostGIS container"; exit 1; }
fi

# Wait for PostgreSQL/PostGIS to become ready
echo "Waiting for PostGIS ARM64 (PostgreSQL) to be ready..."

RETRY_COUNT=0
export PGPASSWORD=postgres  # Needed for pg_isready with password

# Bounded wait. RETRY_MAX was declared but never incremented or checked, so a database
# that never came up left this script waiting forever while reporting success.
until docker exec "$CONTAINER_NAME" pg_isready -U "$DB_USER" -d "$DB_NAME" > /dev/null 2>&1; do
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ "$RETRY_COUNT" -ge "$RETRY_MAX" ]; then
    echo "Error: PostGIS did not become ready after $((RETRY_MAX * RETRY_INTERVAL))s. Last container logs:"
    docker logs --tail 30 "$CONTAINER_NAME" 2>&1 || true
    exit 1
  fi
  echo "PostGIS not ready yet, retrying (${RETRY_COUNT}/${RETRY_MAX})..."
  sleep "${RETRY_INTERVAL}"
done

echo "PostGIS (PostgreSQL) is ready! Please wait for OpenSensorHub to start..."

sleep 10

# Launch osh-node-oscar
cd "$PROJECT_DIR/osh-node-oscar" || { echo "Error: osh-node-oscar not found"; exit 1; }
./launch.sh