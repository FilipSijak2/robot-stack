#!/usr/bin/env bash
set -euo pipefail
# Helper to switch active navigation map by session id or direct yaml path.
# Usage:
#   scripts/select_map.sh session_20251013-175951            # uses final/map.yaml if present
#   scripts/select_map.sh /srv/maps/session_*/final/map.yaml # direct path
# Environment:
#   MAP_ROOT (default /srv/maps)
#   RESTART_NAV=1 (auto restart nav_cont via docker compose or container name)
#   NAV_SERVICE=nav_cont (container/service name)

ENV_FILE="$(cd "$(dirname "$0")"/.. && pwd)/.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

: "${MAP_ROOT:=/srv/maps}"
: "${RESTART_NAV:=1}"
: "${NAV_SERVICE:=nav_cont}"
TARGET_INPUT=${1:-}
if [ -z "$TARGET_INPUT" ]; then
  if [ ! -d "$MAP_ROOT" ]; then
    echo "[select_map] MAP_ROOT not found: $MAP_ROOT" >&2
    echo "Usage: $0 <session_id | map_yaml_path>" >&2
    exit 2
  fi

  mapfile -t MAPS < <(find "$MAP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
  if [ ${#MAPS[@]} -eq 0 ]; then
    echo "[select_map] No maps found in $MAP_ROOT" >&2
    exit 2
  fi

  echo "Select map:" >&2
  for i in "${!MAPS[@]}"; do
    idx=$((i+1))
    echo "  [$idx] ${MAPS[$i]}" >&2
  done
  echo -n "Enter number: " >&2
  read -r choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
    echo "[select_map] Invalid selection" >&2
    exit 2
  fi
  sel_index=$((choice-1))
  if [ "$sel_index" -lt 0 ] || [ "$sel_index" -ge ${#MAPS[@]} ]; then
    echo "[select_map] Selection out of range" >&2
    exit 2
  fi
  TARGET_INPUT="${MAPS[$sel_index]}"
fi

resolve_yaml(){
  local inp="$1"
  if [ -f "$inp" ]; then echo "$inp"; return 0; fi
  # treat as session id
  local base="${MAP_ROOT}/${inp}"
  if [ -f "${base}/final/map.yaml" ]; then echo "${base}/final/map.yaml"; return 0; fi
  if [ -f "${base}/map.yaml" ]; then echo "${base}/map.yaml"; return 0; fi
  return 1
}

YAML_FILE=$(resolve_yaml "$TARGET_INPUT") || { echo "[select_map] Cannot resolve map yaml for '$TARGET_INPUT'" >&2; exit 1; }
SESSION_DIR=$(dirname $(dirname "$YAML_FILE"))
SESSION_NAME=$(basename "$SESSION_DIR")

# Update active symlink
mkdir -p "$MAP_ROOT"
ln -sfn "$SESSION_NAME" "$MAP_ROOT/active"

echo "[select_map] Active map now -> $YAML_FILE (session $SESSION_NAME)"

if [ "$RESTART_NAV" = "1" ]; then
  echo "[select_map] Restarting nav container ($NAV_SERVICE) to pick up map..."
  if docker compose ps -q "$NAV_SERVICE" >/dev/null 2>&1; then
    docker compose restart "$NAV_SERVICE"
  else
    docker restart "$NAV_SERVICE" || true
  fi
  echo "[select_map] Waiting 5s..."; sleep 5
  # Show loaded map param if possible
  docker exec -i "$NAV_SERVICE" bash -c "ros2 param get /map_server yaml_filename" 2>/dev/null || true
fi
