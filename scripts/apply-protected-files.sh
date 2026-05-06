#!/usr/bin/env bash
set -euo pipefail
# Applies skip-worktree to listed files so local edits survive git pull.
# Usage:
#   bash apply-protected-files.sh                 # normal (only mark if clean index state)
#   bash apply-protected-files.sh --force         # force: reset index to HEAD (keeping your working copy), then mark skip-worktree
#   bash apply-protected-files.sh --backup        # copy protected files into .git/protected-backups & checkout HEAD versions (prep for pull)
#   bash apply-protected-files.sh --restore       # restore from backups then mark skip-worktree
#   bash apply-protected-files.sh --pull origin devel  # convenience: backup -> git pull origin devel -> restore & skip
# Notes:
#  - backup/restore bypass limitations of skip-worktree during pull (Git still blocks if working tree has local mods)
#  - manifest itself (protected-files.txt) is never auto-backed up/restored to avoid recursion issues
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$SCRIPT_DIR/protected-files.txt"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

FORCE=0; MODE="apply"; PULL_REMOTE=""; PULL_BRANCH=""
case "${1:-}" in
  --force)
    FORCE=1; shift || true
    echo "[INFO] Force mode enabled: index entries will be reset to HEAD while preserving working copy" >&2 ;;
  --backup)
    MODE="backup"; shift || true
    echo "[INFO] Backup mode: saving protected file contents & checking out HEAD versions" >&2 ;;
  --restore)
    MODE="restore"; shift || true
    echo "[INFO] Restore mode: restoring backups & applying skip-worktree" >&2 ;;
  --pull)
    MODE="pull"; shift || true
    PULL_REMOTE="${1:-origin}"; PULL_BRANCH="${2:-devel}"; shift 2 || true
    echo "[INFO] Pull mode: will backup, git pull ${PULL_REMOTE} ${PULL_BRANCH}, then restore+skip" >&2 ;;
esac

BACKUP_ROOT="$REPO_ROOT/.git/protected-backups"
mkdir -p "$BACKUP_ROOT" 2>/dev/null || true

restore_one(){
  rel="$1"
  src="$BACKUP_ROOT/$rel"
  if [ -f "$src" ]; then
    mkdir -p "$(dirname "$REPO_ROOT/$rel")" 2>/dev/null || true
    cp "$src" "$REPO_ROOT/$rel"
    echo "[RESTORE] $rel"
  else
    echo "[RESTORE][MISS] $rel" >&2
  fi
}

backup_one(){
  rel="$1"
  if [ -f "$REPO_ROOT/$rel" ]; then
    mkdir -p "$BACKUP_ROOT/$(dirname "$rel")" 2>/dev/null || true
    cp "$REPO_ROOT/$rel" "$BACKUP_ROOT/$rel"
    echo "[BACKUP] $rel -> $BACKUP_ROOT/$rel"
  fi
}

if [ "$MODE" = "backup" ]; then
  : # proceed into loop with MODE awareness
elif [ "$MODE" = "restore" ]; then
  :
elif [ "$MODE" = "pull" ]; then
  :
fi

if [ ! -f "$MANIFEST" ]; then
  echo "Manifest not found: $MANIFEST" >&2; exit 1; fi

cd "$REPO_ROOT"

COLLECTED=()
while IFS= read -r line; do
  # Strip comments and whitespace
  entry="${line%%#*}"   # strip comments
  entry="${entry//$'\r'/}"  # remove CR if present
  entry="${entry%%+([[:space:]])}" 2>/dev/null || true
  entry="${entry##+([[:space:]])}" 2>/dev/null || true
  # Fallback trim (POSIX) if extglob not enabled
  entry="${entry## }"; entry="${entry%% }"
  entry="${entry//[$'\n']/}"
  # If user mistakenly prefixed with repo dir name (e.g. stack/.env), strip it
  REPO_BASENAME="$(basename "$REPO_ROOT")"
  case "$entry" in
    "$REPO_BASENAME"/*) entry="${entry#"${REPO_BASENAME}"/}" ;;
  esac
  [ -z "$entry" ] && continue
  # Auto-resolve common nesting (e.g. user wrote 'static_tf.yaml' but file is under config/containers/static_tf.yaml)
  if [ ! -e "$REPO_ROOT/$entry" ] && [[ "$entry" != */* ]]; then
    if [ -e "$REPO_ROOT/config/containers/$entry" ]; then
      echo "[INFO] Auto-resolving $entry -> config/containers/$entry" >&2
      entry="config/containers/$entry"
    elif [ -e "$REPO_ROOT/config/$entry" ]; then
      echo "[INFO] Auto-resolving $entry -> config/$entry" >&2
      entry="config/$entry"
    fi
  fi

  COLLECTED+=("$entry")
  if [ "$MODE" = "backup" ]; then
    backup_one "$entry"
    # Ensure file is not marked skip so checkout works
    if git ls-files -v -- "$entry" | grep -q '^S'; then
      git update-index --no-skip-worktree "$entry" 2>/dev/null || true
      echo "[UNSKIP] $entry" >&2
    fi
    # Force checkout HEAD version (discard index/worktree diff) to make merge clean
    if git ls-files --error-unmatch -- "$entry" >/dev/null 2>&1; then
      git checkout HEAD -- "$entry" 2>/dev/null || true
      echo "[CHECKOUT-HEAD] $entry" >&2
    fi
    continue
  fi
  if [ "$MODE" = "restore" ]; then
    restore_one "$entry"
    # fall through to apply skip-worktree after restore
  fi
  if [ -e "$REPO_ROOT/$entry" ]; then
    # If file is not tracked, skip-worktree is meaningless (git won't overwrite it on pull)
    if ! git ls-files --error-unmatch -- "$entry" >/dev/null 2>&1; then
      echo "[INFO] $entry is not tracked in git (no need for skip-worktree)." >&2
      continue
    fi
    # Always (re)sync index if force and file differs OR already skipped but dirty
    if [ $FORCE -eq 1 ]; then
      if ! git diff --quiet -- "$entry" 2>/dev/null || ! git diff --quiet --cached -- "$entry" 2>/dev/null; then
        tree_line=$(git ls-tree HEAD -- "$entry" || true)
        if [ -n "$tree_line" ]; then
          mode=$(echo "$tree_line" | awk '{print $1}')
          blob=$(echo "$tree_line" | awk '{print $3}')
          if [ -n "$mode" ] && [ -n "$blob" ]; then
            if git update-index --cacheinfo "$mode","$blob","$entry" 2>/dev/null; then
              echo "[INFO] Index reset to HEAD for $entry (working copy preserved)" >&2
            else
              echo "[WARN] Failed to reset index for $entry" >&2
            fi
          fi
        fi
      fi
    fi
    # (Re)apply skip-worktree (idempotent)
    if git ls-files -v -- "$entry" | grep -q '^S'; then
      # ensure flag remains after potential index reset
      git update-index --skip-worktree "$entry" 2>/dev/null || true
      echo "Skipped (already): $entry"
    else
      if git update-index --skip-worktree "$entry" 2>/dev/null; then
        echo "Marked skip-worktree: $entry"
      else
        echo "[ERROR] Failed to mark skip-worktree: $entry" >&2
      fi
    fi
  else
    echo "[WARN] Listed file does not exist (skipping): $entry" >&2
  fi
done < "$MANIFEST"

if [ "$MODE" = "pull" ]; then
  echo "[INFO] Pull mode step 1/3: backup"
  bash "$SCRIPT_DIR/$(basename "$0")" --backup
  echo "[INFO] Pull mode step 2/3: git pull $PULL_REMOTE $PULL_BRANCH"
  if ! git pull "$PULL_REMOTE" "$PULL_BRANCH"; then
    echo "[ERROR] git pull failed; restore your backups manually with --restore" >&2
    exit 2
  fi
  echo "[INFO] Pull mode step 3/3: restore & apply skip-worktree"
  bash "$SCRIPT_DIR/$(basename "$0")" --restore
  echo "[INFO] Pull mode finished"
  exit 0
fi

case "$MODE" in
  backup) echo "Backup complete. Now run: git pull <remote> <branch>  &&  bash $SCRIPT_DIR/$(basename "$0") --restore" ;;
  restore|apply) echo "Done. To list skipped files: git ls-files -v | grep ^S" ;;
esac
