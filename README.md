# Raspberry Pi Robot Stack

This repository is the deployed Docker Compose configuration for the Raspberry Pi 5 robot runtime. Container source code is maintained in the `paper` repository, and Jetson YOLO processing is maintained in `jetson-stack`.

## Active services

`docker-compose.yaml` starts:

- Nav2 and AMCL navigation
- PostgreSQL/PostGIS storage
- RPLidar input
- SLAM and RF2O fallback odometry
- sensor fusion and IMU yaw correction
- direct Raspberry Pi GPIO motor control
- Raspberry Pi AI Kit service
- rosbridge and Foxglove bridges
- RealSense RGB, depth, point-cloud and IMU streams
- MCAP bag recording and read-only bag browsing
- log collection and runtime health checks

All services use the host network where required by ROS 2 or hardware access.

## Configuration

1. Copy `.env.example` to `.env`.
2. Set image tags, `DB_PASS` and device-specific values.
3. Keep `.env` private; it is ignored by Git.
4. Render CycloneDDS configuration after changing its inputs.

```bash
cp .env.example .env
scripts/render_cyclonedds_config.sh
docker compose config
docker compose up -d
```

The tracked files under `config/containers` are the active mounted runtime configuration. Files ending in `.env` contain non-secret service settings; shared and sensitive values belong in the ignored root `.env`.

## Active configuration groups

| File | Purpose |
| --- | --- |
| `bridge_rpi_direct.env` | GPIO pins, drivetrain geometry and motor behavior |
| `drive_profiles/*.env` | Selected surface dynamics and motor transition safety |
| `nav_cont.env` | command routing, safety, inspection and pose persistence |
| `nav2_params.yaml` | Nav2 planners, controllers and costmaps |
| `collision_monitor_params.yaml` | collision-monitor zones and sources |
| `slam_cont.env` / `slam_params.yaml` | mapping and localization behavior |
| `sensor_fusion_cont.env` / `robot_localization.yaml` | IMU correction and EKF |
| `realsense_cont.env` | RealSense streams and watchdog |
| `recorded_topics.yaml` | MCAP topic selection |
| `logging.yaml` | container log collection |
| `cyclonedds.xml` | generated DDS network configuration |

## Maps

Select a map before starting localization:

```bash
scripts/select_map.sh <session-or-map-path>
```

Start or stop mapping with:

```bash
scripts/start_mapping.sh
scripts/stop_mapping.sh
```

## Validation

```bash
docker compose config
bash -n scripts/*.sh
```

The optional lightweight Raspberry Pi monitoring deployment is documented in [monitoring/README.md](./monitoring/README.md).
