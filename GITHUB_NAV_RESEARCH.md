# GitHub / Nav2 navigation research notes

This document lists useful upstream ROS/Nav2 components and GitHub projects that are relevant for improving autonomous navigation on the Devastator robot.

## 1. Nav2 Collision Monitor

Repository/package: `ros-navigation/navigation2/nav2_collision_monitor`

Why useful:

- Adds an independent safety layer below the controller.
- Acts as a `cmd_vel` filter.
- Can stop or slow the robot based on LaserScan, PointCloud2, Range, or costmap data.
- Uses configurable polygons/circles/velocity polygons around the robot.
- Good fit for the current problem: robot must not touch obstacles seen by `/scan_filtered`.

Recommended use in this project:

```text
cmd_vel_auto / cmd_vel_smoothed
  -> collision_monitor
  -> cmd_vel_safety_filter
  -> robot_bridge
```

Initial zones:

```text
front_stop_zone: short polygon in front of base_link -> stop
front_slow_zone: larger polygon in front -> slow down
rear_stop_zone: small polygon behind robot -> stop reverse if obstacle behind
```

Start with `/scan_filtered` as the source. Add RealSense pointcloud later only if CPU budget is acceptable.

## 2. ros-teleop/twist_mux

Repository: `ros-teleop/twist_mux`

Why useful:

- Mature ROS twist multiplexer.
- Supports priorities and lock topics.
- Useful if the current custom mux grows too much.

Recommended use:

- Keep current mux if it is simple and working.
- Consider replacing it with `twist_mux` if you need clean priority arbitration between autonomous navigation, joystick, emergency stop, and safety locks.

Suggested priority model:

```text
emergency_stop lock: highest
collision_monitor lock/stop: high
joystick/manual: high
nav2 auto: normal
```

## 3. Nav2 Regulated Pure Pursuit / DWPP

Package: `nav2_regulated_pure_pursuit_controller`

Why useful:

- Designed for service/industrial robots.
- Regulates speed based on path curvature.
- Slows near obstacles.
- DWPP mode considers velocity and acceleration constraints more explicitly.

Recommended use:

- Do not switch immediately.
- First stabilize DWB + RotationShim.
- Then create a comparison branch:

```text
DWB + RotationShim baseline
vs.
RPP
vs.
DWPP, if available in the deployed Nav2 version
```

Metrics:

- goal success rate,
- minimum distance to obstacles,
- number of replans,
- number of recoveries,
- localization stability during rotation,
- average path tracking smoothness.

## 4. Nav2 MPPI Controller

Package: `nav2_mppi_controller`

Why useful:

- Predictive local trajectory planner.
- Simulates candidate trajectories and scores them with plugin critics.
- Supports differential-drive robots.
- Good for smooth obstacle-aware trajectories once compute budget and odometry are stable.

Risk:

- More complex to tune than DWB.
- More CPU-intensive than DWB/RPP.
- Not the first thing to try on Raspberry Pi while localization is still being stabilized.

Recommended use:

- Treat as a later experiment, possibly on Jetson or after measuring RPi CPU headroom.

## 5. Nav2 Keepout and Speed Zones

Feature: Costmap filters in Nav2

Why useful:

- Lets you encode no-go areas and slow zones in the map.
- Useful for known risky static regions: furniture legs, narrow corners, bad localization zones, reflective surfaces, or places where the robot often clips obstacles.

Recommended use:

- Add keepout zones only after basic obstacle avoidance is stable.
- For the final demo map, define:

```text
keepout: under furniture, wall edges with map artifacts, known trap areas
speed zones: narrow passages, anomaly inspection zones
```

## 6. Spatio-Temporal Voxel Layer, STVL

Repository: `SteveMacenski/spatio_temporal_voxel_layer`

Why useful:

- Alternative 3D voxel obstacle layer with temporal decay.
- Designed for depth cameras and 3D obstacle persistence/clearing.
- Reported use cases include warehouses, factories, retail, hospitals, hospitality, and RoboCup@Home.

Fit for this project:

- Currently optional, not immediate.
- Your current Nav2 voxel layer with RealSense pointcloud should be tuned first.
- Consider STVL if RealSense pointcloud obstacles flicker, remain stuck, or cost too much CPU in the current `VoxelLayer`.

## 7. Denoise / filtering of noise-induced obstacles

Nav2 has tutorials around filtering noise-induced obstacles. This may be useful if `/scan_filtered` or RealSense pointcloud creates false obstacles.

Recommended local approach before adding new packages:

- confirm `/scan_filtered` is stable,
- tune obstacle ranges,
- tune min/max obstacle heights for pointcloud,
- avoid feeding noisy pointcloud into global costmap until local behavior is stable.

## 8. Recommended priority order for this robot

1. Keep DWB + RotationShim as the baseline.
2. Add `cmd_vel_safety_filter` for reverse-only-straight rule.
3. Restore `ObstacleFootprint` and local `static_layer`.
4. Add `Collision Monitor` using `/scan_filtered`.
5. Tune inflation/critic weights until the physical footprint never touches map/scan obstacles.
6. Add keepout/speed zones for final demo areas.
7. Compare RPP/DWPP once DWB baseline is stable.
8. Consider STVL only if RealSense 3D obstacle handling becomes the bottleneck.
9. Consider MPPI only if there is enough CPU and the baseline still feels too jerky.

## Suggested thesis angle

The thesis can describe this as a layered safety/navigation architecture:

```text
Planner layer: global path around static map obstacles
Controller layer: local obstacle-aware trajectory generation
Costmap layer: static map + live LiDAR/depth obstacles
Safety filter layer: collision monitor + reverse-motion constraint
Hardware adaptation layer: adaptive motor power + forward-arc turning
Perception layer: anomaly detection using camera/depth on Jetson
```

This structure supports the main thesis topic: autonomous robot for anomaly detection in indoor spaces.
