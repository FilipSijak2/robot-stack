# Raspberry Pi Metrics Exporter

The tracked monitoring configuration exposes Raspberry Pi and robot-container metrics for an external Prometheus server.

## Start node_exporter

From the repository root:

```bash
docker compose -f monitoring/rpi/docker-compose.exporters.yaml up -d
```

`node_exporter` listens on host port `9100` and reads custom metrics from `monitoring/textfile`.

## Start the custom metrics writer

The writer publishes Raspberry Pi temperature, throttling state, ARM clock, Docker resource usage and top-process metrics.

For a foreground test:

```bash
TEXTFILE_DIR="$PWD/monitoring/textfile" \
  monitoring/rpi/scripts/write_rpi_metrics.sh --once
```

The tracked systemd unit assumes the repository is installed at `/home/raspberry/robot-stack`. If that is the deployed path:

```bash
sudo cp monitoring/rpi/systemd/rpi-robot-metrics.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now rpi-robot-metrics.service
```

Verify the exporter locally:

```bash
curl http://127.0.0.1:9100/metrics
```

Prometheus and dashboard configuration are intentionally not stored in this repository.
