#!/usr/bin/env bash
set -euo pipefail
# Deletes bag files and log files older than RETENTION_DAYS (default: 3) days.
# Run from any directory; paths are resolved relative to the repo root.
#
# Usage:
#   scripts/cleanup_old_data.sh              # dry-run (preview only)
#   scripts/cleanup_old_data.sh --delete     # actually delete
#   scripts/cleanup_old_data.sh --delete --all-bags
#   RETENTION_DAYS=7 scripts/cleanup_old_data.sh --delete
#
# Designed to be called from a cron job on the RPi host, e.g.:
#   0 3 * * * /home/raspberry/robot-stack/scripts/cleanup_old_data.sh --delete >> /home/raspberry/robot-stack/logs/cleanup.log 2>&1
#   @reboot /home/raspberry/robot-stack/scripts/cleanup_old_data.sh --delete --all-bags >> /home/raspberry/robot-stack/logs/cleanup.log 2>&1
#
# IMPORTANT: the --delete flag is required; without it the script runs in
# dry-run mode and prints what would be deleted but removes nothing.

REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
BAGS_DIR="$REPO_ROOT/bags"
LOGS_DIR="$REPO_ROOT/logs"
RETENTION_DAYS="${RETENTION_DAYS:-3}"
DRY_RUN=1
ALL_BAGS=0

if ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] RETENTION_DAYS must be a non-negative integer, got: $RETENTION_DAYS" >&2
    exit 1
fi

# ---- argument parsing ----
for arg in "$@"; do
    case "$arg" in
        --delete) DRY_RUN=0 ;;
        --dry-run) DRY_RUN=1 ;;
        --all-bags) ALL_BAGS=1 ;;
        --help)
            echo "Usage: $0 [--delete|--dry-run] [--all-bags]"
            echo "  --delete   actually remove files (default is dry-run)"
            echo "  --all-bags delete every top-level entry in bags/"
            echo "  RETENTION_DAYS=N  keep files newer than N days (default: 3)"
            exit 0
            ;;
        *) echo "[ERROR] Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

TIMESTAMP="$(date '+%Y-%m-%dT%H:%M:%S')"
NOW_EPOCH="$(date -u '+%s')"
CUTOFF_EPOCH=$(( NOW_EPOCH - RETENTION_DAYS * 86400 ))
echo "[$TIMESTAMP] cleanup_old_data.sh start (retention=${RETENTION_DAYS}d, dry_run=${DRY_RUN}, all_bags=${ALL_BAGS})"

deleted_count=0
deleted_bytes=0

delete_entry() {
    local entry="$1"
    local size_kb
    local size_bytes

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
}

bag_entry_is_old() {
    local entry="$1"
    local base
    local stamp
    local entry_epoch

    if [ "$ALL_BAGS" -eq 1 ]; then
        return 0
    fi

    base="$(basename "$entry")"
    if [[ "$base" =~ ^recording_([0-9]{8})-([0-9]{6})$ ]]; then
        stamp="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
        entry_epoch="$(date -u -d "${stamp:0:4}-${stamp:4:2}-${stamp:6:2} ${stamp:9:2}:${stamp:11:2}:${stamp:13:2}" '+%s' 2>/dev/null || true)"
        if [[ "$entry_epoch" =~ ^[0-9]+$ ]]; then
            [ "$entry_epoch" -lt "$CUTOFF_EPOCH" ]
            return
        fi
        echo "[WARN] Could not parse bag timestamp from $base; falling back to mtime"
    fi

    [ "$(find "$entry" -maxdepth 0 -mtime +"$RETENTION_DAYS" -print -quit)" = "$entry" ]
}

delete_old() {
    local dir="$1"
    local label="$2"

    if [ ! -d "$dir" ]; then
        echo "[WARN] $label directory not found: $dir - skipping"
        return
    fi

    echo "[INFO] Scanning $label: $dir"

    while IFS= read -r -d '' entry; do
        delete_entry "$entry"
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -mtime +"$RETENTION_DAYS" -print0)
}

delete_old_bags() {
    local dir="$1"

    if [ ! -d "$dir" ]; then
        echo "[WARN] bags directory not found: $dir - skipping"
        return
    fi

    echo "[INFO] Scanning bags: $dir"

    # ROS 2 bag sessions are directories named recording_YYYYMMDD-HHMMSS.
    # Use that timestamp first because directory mtimes can change after copying
    # or inspecting a bag, which makes old recordings look new to find -mtime.
    while IFS= read -r -d '' entry; do
        if bag_entry_is_old "$entry"; then
            delete_entry "$entry"
        fi
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0)
}

delete_old_bags "$BAGS_DIR"
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
