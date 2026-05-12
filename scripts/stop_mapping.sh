#!/usr/bin/env bash
set -euo pipefail
# Restart all containers stopped by start_mapping.sh after mapping is done.
# Usage:
#   scripts/stop_mapping.sh

REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
cd "$REPO_ROOT"

echo "[stop_mapping] Starting all containers..."
docker compose up -d
echo "[stop_mapping] Done."
