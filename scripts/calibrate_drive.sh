#!/usr/bin/env bash
set -euo pipefail

# Thin host launcher. All ROS and report logic runs inside nav_cont, where
# Python/rclpy are already part of the ROS 2 runtime image.

NAV_CONTAINER="${NAV_CONTAINER:-nav_cont}"

usage() {
	cat <<'EOF'
Usage: bash scripts/calibrate_drive.sh --surface <laminate|carpet|safe-demo> [options]

Options are forwarded to /app/drive_calibration.py inside nav_cont:
  --surface <name>       Required: laminate, carpet or safe-demo
  --duration <seconds>   Command pulse duration, 1.0..5.0 (default: 2.5)
  --settle <seconds>     Settling time before final pose, 0.3..5.0 (default: 1.0)
  --repeats <count>      Repetitions per command, 1..10 (default: 3)
  --include-reverse      Include reverse straight-line tests
  --continuous           Do not pause before each movement (less safe)
  --yes                  Skip the initial typed CALIBRATE confirmation
  --odom-topic <topic>   Measurement topic (default: /odometry/filtered)
  --command-topic <topic> Command topic (default: /cmd_vel_joy)
  --manual-speed-scale <n> Override mux scale read from nav_cont environment
  --manual-angular-scale <n> Override angular mux scale from environment

Host-only option:
  --nav-container <name> Container name (default: nav_cont)

Reports are written through the /srv bind mount to:
  ./srv/calibration_results/
EOF
}

forwarded=()
while [ "$#" -gt 0 ]; do
	case "$1" in
	--nav-container)
		if [ "$#" -lt 2 ]; then
			echo "ERROR: --nav-container requires a value" >&2
			exit 2
		fi
		NAV_CONTAINER="$2"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		forwarded+=("$1")
		shift
		;;
	esac
done

if ! command -v docker >/dev/null 2>&1; then
	echo "ERROR: docker command not found" >&2
	exit 2
fi

if ! docker inspect -f '{{.State.Running}}' "$NAV_CONTAINER" 2>/dev/null | grep -q '^true$'; then
	echo "ERROR: container is not running: $NAV_CONTAINER" >&2
	exit 2
fi

if ! docker exec "$NAV_CONTAINER" test -f /app/drive_calibration.py; then
	cat >&2 <<EOF
ERROR: /app/drive_calibration.py is missing in $NAV_CONTAINER.
Deploy/rebuild the nav image containing the calibration node, then recreate nav_cont.
EOF
	exit 2
fi

docker_args=(-i)
if [ -t 0 ] && [ -t 1 ]; then
	docker_args=(-it)
fi

exec docker exec "${docker_args[@]}" "$NAV_CONTAINER" \
	bash -lc 'source /opt/ros/humble/setup.bash && exec python3 /app/drive_calibration.py "$@"' \
	calibrate_drive "${forwarded[@]}"
