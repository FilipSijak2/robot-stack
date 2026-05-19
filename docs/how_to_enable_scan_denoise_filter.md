# How to enable LaserScan denoise filtering

This guide describes how to make `/scan_filtered` explicit and reproducible.

## Why this matters

Nav2 already uses `/scan_filtered` for AMCL and costmaps. If `/scan_filtered` is not produced by a known filter chain, debugging obstacle avoidance becomes harder.

Filtering can reduce:

- random short-range noise,
- edge/shadow artifacts,
- invalid range values,
- robot-body reflections if angular bounds are configured.

## Recommended first setup

Use the ROS `laser_filters` package:

```bash
sudo apt install ros-${ROS_DISTRO}-laser-filters
```

Copy the example config:

```bash
cp config/containers/scan_filter_chain.example.yaml config/containers/scan_filter_chain.yaml
```

## Topic chain

```text
laser_driver -> /scan
laser_filters -> /scan_filtered
Nav2 AMCL/costmaps -> /scan_filtered
```

## Example run command

```bash
ros2 run laser_filters scan_to_scan_filter_chain \
  --ros-args \
  -r scan:=/scan \
  -r scan_filtered:=/scan_filtered \
  --params-file /config/scan_filter_chain.yaml
```

## Recommended validation

Before autonomous driving, compare both scans in Foxglove/RViz:

```text
/scan
/scan_filtered
```

Check that:

- walls remain visible,
- chair/table legs remain visible,
- random spikes disappear,
- obstacles are not removed too aggressively,
- AMCL still localizes correctly.

## Initial filters

The proposed initial chain uses:

1. `LaserScanRangeFilter` to remove unreliable near/far readings.
2. `ScanShadowsFilter` to remove edge/shadow artifacts.

If localization becomes worse, disable `ScanShadowsFilter` first and keep only the range filter.

## Tuning notes

### `lower_threshold`

Set this slightly below the robot's reliable LiDAR minimum range.

Start with:

```yaml
lower_threshold: 0.12
```

If nearby real obstacles disappear, lower it. If robot-body reflections remain, raise it carefully.

### `upper_threshold`

Set this to the useful indoor range, not necessarily the LiDAR maximum.

Start with:

```yaml
upper_threshold: 8.0
```

### Shadow filter

Shadow filtering can help around object edges, but can also remove useful geometry. Treat it as optional.

## Integration into Docker Compose

A future compose service could look like:

```yaml
scan_filter_cont:
  image: ${REGISTRY_HOST}/${IMAGE_OWNER}/scan_filter_cont:${STACK_TAG}
  container_name: scan_filter_cont
  network_mode: host
  ipc: host
  env_file:
    - .env
  volumes:
    - ./config/containers/scan_filter_chain.yaml:/config/scan_filter_chain.yaml:ro
  command: >
    bash -lc "source /opt/ros/${ROS_DISTRO}/setup.bash &&
    ros2 run laser_filters scan_to_scan_filter_chain
    --ros-args
    -r scan:=/scan
    -r scan_filtered:=/scan_filtered
    --params-file /config/scan_filter_chain.yaml"
```

Do not enable this blindly. First verify it on a bag or with the robot raised/off the ground.
