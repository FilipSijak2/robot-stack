#!/usr/bin/env bash
set -euo pipefail

# Robust PostgreSQL schema existence checker that works whether the DB was started
# via docker compose (any project path) or as a plain container. It auto-discovers
# a docker-compose.yaml upwards from the script location, but falls back to plain
# docker exec if the target isn't a compose service.
#
# Exit codes:
# 0 schema exists
# 1 schema missing
# 2 container/service not found or not running
# 3 database not available within timeout
# 4 unexpected internal error

SCHEMA=${SCHEMA:-robot_data}
TARGET=${1:-database_cont}   # Accept either service name or container name; default matches compose file
DB_USER=${DB_USER:-postgres}
DB_NAME=${DB_NAME:-postgres}
DB_WAIT_TIMEOUT=${DB_WAIT_TIMEOUT:-25}
VERBOSE=${VERBOSE:-0}

log(){ printf '[INFO] %s\n' "$*"; }
ok(){ printf '[OK] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*"; }
err(){ printf '[ERROR] %s\n' "$*" >&2; }
dbg(){ if [ "$VERBOSE" = 1 ]; then printf '[DBG] %s\n' "$*"; fi; }

# Allow common aliases
case "$TARGET" in
  db) TARGET="database_cont" ;;
  database) TARGET="database_cont" ;;
esac

# Locate a docker-compose file (search upward from script dir up to 4 levels)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEARCH_DIR="$SCRIPT_DIR"
FOUND_COMPOSE=""
for _ in 1 2 3 4; do
  if [ -f "$SEARCH_DIR/docker-compose.yaml" ]; then
    FOUND_COMPOSE="$SEARCH_DIR/docker-compose.yaml"; break
  fi
  SEARCH_DIR="$(dirname "$SEARCH_DIR")"
done

if [ -n "${COMPOSE_FILE:-}" ]; then
  COMPOSE_FILE_USE="$COMPOSE_FILE"
elif [ -n "$FOUND_COMPOSE" ]; then
  COMPOSE_FILE_USE="$FOUND_COMPOSE"
else
  COMPOSE_FILE_USE=""  # none found
fi

if [ -n "$COMPOSE_FILE_USE" ]; then
  COMPOSE_CMD=(docker compose -f "$COMPOSE_FILE_USE")
  dbg "Using compose file: $COMPOSE_FILE_USE"
else
  COMPOSE_CMD=(docker compose) # may still work if run in project root
  dbg "No compose file auto-found; relying on current directory context (if any)."
fi

# Try to resolve as compose service
set +e
CID=$("${COMPOSE_CMD[@]}" ps -q "$TARGET" 2>/dev/null)
set -e
MODE=""
if [ -n "$CID" ]; then
  MODE="compose"
else
  # Fallback: treat TARGET as an actual container name
  CID=$(docker ps -q --filter "name=^${TARGET}$" || true)
  if [ -n "$CID" ]; then
    MODE="container"
  fi
fi

if [ -z "$CID" ]; then
  err "Target '$TARGET' nije pronađen ni kao compose servis ni kao container."
  exit 2
fi

RUNNING=$(docker inspect -f '{{.State.Running}}' "$CID" 2>/dev/null || echo false)
if [ "$RUNNING" != "true" ]; then
  err "Target '$TARGET' postoji (ID=$CID) ali nije Running."
  exit 2
fi
ok "Target ($MODE) je running (ID: $CID)."

exec_compose(){ "${COMPOSE_CMD[@]}" exec -T "$TARGET" "$@"; }
exec_container(){ docker exec -i "$CID" "$@"; }
run_exec(){ if [ "$MODE" = compose ]; then exec_compose "$@"; else exec_container "$@"; fi; }

log "Čekam Postgres (timeout ${DB_WAIT_TIMEOUT}s)..."
ATT=0
# If user left defaults but container uses custom POSTGRES_USER/POSTGRES_DB, auto-adjust before waiting
if [ "$DB_USER" = "postgres" ] || [ "$DB_NAME" = "postgres" ]; then
  # We have to attempt a lightweight exec to read env; ignore failures (e.g. compose vs container)
  CONTAINER_POSTGRES_USER=$(run_exec /bin/sh -c "echo \${POSTGRES_USER:-}" 2>/dev/null || true)
  CONTAINER_POSTGRES_DB=$(run_exec /bin/sh -c "echo \${POSTGRES_DB:-}" 2>/dev/null || true)
  if [ -n "$CONTAINER_POSTGRES_USER" ] && [ "$DB_USER" = "postgres" ]; then
    warn "DB_USER nije specificiran; auto-detektiran POSTGRES_USER=$CONTAINER_POSTGRES_USER"
    DB_USER="$CONTAINER_POSTGRES_USER"
  fi
  if [ -n "$CONTAINER_POSTGRES_DB" ] && [ "$DB_NAME" = "postgres" ]; then
    warn "DB_NAME nije specificiran; auto-detektiran POSTGRES_DB=$CONTAINER_POSTGRES_DB"
    DB_NAME="$CONTAINER_POSTGRES_DB"
  fi
fi
while : ; do
  if run_exec pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
    ok "Postgres prihvaća konekcije."
    break
  fi
  if run_exec psql -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT 1" >/dev/null 2>&1; then
    ok "Postgres prihvaća konekcije (psql fallback)."
    break
  fi
  ATT=$((ATT+1))
  if [ "$ATT" -ge "$DB_WAIT_TIMEOUT" ]; then
    err "Postgres nije dostupan u ${DB_WAIT_TIMEOUT}s."
    exit 3
  fi
  sleep 1
done

log "Provjera schematika '${SCHEMA}' u bazi '${DB_NAME}'..."
if run_exec psql -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT 1 FROM information_schema.schemata WHERE schema_name='${SCHEMA}'" | grep -q 1; then
  ok "Schema '${SCHEMA}' postoji."
  exit 0
else
  warn "Schema '${SCHEMA}' NE postoji."
  exit 1
fi
