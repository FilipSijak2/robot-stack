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
REGISTRY_SCHEME=$(get_env REGISTRY_SCHEME)
REGISTRY_SCHEME_FALLBACK=$(get_env REGISTRY_SCHEME_FALLBACK)
IMAGE_OWNER=$(get_env IMAGE_OWNER)
REGISTRY_USER=$(get_env REGISTRY_USER)
REGISTRY_PASS=$(get_env REGISTRY_PASS)

if [ -z "$REGISTRY_HOST" ] || [ -z "$IMAGE_OWNER" ]; then
  echo "REGISTRY_HOST or IMAGE_OWNER missing in .env" >&2
  exit 1
fi

REGISTRY_SCHEME=${REGISTRY_SCHEME:-http}
REGISTRY_SCHEME_FALLBACK=${REGISTRY_SCHEME_FALLBACK:-0}
REGISTRY_HOST=${REGISTRY_HOST#http://}
REGISTRY_HOST=${REGISTRY_HOST#https://}

# Map env keys to repository names
declare -A REPO_MAP=(
  [SLAM_TAG]="slam"
  [NAV_TAG]="nav"
  [DRIVER_TAG]="laser_driver"
  [DB_TAG]="db"
  [SENSOR_FUSION_TAG]="sensor_fusion"
  [BRIDGE_TAG]="bridge"
  [AI_KIT_TAG]="ai_kit"
  [CAMERA_TAG]="camera"
  [REALSENSE_TAG]="realsense"
  [BAG_RECORDER_TAG]="bag_recorder"
  [HEALTHCHECK_TAG]="healthcheck"
  [FOXGLOVE_BRIDGE_TAG]="foxglove_bridge"
)

fetch_tags() {
  local repo="$1"
  local base="${REGISTRY_HOST}/v2/${IMAGE_OWNER}/${repo}/tags/list"
  local url_primary="${REGISTRY_SCHEME}://${base}"
  local url_fallback=""
  if [ "$REGISTRY_SCHEME_FALLBACK" = "1" ]; then
    if [ "$REGISTRY_SCHEME" = "http" ]; then
      url_fallback="https://${base}"
    elif [ "$REGISTRY_SCHEME" = "https" ]; then
      url_fallback="http://${base}"
    fi
  fi
  local auth=()
  if [ -n "${REGISTRY_USER}" ] && [ -n "${REGISTRY_PASS}" ]; then
    auth=( -u "${REGISTRY_USER}:${REGISTRY_PASS}" )
  fi

  local status
  : > /tmp/tags.json
  status=$(curl -sS -o /tmp/tags.json -w '%{http_code}' "${auth[@]}" "$url_primary" || echo 000)
  if [ "$status" = "200" ]; then
    jq -r '.tags[]?' /tmp/tags.json
    return 0
  fi

  if [ -n "$url_fallback" ]; then
    : > /tmp/tags.json
    status=$(curl -sS -o /tmp/tags.json -w '%{http_code}' "${auth[@]}" "$url_fallback" || echo 000)
    if [ "$status" = "200" ]; then
      jq -r '.tags[]?' /tmp/tags.json
      return 0
    fi
  fi

  echo "[WARN] ${repo}: registry response ${status} for ${url_primary}" >&2
  if [ "$status" = "401" ]; then
    echo "[WARN] ${repo}: authentication required (set REGISTRY_USER/REGISTRY_PASS in .env)" >&2
  fi
  if [ -s /tmp/tags.json ]; then
    echo "[WARN] ${repo}: response body: $(tr -d '\n' </tmp/tags.json | head -c 200)" >&2
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
