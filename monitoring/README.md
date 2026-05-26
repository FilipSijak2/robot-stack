# Lightweight RPi performance monitoring

This monitoring setup is designed for the thesis robot stack:

- Raspberry Pi 5 robot only exports metrics.
- Banana Pi runs Prometheus and Grafana from the `FilipSijak2/rezije` repository.
- Prometheus scrapes the RPi over Tailscale.
- The robot does not run Prometheus, Grafana, or any time-series database.

This keeps the monitoring overhead on the robot low.

## What this monitors

On the Raspberry Pi:

- CPU usage and load average,
- RAM usage,
- disk usage,
- network traffic,
- CPU temperature,
- undervoltage and throttling flags,
- ARM clock frequency,
- top Docker containers by CPU and memory usage.

## Architecture

```text
Raspberry Pi 5 robot - robot-stack repo
  node_exporter :9100
  textfile collector metrics
    - rpi_cpu_temperature_celsius
    - rpi_throttled_now
    - rpi_undervoltage_now
    - docker_container_cpu_percent
    - docker_container_mem_usage_bytes
        |
        | Tailscale scrape every 15s
        v
Banana Pi - rezije repo
  Prometheus :9090
  Grafana    :3000
```

## Why this approach

Prometheus and Grafana can use noticeable CPU, memory, disk writes, and web resources. Those should not run on the robot during navigation. The robot only exposes metrics through `node_exporter`, while Banana Pi stores and visualizes the data.

## Raspberry Pi setup

From the `robot-stack` directory on the Raspberry Pi:

```bash
mkdir -p monitoring/textfile
chmod +x monitoring/rpi/scripts/write_rpi_metrics.sh
```

Start the custom metric writer once for testing:

```bash
TEXTFILE_DIR=$PWD/monitoring/textfile ./monitoring/rpi/scripts/write_rpi_metrics.sh --once
cat monitoring/textfile/rpi_robot.prom
```

Start `node_exporter`:

```bash
docker compose -f monitoring/rpi/docker-compose.exporters.yaml up -d
```

Test locally:

```bash
curl http://localhost:9100/metrics | grep -E "rpi_cpu_temperature|docker_container_cpu|docker_container_mem|node_load1"
```

### Optional systemd service for custom metrics

Edit the paths in `monitoring/rpi/systemd/rpi-robot-metrics.service` if your repo is not in:

```text
/home/raspberry/robot-stack
```

Install:

```bash
sudo cp monitoring/rpi/systemd/rpi-robot-metrics.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now rpi-robot-metrics.service
systemctl status rpi-robot-metrics.service
```

## Banana Pi setup

The Banana Pi Prometheus/Grafana stack has been moved to:

```text
FilipSijak2/rezije
branch: chatgpt-banana-monitoring
path: monitoring/banana
```

On Banana Pi:

```bash
git checkout chatgpt-banana-monitoring
cd monitoring/banana
cp prometheus.example.yml prometheus.yml
```

Edit `prometheus.yml` and set the Raspberry Pi Tailscale IP or MagicDNS name:

```yaml
- targets: ["<RASPBERRY_PI_TAILSCALE_IP>:9100"]
```

Check the current RPi Tailscale IP with:

```bash
tailscale status
```

Start monitoring from the `rezije` repository:

```bash
docker compose -f docker-compose.monitoring.yaml up -d
```

Open:

```text
Grafana:    http://<banana-pi-tailscale-ip>:3000
Prometheus: http://<banana-pi-tailscale-ip>:9090
```

## Useful Prometheus queries

### Host CPU usage

```promql
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[2m])) * 100)
```

### Host memory usage

```promql
100 * (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes))
```

### CPU temperature

```promql
rpi_cpu_temperature_celsius
```

### Top containers by CPU

```promql
topk(10, docker_container_cpu_percent)
```

### Top containers by memory

```promql
topk(10, docker_container_mem_usage_bytes)
```

### Throttling / undervoltage

```promql
rpi_throttled_now
rpi_undervoltage_now
```

## How to use this for optimization

Run one test scenario at a time and mark what was active:

1. idle stack, no navigation,
2. RealSense only,
3. LiDAR + rf2o + AMCL,
4. Nav2 autonomous driving,
5. Nav2 + Foxglove visualization,
6. Nav2 + bag recording,
7. Nav2 + anomaly pipeline.

For each scenario, watch:

- CPU temperature,
- throttling flags,
- top container CPU,
- top container memory,
- network traffic,
- disk usage if bag recording is active.

This shows what actually costs resources before changing the stack.

## Expected overhead

RPi side:

- `node_exporter`: usually low CPU and memory usage,
- custom metrics script every 15s: short `docker stats --no-stream` snapshot,
- no local time-series database,
- no Grafana web UI.

Banana Pi side:

- Prometheus stores metrics,
- Grafana serves dashboard,
- retention is configured in the `rezije` monitoring compose.

## Notes

If monitoring ever affects robot behavior, stop it immediately:

```bash
docker stop rpi_node_exporter
sudo systemctl stop rpi-robot-metrics.service
```

The monitoring stack is optional and should not be required for robot operation.
