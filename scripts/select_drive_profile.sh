#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"
PROFILE_DIR="$REPO_ROOT/config/drive_profiles"
RESTART_BRIDGE=1
CONFIRMED=0

usage() {
	cat <<'EOF'
Usage: bash scripts/select_drive_profile.sh <safe-demo|laminate|carpet> [options]

Options:
  --no-restart  Persist selection but do not recreate robot_bridge
  --yes         Confirm that the robot is stationary and the path is clear
  --show        Show the persisted profile and exit
  -h, --help    Show this help
EOF
}

if [ "${1:-}" = "--show" ]; then
	if [ -f "$ENV_FILE" ]; then
		value="$(grep -E '^DRIVE_PROFILE=' "$ENV_FILE" | tail -n1 | cut -d= -f2- || true)"
	fi
	echo "${value:-safe-demo}"
	exit 0
fi

PROFILE="${1:-}"
if [ -z "$PROFILE" ] || [ "$PROFILE" = "-h" ] || [ "$PROFILE" = "--help" ]; then
	usage
	[ -n "$PROFILE" ] && exit 0
	exit 2
fi
shift

while [ "$#" -gt 0 ]; do
	case "$1" in
	--no-restart) RESTART_BRIDGE=0 ;;
	--yes) CONFIRMED=1 ;;
	-h | --help) usage; exit 0 ;;
	*) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
	shift
done

case "$PROFILE" in
safe-demo | laminate | carpet) ;;
*) echo "ERROR: invalid drive profile: $PROFILE" >&2; exit 2 ;;
esac

PROFILE_FILE="$PROFILE_DIR/$PROFILE.env"
if [ ! -r "$PROFILE_FILE" ]; then
	echo "ERROR: profile file is missing: $PROFILE_FILE" >&2
	exit 2
fi
if [ ! -f "$ENV_FILE" ]; then
	echo "ERROR: missing $ENV_FILE (copy .env.example to .env first)" >&2
	exit 2
fi

# Validate the candidate before changing the persisted selection.
(
	cd "$REPO_ROOT"
	DRIVE_PROFILE="$PROFILE" docker compose config --quiet
)

if [ "$CONFIRMED" -ne 1 ]; then
	cat <<EOF
Selected drive profile: $PROFILE
The robot_bridge container may be recreated and motor output will be reset.
Verify that the robot is stationary, supported on the selected surface, and
that the path is clear.
EOF
	read -r -p "Type SELECT to continue: " answer
	if [ "$answer" != "SELECT" ]; then
		echo "Profile selection cancelled."
		exit 1
	fi
fi

tmp_file="$(mktemp "$REPO_ROOT/.env.drive-profile.XXXXXX")"
cleanup() { rm -f -- "$tmp_file"; }
trap cleanup EXIT

awk -v profile="$PROFILE" '
BEGIN { replaced=0 }
/^DRIVE_PROFILE=/ {
    if (!replaced) print "DRIVE_PROFILE=" profile
    replaced=1
    next
}
{ print }
END { if (!replaced) print "DRIVE_PROFILE=" profile }
' "$ENV_FILE" > "$tmp_file"
chmod --reference="$ENV_FILE" "$tmp_file" 2>/dev/null || true
mv -- "$tmp_file" "$ENV_FILE"
trap - EXIT

cd "$REPO_ROOT"
docker compose config --quiet
echo "[drive_profile] Persisted DRIVE_PROFILE=$PROFILE in .env"

if [ "$RESTART_BRIDGE" -eq 1 ]; then
	if docker compose ps -q robot_bridge 2>/dev/null | grep -q .; then
		echo "[drive_profile] Recreating robot_bridge with $PROFILE profile..."
		docker compose up -d --no-deps --force-recreate robot_bridge
		echo "[drive_profile] Effective runtime values:"
		docker exec robot_bridge_cont env \
			| grep -E '^(DRIVE_PROFILE_NAME|MOTOR_SLEW_|MOTOR_REVERSAL_|MOTOR_IMMEDIATE_STOP)=' \
			| sort
	else
		echo "[drive_profile] robot_bridge is not running; profile applies on next stack start."
	fi
fi
