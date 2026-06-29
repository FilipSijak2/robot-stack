#!/usr/bin/env bash
set -euo pipefail

if (($# == 0)); then
	echo "Usage: $0 <scenario> [start|end]" >&2
	echo "Example: $0 normal_straight" >&2
	exit 2
fi

exec docker exec -i bag_recorder_cont python3 /app/experiment_event.py "$@"
