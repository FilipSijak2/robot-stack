#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${TEXTFILE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/monitoring/textfile}"
OUT_FILE="${OUT_DIR}/rpi_robot.prom"
TMP_FILE="${OUT_FILE}.tmp"
INTERVAL_S="${RPI_METRICS_INTERVAL_S:-15}"

mkdir -p "${OUT_DIR}"

write_metrics_once() {
  local now
  now="$(date +%s)"
  : > "${TMP_FILE}"

  {
    echo "# HELP rpi_robot_metrics_timestamp_seconds Unix timestamp when custom RPi metrics were collected."
    echo "# TYPE rpi_robot_metrics_timestamp_seconds gauge"
    echo "rpi_robot_metrics_timestamp_seconds ${now}"
  } >> "${TMP_FILE}"

  if [ -r /sys/class/thermal/thermal_zone0/temp ]; then
    local temp_raw temp_c
    temp_raw="$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)"
    temp_c="$(awk -v t="${temp_raw}" 'BEGIN { printf "%.3f", t / 1000.0 }')"
    {
      echo "# HELP rpi_cpu_temperature_celsius Raspberry Pi CPU temperature in Celsius."
      echo "# TYPE rpi_cpu_temperature_celsius gauge"
      echo "rpi_cpu_temperature_celsius ${temp_c}"
    } >> "${TMP_FILE}"
  fi

  if command -v vcgencmd >/dev/null 2>&1; then
    local throttled_raw throttled_dec undervoltage_now throttled_now arm_freq
    throttled_raw="$(vcgencmd get_throttled 2>/dev/null | awk -F= '{print $2}' || echo 0x0)"
    throttled_dec=$((throttled_raw))
    undervoltage_now=$(( (throttled_dec & 0x1) ? 1 : 0 ))
    throttled_now=$(( (throttled_dec & 0x4) ? 1 : 0 ))
    arm_freq="$(vcgencmd measure_clock arm 2>/dev/null | awk -F= '{ printf "%.0f", $2 }' || echo 0)"
    {
      echo "# HELP rpi_throttled_flags Raw vcgencmd get_throttled bitfield."
      echo "# TYPE rpi_throttled_flags gauge"
      echo "rpi_throttled_flags ${throttled_dec}"
      echo "# HELP rpi_undervoltage_now 1 if Raspberry Pi reports current undervoltage."
      echo "# TYPE rpi_undervoltage_now gauge"
      echo "rpi_undervoltage_now ${undervoltage_now}"
      echo "# HELP rpi_throttled_now 1 if Raspberry Pi reports current frequency throttling."
      echo "# TYPE rpi_throttled_now gauge"
      echo "rpi_throttled_now ${throttled_now}"
      echo "# HELP rpi_arm_clock_hertz Current ARM clock frequency from vcgencmd."
      echo "# TYPE rpi_arm_clock_hertz gauge"
      echo "rpi_arm_clock_hertz ${arm_freq}"
    } >> "${TMP_FILE}"
  fi

  if command -v docker >/dev/null 2>&1; then
    {
      echo "# HELP docker_container_cpu_percent Docker container CPU percent from docker stats snapshot."
      echo "# TYPE docker_container_cpu_percent gauge"
      echo "# HELP docker_container_mem_usage_bytes Docker container memory usage from docker stats snapshot."
      echo "# TYPE docker_container_mem_usage_bytes gauge"
    } >> "${TMP_FILE}"

    docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' 2>/dev/null | while IFS='|' read -r name cpu mem; do
      [ -n "${name}" ] || continue
      local cpu_num mem_usage mem_unit mem_bytes safe_name
      cpu_num="$(printf '%s' "${cpu}" | tr -d '%' | tr ',' '.')"
      mem_usage="$(printf '%s' "${mem}" | awk -F/ '{print $1}' | xargs | sed 's/,/./g')"
      mem_unit="$(printf '%s' "${mem_usage}" | sed -E 's/[0-9. ]//g')"
      mem_num="$(printf '%s' "${mem_usage}" | sed -E 's/[^0-9.]//g')"
      mem_bytes="$(awk -v n="${mem_num:-0}" -v u="${mem_unit}" 'BEGIN {
        if (u == "KiB") m=1024;
        else if (u == "MiB") m=1024*1024;
        else if (u == "GiB") m=1024*1024*1024;
        else if (u == "kB") m=1000;
        else if (u == "MB") m=1000*1000;
        else if (u == "GB") m=1000*1000*1000;
        else if (u == "B") m=1;
        else m=1;
        printf "%.0f", n*m;
      }')"
      safe_name="$(printf '%s' "${name}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
      echo "docker_container_cpu_percent{container=\"${safe_name}\"} ${cpu_num:-0}" >> "${TMP_FILE}"
      echo "docker_container_mem_usage_bytes{container=\"${safe_name}\"} ${mem_bytes:-0}" >> "${TMP_FILE}"
    done
  fi

  mv "${TMP_FILE}" "${OUT_FILE}"
}

if [ "${1:-}" = "--once" ]; then
  write_metrics_once
  exit 0
fi

while true; do
  write_metrics_once || true
  sleep "${INTERVAL_S}"
done
