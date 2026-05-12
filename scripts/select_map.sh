#!/usr/bin/env bash
set -euo pipefail
# Helper to switch active navigation map by session id or direct yaml path.
# Usage:
#   scripts/select_map.sh session_20251013-175951            # uses final/map.yaml if present
#   scripts/select_map.sh /srv/maps/session_*/final/map.yaml # direct path
# Environment:
#   MAP_ROOT (container path, default /srv/maps)
#   MAP_ROOT_HOST (host path, default <repo>/srv/maps)
#   MAP_CONFIG_FILE (default <repo>/config/containers/map.yaml)
#   RESTART_NAV=1 (auto restart nav_cont via docker compose or container name)
#   NAV_SERVICE=nav_cont (container/service name)

REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
ENV_FILE="$REPO_ROOT/.env"
if [ -f "$ENV_FILE" ]; then
	set -a
	# shellcheck disable=SC1090
	. "$ENV_FILE"
	set +a
fi

: "${MAP_ROOT:=/srv/maps}"
: "${MAP_ROOT_HOST:=$REPO_ROOT/srv/maps}"
: "${MAP_CONFIG_FILE:=$REPO_ROOT/config/containers/map.yaml}"
: "${RESTART_NAV:=1}"
: "${NAV_SERVICE:=nav_cont}"

# Read START_SLAM_TOOLBOX from slam_cont.env to know whether slam_toolbox localization is active.
# If 0 (AMCL mode), skip posegraph requirement and slam_cont restart.
SLAM_CONT_ENV="$REPO_ROOT/config/containers/slam_cont.env"
START_SLAM_TOOLBOX="0"
if [ -f "$SLAM_CONT_ENV" ]; then
	_val=$(grep -E '^START_SLAM_TOOLBOX=' "$SLAM_CONT_ENV" | tail -n1 | cut -d'=' -f2- | tr -d '[:space:]"'"'"')
	[ -n "$_val" ] && START_SLAM_TOOLBOX="$_val"
fi
USE_SLAM_TOOLBOX_LOCALIZATION=0
if [ "$START_SLAM_TOOLBOX" != "0" ] && [ "$START_SLAM_TOOLBOX" != "false" ] && [ "$START_SLAM_TOOLBOX" != "no" ] && [ "$START_SLAM_TOOLBOX" != "off" ]; then
	USE_SLAM_TOOLBOX_LOCALIZATION=1
fi

MAP_ROOT_FS="$MAP_ROOT"
if [ -n "$MAP_ROOT_HOST" ] && [ -d "$MAP_ROOT_HOST" ]; then
	MAP_ROOT_FS="$MAP_ROOT_HOST"
fi
TARGET_INPUT=${1:-}
if [ -z "$TARGET_INPUT" ]; then
	if [ ! -d "$MAP_ROOT_FS" ]; then
		echo "[select_map] MAP_ROOT not found: $MAP_ROOT_FS" >&2
		echo "Usage: $0 <session_id | map_yaml_path>" >&2
		exit 2
	fi

	mapfile -t MAPS < <(find "$MAP_ROOT_FS" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
	if [ ${#MAPS[@]} -eq 0 ]; then
		echo "[select_map] No maps found in $MAP_ROOT" >&2
		exit 2
	fi

	echo "Select map:" >&2
	for i in "${!MAPS[@]}"; do
		idx=$((i + 1))
		echo "  [$idx] ${MAPS[$i]}" >&2
	done
	echo -n "Enter number: " >&2
	read -r choice
	if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
		echo "[select_map] Invalid selection" >&2
		exit 2
	fi
	sel_index=$((choice - 1))
	if [ "$sel_index" -lt 0 ] || [ "$sel_index" -ge ${#MAPS[@]} ]; then
		echo "[select_map] Selection out of range" >&2
		exit 2
	fi
	TARGET_INPUT="${MAPS[$sel_index]}"
fi

resolve_yaml() {
	local inp="$1"
	if [ -f "$inp" ]; then
		echo "$inp"
		return 0
	fi
	# treat as session id
	local base="${MAP_ROOT_FS}/${inp}"
	if [ -f "${base}/final/map.yaml" ]; then
		echo "${base}/final/map.yaml"
		return 0
	fi
	if [ -f "${base}/map.yaml" ]; then
		echo "${base}/map.yaml"
		return 0
	fi
	return 1
}

YAML_FILE=$(resolve_yaml "$TARGET_INPUT") || {
	echo "[select_map] Cannot resolve map yaml for '$TARGET_INPUT'" >&2
	exit 1
}
SESSION_DIR=$(dirname "$YAML_FILE")
# If yaml is in a "final/" subdirectory, the session root is one level up
if [ "$(basename "$SESSION_DIR")" = "final" ]; then
	SESSION_DIR=$(dirname "$SESSION_DIR")
fi
SESSION_NAME=$(basename "$SESSION_DIR")

# Write selected map into config map.yaml (no symlink usage)
MAP_DIR_HOST=$(dirname "$YAML_FILE")
MAP_DIR_CONTAINER="$MAP_DIR_HOST"
if [[ "$MAP_DIR_HOST" == "$MAP_ROOT_FS"* ]]; then
	MAP_DIR_CONTAINER="$MAP_ROOT${MAP_DIR_HOST#"$MAP_ROOT_FS"}"
fi

IMAGE_LINE=$(grep -E '^image:' "$YAML_FILE" | head -n1 | cut -d':' -f2- | xargs || true)
if [ -z "$IMAGE_LINE" ]; then
	echo "[select_map] Invalid map.yaml (missing image:)" >&2
	exit 1
fi

if [[ "$IMAGE_LINE" != /* ]]; then
	IMAGE_LINE="$MAP_DIR_CONTAINER/$IMAGE_LINE"
fi

mkdir -p "$(dirname "$MAP_CONFIG_FILE")"
awk -v img="$IMAGE_LINE" 'BEGIN{done=0} /^image:/ {print "image: "img; done=1; next} {print} END{if (!done) print "image: "img}' "$YAML_FILE" >"$MAP_CONFIG_FILE"

echo "[select_map] Selected map -> $YAML_FILE (session $SESSION_NAME)"
echo "[select_map] Wrote config map -> $MAP_CONFIG_FILE"

# Update slam_params.yaml map_file_name so localization_slam_toolbox_node loads the correct map.
# slam_toolbox localization needs the serialized pose graph (.posegraph + .data), not the occupancy grid.
# The serialized files are saved by run_mapping.sh alongside the occupancy grid (same base name, no extension).
SLAM_PARAMS_FILE="${REPO_ROOT}/config/containers/slam_params.yaml"
POSEGRAPH_BASE="${MAP_DIR_CONTAINER}/map"
if [ "$USE_SLAM_TOOLBOX_LOCALIZATION" = "1" ]; then
	if [ -f "${MAP_DIR_HOST}/map.posegraph" ]; then
		if [ -f "$SLAM_PARAMS_FILE" ]; then
			# Replace map_file_name value with container-side path (no extension, slam_toolbox appends it)
			sed -i "s|map_file_name:.*|map_file_name: \"${POSEGRAPH_BASE}\"|" "$SLAM_PARAMS_FILE"
			echo "[select_map] Updated slam_params.yaml map_file_name -> ${POSEGRAPH_BASE}"
		else
			echo "[select_map] WARNING: slam_params.yaml not found at $SLAM_PARAMS_FILE – slam localization map not updated" >&2
		fi
	else
		echo "[select_map] WARNING: No .posegraph file found at ${MAP_DIR_HOST}/map.posegraph" >&2
		echo "[select_map]   Run a mapping session first (run_mapping.sh) to generate the pose graph." >&2
	fi
else
	echo "[select_map] AMCL mode (START_SLAM_TOOLBOX=0) – posegraph not required, slam_params.yaml not updated."
fi

if [ "$RESTART_NAV" = "1" ]; then
	# Check whether the container is actually running before attempting a restart.
	# 'docker compose ps -q' returns exit 0 even for stopped services (empty output),
	# so we inspect the running state explicitly to avoid crashing when stack is down.
	NAV_RUNNING=$(docker compose ps -q "$NAV_SERVICE" 2>/dev/null | head -n1)
	if [ -z "$NAV_RUNNING" ]; then
		echo "[select_map] $NAV_SERVICE is not running — map will be picked up on next stack start."
	else
		echo "[select_map] Restarting nav container ($NAV_SERVICE) to pick up map..."
		docker compose restart "$NAV_SERVICE" || docker restart "$NAV_SERVICE" || true
	fi
	# Restart slam_cont so localization_slam_toolbox_node loads the new pose graph.
	# Only needed when slam_toolbox localization is active (START_SLAM_TOOLBOX != 0).
	if [ "$USE_SLAM_TOOLBOX_LOCALIZATION" = "1" ]; then
		SLAM_RUNNING=$(docker compose ps -q slam_cont 2>/dev/null | head -n1)
		if [ -z "$SLAM_RUNNING" ]; then
			echo "[select_map] slam_cont is not running — updated map_file_name will be picked up on next stack start."
		else
			echo "[select_map] Restarting slam_cont to load new pose graph..."
			docker compose restart slam_cont || docker restart slam_cont || true
		fi
	fi
	echo "[select_map] Waiting 5s..."
	sleep 5
	# Show loaded map param if possible
	docker exec -i "$NAV_SERVICE" bash -c "ros2 param get /map_server yaml_filename" 2>/dev/null || true
fi
