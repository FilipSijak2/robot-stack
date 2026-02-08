#!/usr/bin/env bash
set -euo pipefail
# Update *_TAG values in .env to the latest tags found in the registry.
# Usage: bash scripts/update-image-tags.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing .env at $ENV_FILE" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

get_env() {
  local key="$1"
  local line
  line=$(grep -E "^${key}=" "$ENV_FILE" | tail -n 1 || true)
  echo "${line#${key}=}"
}

REGISTRY_HOST=$(get_env REGISTRY_HOST)
IMAGE_OWNER=$(get_env IMAGE_OWNER)

if [ -z "$REGISTRY_HOST" ] || [ -z "$IMAGE_OWNER" ]; then
  echo "REGISTRY_HOST or IMAGE_OWNER missing in .env" >&2
  exit 1
fi

# Map env keys to repository names
declare -A REPO_MAP=(
  [SLAM_TAG]="slam"
  [NAV_TAG]="nav"
  [DRIVER_TAG]="laser_driver"
  [DB_TAG]="db"
  [SENSOR_FUSION_TAG]="sensor_fusion"
  [BRIDGE_TAG]="bridge"
  [AI_KIT_TAG]="ai-kit"
  [CAMERA_TAG]="camera"
  [REALSENSE_TAG]="realsense"
  [BAG_RECORDER_TAG]="bag_recorder"
  [HEALTHCHECK_TAG]="healthcheck"
  [FOXGLOVE_BRIDGE_TAG]="foxglove_bridge"
)

fetch_tags() {
  local repo="$1"
  local base="${REGISTRY_HOST}/${IMAGE_OWNER}/${repo}"
  local url_http="http://${base}/tags/list"
  local url_https="https://${base}/tags/list"

  if curl -fsS "$url_http" -o /tmp/tags.json 2>/dev/null; then
    jq -r '.tags[]?' /tmp/tags.json
    return 0
  fi
  if curl -fsS "$url_https" -o /tmp/tags.json 2>/dev/null; then
    jq -r '.tags[]?' /tmp/tags.json
    return 0
  fi
  return 1
}

pick_latest_tag() {
  local repo="$1"
  local tags
  tags=$(fetch_tags "$repo" || true)
  if [ -z "$tags" ]; then
    echo ""
    return 0
  fi
  # Prefer tags starting with "${repo}-" if any
  local filtered
  filtered=$(printf "%s\n" "$tags" | grep -E "^${repo}-" || true)
  if [ -n "$filtered" ]; then
    printf "%s\n" "$filtered" | sort -V | tail -n 1
  else
    printf "%s\n" "$tags" | sort -V | tail -n 1
  fi
}

update_env_value() {
  local key="$1"
  local value="$2"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    awk -v k="$key" -v v="$value" 'BEGIN{changed=0} {if ($0 ~ "^"k"=") {print k"="v; changed=1} else {print}} END{if (!changed) print k"="v}' "$ENV_FILE" > "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
  else
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
}

for key in "${!REPO_MAP[@]}"; do
  repo="${REPO_MAP[$key]}"
  latest=$(pick_latest_tag "$repo")
  if [ -z "$latest" ]; then
    echo "[SKIP] ${repo}: no tags found"
    continue
  fi
  current=$(get_env "$key")
  if [ "$current" = "$latest" ]; then
    echo "[OK] ${repo}: already ${latest}"
  else
    echo "[UPDATE] ${repo}: ${current:-<empty>} -> ${latest}"
    update_env_value "$key" "$latest"
  fi
done
