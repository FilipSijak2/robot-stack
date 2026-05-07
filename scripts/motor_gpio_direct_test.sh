#!/usr/bin/env bash
set -euo pipefail

# Direct GPIO motor pulse test (bypasses ROS cmd_vel path).
# This script:
# 1) Reads DRV pin config from .env + config/containers/bridge_rpi_direct.env
# 2) Stops robot_bridge container (to avoid GPIO contention)
# 3) Runs a one-off Python test inside the same bridge image
# 4) Restarts robot_bridge container
#
# Safety:
# - Lift wheels off the ground before running.
# - Keep pulse duration short.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV_FILE="$REPO_ROOT/.env"
BRIDGE_ENV_FILE="$REPO_ROOT/config/containers/bridge_rpi_direct.env"

BRIDGE_CONTAINER="${BRIDGE_CONTAINER:-robot_bridge_cont}"
MOTOR="both"            # left | right | both
DIRECTION="forward"     # forward | reverse
DUTY="30"               # 0..100
SECONDS="1.2"           # pulse duration
PWM_HZ="1000"           # software PWM frequency
KEEP_BRIDGE_STOPPED=0
CONFIRMED=0

usage() {
  cat <<'EOF'
Usage: bash scripts/motor_gpio_direct_test.sh [options] --yes

Options:
  --motor <left|right|both>      Motor side to test (default: both)
  --direction <forward|reverse>  Direction to test (default: forward)
  --duty <0..100>                PWM duty in percent (default: 30)
  --seconds <float>              Pulse duration in seconds (default: 1.2)
  --pwm-hz <int>                 PWM frequency (default: 1000)
  --bridge-container <name>      Bridge container name (default: robot_bridge_cont)
  --keep-bridge-stopped          Do not auto-restart bridge after test
  --yes                          Required safety confirmation
  -h, --help                     Show this help
EOF
}

log() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
err() { printf '[ERROR] %s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --motor)
      MOTOR="${2:-}"
      shift 2
      ;;
    --direction)
      DIRECTION="${2:-}"
      shift 2
      ;;
    --duty)
      DUTY="${2:-}"
      shift 2
      ;;
    --seconds)
      SECONDS="${2:-}"
      shift 2
      ;;
    --pwm-hz)
      PWM_HZ="${2:-}"
      shift 2
      ;;
    --bridge-container)
      BRIDGE_CONTAINER="${2:-}"
      shift 2
      ;;
    --keep-bridge-stopped)
      KEEP_BRIDGE_STOPPED=1
      shift
      ;;
    --yes)
      CONFIRMED=1
      shift
      ;;
    -h|--help)
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

if [ "$CONFIRMED" -ne 1 ]; then
  err "Refusing to run without --yes safety confirmation."
  warn "Lift wheels off ground before test."
  exit 2
fi

case "$MOTOR" in
  left|right|both) ;;
  *)
    err "--motor must be one of: left, right, both"
    exit 2
    ;;
esac

case "$DIRECTION" in
  forward|reverse) ;;
  *)
    err "--direction must be one of: forward, reverse"
    exit 2
    ;;
esac

if ! command -v docker >/dev/null 2>&1; then
  err "docker command not found."
  exit 2
fi

if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

if [ -f "$BRIDGE_ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$BRIDGE_ENV_FILE"
  set +a
fi

: "${RPI_LGPIO_CHIP:=4}"
: "${DRV_AIN1_PIN:=18}"
: "${DRV_AIN2_PIN:=23}"
: "${DRV_BIN1_PIN:=19}"
: "${DRV_BIN2_PIN:=24}"
: "${DRV_SLEEP_PIN:=-1}"
: "${BRIDGE_GPIOMEM_DEVICE:=/dev/gpiochip4}"

if [ ! -e "$BRIDGE_GPIOMEM_DEVICE" ]; then
  err "GPIO device not found on host: $BRIDGE_GPIOMEM_DEVICE"
  exit 2
fi

if ! docker inspect "$BRIDGE_CONTAINER" >/dev/null 2>&1; then
  err "Bridge container not found: $BRIDGE_CONTAINER"
  exit 2
fi

BRIDGE_IMAGE="$(docker inspect -f '{{.Config.Image}}' "$BRIDGE_CONTAINER")"
BRIDGE_RUNNING="$(docker inspect -f '{{.State.Running}}' "$BRIDGE_CONTAINER" 2>/dev/null || echo false)"
RESTART_ON_EXIT=0

cleanup() {
  if [ "$RESTART_ON_EXIT" -eq 1 ] && [ "$KEEP_BRIDGE_STOPPED" -eq 0 ]; then
    log "Restarting bridge container: $BRIDGE_CONTAINER"
    docker start "$BRIDGE_CONTAINER" >/dev/null
    ok "Bridge restarted."
  fi
}
trap cleanup EXIT

log "Test parameters:"
printf '  motor=%s direction=%s duty=%s%% seconds=%s pwm_hz=%s\n' "$MOTOR" "$DIRECTION" "$DUTY" "$SECONDS" "$PWM_HZ"
printf '  gpiochip_device=%s gpiochip_index=%s\n' "$BRIDGE_GPIOMEM_DEVICE" "$RPI_LGPIO_CHIP"
printf '  pins AIN1=%s AIN2=%s BIN1=%s BIN2=%s SLEEP=%s\n' "$DRV_AIN1_PIN" "$DRV_AIN2_PIN" "$DRV_BIN1_PIN" "$DRV_BIN2_PIN" "$DRV_SLEEP_PIN"

if [ "$BRIDGE_RUNNING" = "true" ]; then
  log "Stopping bridge container to avoid GPIO contention: $BRIDGE_CONTAINER"
  docker stop "$BRIDGE_CONTAINER" >/dev/null
  RESTART_ON_EXIT=1
fi

log "Running one-off direct GPIO test in bridge image: $BRIDGE_IMAGE"
docker run --rm \
  --privileged \
  --network host \
  --device "${BRIDGE_GPIOMEM_DEVICE}:${BRIDGE_GPIOMEM_DEVICE}" \
  -e RPI_LGPIO_CHIP="$RPI_LGPIO_CHIP" \
  -e DRV_AIN1_PIN="$DRV_AIN1_PIN" \
  -e DRV_AIN2_PIN="$DRV_AIN2_PIN" \
  -e DRV_BIN1_PIN="$DRV_BIN1_PIN" \
  -e DRV_BIN2_PIN="$DRV_BIN2_PIN" \
  -e DRV_SLEEP_PIN="$DRV_SLEEP_PIN" \
  -e TEST_MOTOR="$MOTOR" \
  -e TEST_DIRECTION="$DIRECTION" \
  -e TEST_DUTY="$DUTY" \
  -e TEST_SECONDS="$SECONDS" \
  -e TEST_PWM_HZ="$PWM_HZ" \
  --entrypoint /bin/bash \
  "$BRIDGE_IMAGE" \
  -lc "python3 - <<'PY'
import os
import time
import sys

try:
    if 'RPI_LGPIO_REVISION' not in os.environ:
        os.environ['RPI_LGPIO_REVISION'] = '0'
    import RPi.GPIO as GPIO
except Exception as exc:
    print(f'[ERROR] Failed to import RPi.GPIO: {exc}', file=sys.stderr)
    sys.exit(2)

def getenv_int(name, default):
    raw = os.environ.get(name, str(default))
    return int(raw, 0)

def getenv_float(name, default):
    return float(os.environ.get(name, str(default)))

ain1 = getenv_int('DRV_AIN1_PIN', 18)
ain2 = getenv_int('DRV_AIN2_PIN', 23)
bin1 = getenv_int('DRV_BIN1_PIN', 19)
bin2 = getenv_int('DRV_BIN2_PIN', 24)
sleep_pin = getenv_int('DRV_SLEEP_PIN', -1)

motor = os.environ.get('TEST_MOTOR', 'both').strip().lower()
direction = os.environ.get('TEST_DIRECTION', 'forward').strip().lower()
duty = max(0.0, min(100.0, getenv_float('TEST_DUTY', 30.0)))
seconds = max(0.1, getenv_float('TEST_SECONDS', 1.2))
pwm_hz = max(1, getenv_int('TEST_PWM_HZ', 1000))

if motor not in ('left', 'right', 'both'):
    print(f'[ERROR] invalid TEST_MOTOR={motor}', file=sys.stderr)
    sys.exit(2)
if direction not in ('forward', 'reverse'):
    print(f'[ERROR] invalid TEST_DIRECTION={direction}', file=sys.stderr)
    sys.exit(2)

GPIO.setwarnings(False)
GPIO.setmode(GPIO.BCM)

for pin in (ain1, ain2, bin1, bin2):
    GPIO.setup(pin, GPIO.OUT)

if sleep_pin >= 0:
    GPIO.setup(sleep_pin, GPIO.OUT)
    GPIO.output(sleep_pin, GPIO.HIGH)

pwm_ain1 = GPIO.PWM(ain1, pwm_hz)
pwm_ain2 = GPIO.PWM(ain2, pwm_hz)
pwm_bin1 = GPIO.PWM(bin1, pwm_hz)
pwm_bin2 = GPIO.PWM(bin2, pwm_hz)

for p in (pwm_ain1, pwm_ain2, pwm_bin1, pwm_bin2):
    p.start(0.0)

def set_motor_pair(cmd, pwm_pos, pwm_neg):
    if cmd > 0:
        pwm_pos.ChangeDutyCycle(duty)
        pwm_neg.ChangeDutyCycle(0.0)
    elif cmd < 0:
        pwm_pos.ChangeDutyCycle(0.0)
        pwm_neg.ChangeDutyCycle(duty)
    else:
        pwm_pos.ChangeDutyCycle(0.0)
        pwm_neg.ChangeDutyCycle(0.0)

left_cmd = 1 if direction == 'forward' else -1
right_cmd = 1 if direction == 'forward' else -1

if motor == 'left':
    right_cmd = 0
elif motor == 'right':
    left_cmd = 0

print('[INFO] Applying direct GPIO pulse...')
print(f'[INFO] motor={motor} direction={direction} duty={duty}% seconds={seconds} pwm_hz={pwm_hz}')

try:
    set_motor_pair(left_cmd, pwm_ain1, pwm_ain2)
    set_motor_pair(right_cmd, pwm_bin1, pwm_bin2)
    time.sleep(seconds)
finally:
    set_motor_pair(0, pwm_ain1, pwm_ain2)
    set_motor_pair(0, pwm_bin1, pwm_bin2)
    time.sleep(0.15)
    for p in (pwm_ain1, pwm_ain2, pwm_bin1, pwm_bin2):
        p.stop()
    GPIO.cleanup()

print('[OK] Direct GPIO pulse test finished.')
PY"

ok "Direct GPIO motor test completed."

if [ "$KEEP_BRIDGE_STOPPED" -eq 1 ] && [ "$RESTART_ON_EXIT" -eq 1 ]; then
  warn "Bridge container left stopped by request (--keep-bridge-stopped)."
fi
