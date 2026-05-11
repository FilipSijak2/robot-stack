#!/usr/bin/env bash
set -euo pipefail

# Quick motor + odometry smoke test for the stack on Raspberry Pi.
# It verifies bridge runtime flags, sends a short /cmd_vel pulse directly
# to robot_bridge, and prints key ROS topics for diagnosis.
#
# Usage:
#   bash scripts/motor_smoke_test.sh
#   bash scripts/motor_smoke_test.sh --linear 0.10 --angular 0.0 --duration 2 --rate 20
#   bash scripts/motor_smoke_test.sh --bridge robot_bridge_cont --nav nav_cont

BRIDGE_CONTAINER="robot_bridge_cont"
NAV_CONTAINER="nav_cont"
LINEAR_SPEED="0.12"
ANGULAR_SPEED="0.00"
DURATION_S="2"
PUB_RATE_HZ="20"

usage() {
	cat <<'EOF'
Usage: bash scripts/motor_smoke_test.sh [options]

Options:
  --bridge <name>    Bridge container name (default: robot_bridge_cont)
  --nav <name>       Nav container name (default: nav_cont)
  --linear <mps>     Linear speed for test command (default: 0.12)
  --angular <rps>    Angular speed for test command (default: 0.00)
  --duration <sec>   Publish duration in seconds (default: 2)
  --rate <hz>        Publish rate in Hz (default: 20)
  -h, --help         Show this help
EOF
}

log() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
err() { printf '[ERROR] %s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
	case "$1" in
	--bridge)
		BRIDGE_CONTAINER="${2:-}"
		shift 2
		;;
	--nav)
		NAV_CONTAINER="${2:-}"
		shift 2
		;;
	--linear)
		LINEAR_SPEED="${2:-}"
		shift 2
		;;
	--angular)
		ANGULAR_SPEED="${2:-}"
		shift 2
		;;
	--duration)
		DURATION_S="${2:-}"
		shift 2
		;;
	--rate)
		PUB_RATE_HZ="${2:-}"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		err "Unknown argument: $1"
		usage >&2
		exit 2
		;;
	esac
done

if ! command -v docker >/dev/null 2>&1; then
	err "docker command not found."
	exit 2
fi

is_running() {
	local name="$1"
	docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -q '^true$'
}

if ! is_running "$BRIDGE_CONTAINER"; then
	err "Bridge container is not running: $BRIDGE_CONTAINER"
	exit 2
fi
if ! is_running "$NAV_CONTAINER"; then
	err "Nav container is not running: $NAV_CONTAINER"
	exit 2
fi

ok "Containers are running: bridge=$BRIDGE_CONTAINER nav=$NAV_CONTAINER"

log "Bridge runtime flags:"
BRIDGE_ENV_DUMP="$(docker exec -i "$BRIDGE_CONTAINER" env | grep -E 'BRIDGE_MODE|ENCODERS_ENABLED|OPEN_LOOP_ODOM_FROM_CMD|DRV_|I2C_|WHEEL_|RPI_LGPIO_CHIP|LEFT_MUX_CHANNEL|RIGHT_MUX_CHANNEL' || true)"
printf '%s\n' "$BRIDGE_ENV_DUMP"
if printf '%s\n' "$BRIDGE_ENV_DUMP" | grep -q '^OPEN_LOOP_ODOM_FROM_CMD=1$'; then
	warn "OPEN_LOOP_ODOM_FROM_CMD=1 -> odometry can move from cmd_vel without real wheel movement."
fi
if printf '%s\n' "$BRIDGE_ENV_DUMP" | grep -q '^ENCODERS_ENABLED=0$'; then
	warn "ENCODERS_ENABLED=0 -> no real encoder feedback is used by bridge."
fi

log "Initial /robot_status (single sample):"
docker exec -i "$NAV_CONTAINER" bash -lc "source /opt/ros/humble/setup.bash && timeout 5s ros2 topic echo /robot_status --once" || warn "Could not read /robot_status."

log "Topic wiring quick check:"
docker exec -i "$NAV_CONTAINER" bash -lc "source /opt/ros/humble/setup.bash && ros2 topic info /cmd_vel && ros2 topic info /wheel_odom && ros2 topic info /odometry/filtered" || warn "Topic info failed."

log "Sending /cmd_vel pulse directly via bridge container."
docker exec -i "$BRIDGE_CONTAINER" bash -lc "source /opt/ros/humble/setup.bash && timeout ${DURATION_S}s ros2 topic pub -r ${PUB_RATE_HZ} /cmd_vel geometry_msgs/msg/Twist \"{linear: {x: ${LINEAR_SPEED}, y: 0.0, z: 0.0}, angular: {x: 0.0, y: 0.0, z: ${ANGULAR_SPEED}}}\" >/dev/null && ros2 topic pub --once /cmd_vel geometry_msgs/msg/Twist \"{linear: {x: 0.0, y: 0.0, z: 0.0}, angular: {x: 0.0, y: 0.0, z: 0.0}}\" >/dev/null"
ok "Command pulse sent."

log "Post-command /robot_status (single sample):"
docker exec -i "$NAV_CONTAINER" bash -lc "source /opt/ros/humble/setup.bash && timeout 5s ros2 topic echo /robot_status --once" || warn "Could not read post-command /robot_status."

log "One sample from /wheel_odom:"
docker exec -i "$NAV_CONTAINER" bash -lc "source /opt/ros/humble/setup.bash && timeout 5s ros2 topic echo /wheel_odom --once" || warn "Could not read /wheel_odom."

log "One sample from /odometry/filtered:"
docker exec -i "$NAV_CONTAINER" bash -lc "source /opt/ros/humble/setup.bash && timeout 5s ros2 topic echo /odometry/filtered --once" || warn "Could not read /odometry/filtered."

log "Current /wheel_odom rate (4s window):"
docker exec -i "$NAV_CONTAINER" bash -lc "source /opt/ros/humble/setup.bash && timeout 4s ros2 topic hz /wheel_odom" || warn "Could not measure /wheel_odom rate."

ok "Smoke test complete."
printf '\n'
printf 'Interpretation hints:\n'
printf '  - If wheels do not spin but /cmd_vel pulse was sent: motor power/wiring/driver issue.\n'
printf '  - If wheels spin but ENC_OK_L/R stay 0 or ENC_READS does not increase: encoder/I2C path issue.\n'
printf '  - If ODOM_SRC is OPEN_LOOP: config still allows command-integrated odometry.\n'
