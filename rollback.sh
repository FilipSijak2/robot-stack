#!/usr/bin/env bash
set -euo pipefail

# Rollback script: takes the last snapshot of tag lines from previous_tags.log
# and rewrites .env with those tags (preserving non-tag lines), then deploys.

LOG=previous_tags.log
ENV_FILE=.env
TMP=.env.tmp

if [[ ! -f "$LOG" ]]; then
  echo "[ERROR] $LOG not found (no snapshots)" >&2
  exit 1
fi
if [[ ! -f "$ENV_FILE" ]]; then
  echo "[ERROR] $ENV_FILE not found" >&2
  exit 1
fi

# Extract last block of TAG lines
LAST_BLOCK=$(tac "$LOG" | awk '/^# Snapshot /{c++; if(c==2)exit} c==1 && /^[A-Z_]+TAG=/' | tac)
if [[ -z "$LAST_BLOCK" ]]; then
  echo "[ERROR] Could not find a previous snapshot block with TAG lines." >&2
  exit 1
fi

echo "[INFO] Restoring tags:"
echo "$LAST_BLOCK"

# Build new env: keep existing non-TAG lines, append restored TAG lines
grep -Ev '^[A-Z_]+TAG=' "$ENV_FILE" > "$TMP"
echo "$LAST_BLOCK" >> "$TMP"

mv "$TMP" "$ENV_FILE"

echo "[INFO] .env updated. Re-deploying with restored tags."
./deploy.sh || {
  echo "[WARN] Deployment after rollback returned non-zero status" >&2
  exit 1
}

echo "[INFO] Rollback complete."
