#!/usr/bin/env bash
set -euo pipefail
# Applies skip-worktree to listed files so local edits survive git pull.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$SCRIPT_DIR/protected-files.txt"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ ! -f "$MANIFEST" ]; then
  echo "Manifest not found: $MANIFEST" >&2; exit 1; fi

cd "$REPO_ROOT"

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
    "$REPO_BASENAME"/*) entry="${entry#${REPO_BASENAME}/}" ;;
  esac
  [ -z "$entry" ] && continue
  if [ -e "$REPO_ROOT/$entry" ]; then
    # If file is not tracked, skip-worktree is meaningless (git won't overwrite it on pull)
    if ! git ls-files --error-unmatch -- "$entry" >/dev/null 2>&1; then
      echo "[INFO] $entry is not tracked in git (no need for skip-worktree)." >&2
      continue
    fi
    # Only mark if not already flagged
    if git ls-files -v -- "$entry" | grep -q '^S'; then
      echo "Already skipped: $entry"
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

echo "Done. To list skipped files: git ls-files -v | grep ^S"
