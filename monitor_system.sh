#!/usr/bin/env bash
# Robot system monitoring script - monitors performance and health

set -euo pipefail

LOG_DIR="/srv/logs"
METRICS_FILE="$LOG_DIR/system_metrics.log"
STAMP=$(date -u +%Y%m%d-%H%M%S)

# Ensure log directory exists
mkdir -p "$LOG_DIR"

echo "=== Robot System Monitoring - $STAMP ===" | tee -a "$METRICS_FILE"

# Container health status
echo "--- Container Health ---" | tee -a "$METRICS_FILE"
docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" | tee -a "$METRICS_FILE"

# Resource usage
echo -e "\n--- Resource Usage ---" | tee -a "$METRICS_FILE"
docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}" | tee -a "$METRICS_FILE"

# ROS2 topic frequencies (if available)
if command -v ros2 &> /dev/null; then
    echo -e "\n--- ROS2 Topic Frequencies ---" | tee -a "$METRICS_FILE"
    
    # Check key topics
    TOPICS=("/cmd_vel" "/odom" "/scan" "/imu/data" "/tf" "/tf_static")
    
    for topic in "${TOPICS[@]}"; do
        if ros2 topic list | grep -q "^$topic$"; then
            echo -n "$topic: " | tee -a "$METRICS_FILE"
            timeout 5s ros2 topic hz "$topic" --window 10 2>/dev/null | grep "average rate" | tail -1 | tee -a "$METRICS_FILE" || echo "N/A" | tee -a "$METRICS_FILE"
        else
            echo "$topic: NOT FOUND" | tee -a "$METRICS_FILE"
        fi
    done
fi

# Hardware status
echo -e "\n--- Hardware Status ---" | tee -a "$METRICS_FILE"
echo "USB Devices:" | tee -a "$METRICS_FILE"
lsusb | grep -E "(Arduino|USB.*Serial)" | tee -a "$METRICS_FILE" || echo "No Arduino devices found" | tee -a "$METRICS_FILE"

echo "Serial Devices:" | tee -a "$METRICS_FILE"
ls -la /dev/tty{ACM,USB}* 2>/dev/null | tee -a "$METRICS_FILE" || echo "No serial devices found" | tee -a "$METRICS_FILE"

# System load
echo -e "\n--- System Load ---" | tee -a "$METRICS_FILE"
uptime | tee -a "$METRICS_FILE"
free -h | tee -a "$METRICS_FILE"

# Disk usage
echo -e "\n--- Disk Usage ---" | tee -a "$METRICS_FILE"
df -h /srv | tee -a "$METRICS_FILE"

# Log file sizes
echo -e "\n--- Log Sizes ---" | tee -a "$METRICS_FILE"
du -sh "$LOG_DIR"/* 2>/dev/null | tail -10 | tee -a "$METRICS_FILE" || echo "No log files found" | tee -a "$METRICS_FILE"

echo -e "\n=== End Monitoring - $STAMP ===\n" | tee -a "$METRICS_FILE"

# Cleanup old metrics (keep last 100 entries)
tail -1000 "$METRICS_FILE" > "${METRICS_FILE}.tmp" && mv "${METRICS_FILE}.tmp" "$METRICS_FILE"

echo "Monitoring complete. Results saved to $METRICS_FILE"