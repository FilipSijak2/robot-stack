#!/usr/bin/env bash
set -euo pipefail

# Simple deployment script:
# 1. Snapshot current tags from .env to previous_tags.log
# 2. Pull latest images from registry
# 3. Recreate containers
# 4. Run basic health checks

STAMP=$(date -u +%Y%m%d-%H%M%S)
LOG=previous_tags.log
ENV_FILE=".env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[ERROR] .env file not found in $(pwd)" >&2
  exit 1
fi

# Snapshot current tag lines (only lines containing *_TAG=)
{ echo "# Snapshot $STAMP"; grep -E '^[A-Z_]+TAG=' "$ENV_FILE"; echo; } >> "$LOG"
echo "[INFO] Snapshot of tags appended to $LOG"

# Pull & recreate
echo "[INFO] Pulling images..."
docker compose pull

echo "[INFO] Recreating containers..."
docker compose up -d

echo "[INFO] Basic health checks..."
FAIL=0

check_container(){
  local name=$1
  local tries=${2:-5}
  local delay=${3:-3}
  echo -n "[CHECK] $name: "
  for i in $(seq 1 $tries); do
    if docker ps --format '{{.Names}}' | grep -q "^$name$"; then
      # If container has health status and it's healthy
      STATUS=$(docker inspect --format='{{json .State.Health.Status}}' "$name" 2>/dev/null || echo '"unknown"')
      STATUS=${STATUS//"/}
      if [[ "$STATUS" == "healthy" || "$STATUS" == "starting" || "$STATUS" == "unknown" ]]; then
        echo "OK ($STATUS)"; return 0
      fi
    fi
    sleep "$delay"
  done
  echo "FAIL"; return 1
}

for c in database_cont slam_cont nav_cont laser_driver_cont rosbridge_websocket_cont sensor_fusion_cont; do
  if ! check_container "$c"; then FAIL=1; fi
done

if [[ $FAIL -eq 0 ]]; then
  echo "[INFO] Deployment complete."
else
  echo "[WARN] Some containers failed health checks." >&2
fi

exit $FAIL
