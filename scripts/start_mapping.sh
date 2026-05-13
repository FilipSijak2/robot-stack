#!/usr/bin/env bash
set -euo pipefail
# Stop containers not needed during mapping to free CPU/RAM on RPi 5.
# nav_cont is restarted in MAPPING_MODE=1 (cmd_vel_mux only, no Nav2) so
# /set_manual_mode service stays available during mapping.
# Keeps: database_cont, slam_cont, sensor_fusion_cont, robot_bridge,
#        laser_driver, rosbridge_websocket, foxglove_bridge (optional, for live preview)
#
# Usage:
#   scripts/start_mapping.sh           # stop unneeded, then drop into slam_cont
#   scripts/start_mapping.sh --no-viz  # also stop foxglove/rosbridge

REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
cd "$REPO_ROOT"

NO_VIZ=0
for arg in "$@"; do
    [ "$arg" = "--no-viz" ] && NO_VIZ=1
done

STOP_SERVICES=(
    ai_kit_cont
    bag_recorder_cont
    bag_browser
    container_log_collector
    healthcheck_cont
)

if [ "$NO_VIZ" = "1" ]; then
    STOP_SERVICES+=(foxglove_bridge rosbridge_websocket)
fi

echo "[start_mapping] Stopping unneeded containers..."
docker compose stop "${STOP_SERVICES[@]}" 2>/dev/null || true
echo "[start_mapping] Stopped: ${STOP_SERVICES[*]}"

echo "[start_mapping] Restarting nav_cont in mapping mode (cmd_vel_mux only, no Nav2)..."
docker compose stop nav_cont 2>/dev/null || true
MAPPING_MODE=1 docker compose up -d nav_cont
echo ""
echo "[start_mapping] Running containers:"
docker compose ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null || docker ps --format "table {{.Names}}\t{{.Status}}"
echo ""
echo "[start_mapping] Entering slam_cont. Run: ./run_mapping.sh"
echo "[start_mapping] When done, run: scripts/stop_mapping.sh"
echo ""
docker exec -it slam_cont bash
