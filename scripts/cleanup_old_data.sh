#!/usr/bin/env bash
set -euo pipefail
# Deletes bag files and log files older than RETENTION_DAYS (default: 3) days.
# Run from any directory; paths are resolved relative to the repo root.
#
# Usage:
#   scripts/cleanup_old_data.sh              # dry-run (preview only)
#   scripts/cleanup_old_data.sh --delete     # actually delete
#   RETENTION_DAYS=7 scripts/cleanup_old_data.sh --delete
#
# Designed to be called from a cron job on the RPi host, e.g.:
#   0 3 * * * /home/pi/stack/scripts/cleanup_old_data.sh --delete >> /home/pi/stack/logs/cleanup.log 2>&1
#
# IMPORTANT: the --delete flag is required; without it the script runs in
# dry-run mode and prints what would be deleted but removes nothing.

REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
BAGS_DIR="$REPO_ROOT/bags"
LOGS_DIR="$REPO_ROOT/logs"
RETENTION_DAYS="${RETENTION_DAYS:-3}"
DRY_RUN=1

# ---- argument parsing ----
for arg in "$@"; do
    case "$arg" in
        --delete) DRY_RUN=0 ;;
        --dry-run) DRY_RUN=1 ;;
        --help)
            echo "Usage: $0 [--delete|--dry-run]"
            echo "  --delete   actually remove files (default is dry-run)"
            echo "  RETENTION_DAYS=N  keep files newer than N days (default: 3)"
            exit 0
            ;;
        *) echo "[ERROR] Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

TIMESTAMP="$(date '+%Y-%m-%dT%H:%M:%S')"
echo "[$TIMESTAMP] cleanup_old_data.sh start (retention=${RETENTION_DAYS}d, dry_run=${DRY_RUN})"

deleted_count=0
deleted_bytes=0

delete_old() {
    local dir="$1"
    local label="$2"

    if [ ! -d "$dir" ]; then
        echo "[WARN] $label directory not found: $dir — skipping"
        return
    fi

    echo "[INFO] Scanning $label: $dir"

    # Bag sessions are directories (ROS 2 bag = folder with metadata.yaml + .db3/.mcap).
    # Also catch any stray plain files (e.g. exported .mcap files at top level).
    while IFS= read -r -d '' entry; do
        # Get size before deletion (in bytes, works for files and dirs via du)
        size_kb=$(du -sk "$entry" 2>/dev/null | awk '{print $1}')
        size_kb=${size_kb:-0}
        size_bytes=$(( size_kb * 1024 ))

        if [ "$DRY_RUN" -eq 1 ]; then
            echo "[DRY-RUN] would delete: $entry (${size_kb} KB)"
        else
            echo "[DELETE] $entry (${size_kb} KB)"
            rm -rf -- "$entry"
            deleted_count=$(( deleted_count + 1 ))
            deleted_bytes=$(( deleted_bytes + size_bytes ))
        fi
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -mtime +"$RETENTION_DAYS" -print0)
}

delete_old "$BAGS_DIR" "bags"
delete_old "$LOGS_DIR" "logs"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "[INFO] Dry-run complete. Run with --delete to actually remove files."
else
    freed_mb=$(( deleted_bytes / 1048576 ))
    echo "[INFO] Done. Removed ${deleted_count} entries, freed ~${freed_mb} MB."
fi

# Rotate cleanup.log itself: keep only the last 500 lines to prevent unbounded growth.
CLEANUP_LOG="$LOGS_DIR/cleanup.log"
if [ -f "$CLEANUP_LOG" ]; then
    tail -n 500 "$CLEANUP_LOG" > "${CLEANUP_LOG}.tmp" && mv "${CLEANUP_LOG}.tmp" "$CLEANUP_LOG"
fi
