# Autonomy improvement research plan

This document collects proposed next steps to improve autonomous navigation quality and safety on the Devastator robot.

## 1. Add a `cmd_vel_safety_filter` before the hardware bridge

### Problem

If the hardware bridge modifies commands after Nav2 has already planned and simulated them, Nav2 is not fully aware of the final motion sent to the motors.

### Proposed command chain

```text
Nav2 controller /cmd_vel_auto
  -> cmd_vel_mux
  -> cmd_vel_safety_filter
  -> robot_bridge /cmd_vel
```

### Rule set

The filter should preserve normal forward driving, but enforce simple drivetrain rules:

```python
if cmd.linear.x < 0.0:
    cmd.angular.z = 0.0
    cmd.linear.x = max(cmd.linear.x, -0.08)
```

Meaning:

- reverse is allowed only as straight reverse,
- reverse speed is limited,
- reverse + rotation is not allowed,
- forward and near-in-place turns are still allowed,
- the hardware bridge remains responsible for motor-level adaptive power.

### Suggested ROS topics

```text
input:  /cmd_vel_muxed or /cmd_vel_safe_in
output: /cmd_vel
```

A later cleanup should make the topic chain explicit so the bridge subscribes only to the filtered command.

## 2. Keep the physical footprint unchanged; use inflation and critics for clearance

Do not enlarge the physical footprint. Keep:

```yaml
footprint: "[[0.16, 0.165], [0.16, -0.165], [-0.11, -0.165], [-0.11, 0.165]]"
footprint_padding: 0.0
```

Use costmap inflation and DWB trajectory critics for clearance:

```yaml
ObstacleFootprint.scale: 120.0
BaseObstacle.scale: 0.20
inflation_radius: 0.75
cost_scaling_factor: 2.2
```

This keeps the robot model honest while still discouraging paths near obstacles.

## 3. Restore local static map awareness

The local rolling costmap should contain both static map obstacles and live sensor obstacles:

```yaml
plugins: ["static_layer", "voxel_layer", "inflation_layer"]
```

Rationale: the robot previously drove into static obstacles already present in the map. A local `static_layer` makes the controller aware of these obstacles inside the local window, not only through the global path.

## 4. Add Nav2 Collision Monitor as an additional safety layer

Nav2 Collision Monitor is intended as an additional CPU-level safety layer after costmaps and planners. It monitors sensor data in configurable zones around the robot and can slow or stop the robot when an imminent collision is detected.

Suggested initial configuration concept:

```text
front_stop_zone: short polygon in front of base_link -> stop
front_slow_zone: larger polygon in front -> slow down
rear_stop_zone: small polygon behind robot -> stop reverse
sources: /scan_filtered first, later pointcloud/costmap if needed
```

This is not a replacement for proper costmaps, but a last-resort protection layer.

## 5. Keep `RotationShimController`, but tune it conservatively

`RotationShimController` is useful for differential robots because it aligns the robot to the path heading before handing control to the primary controller. Keep it enabled while tuning:

```yaml
rotate_to_heading_angular_vel: 0.40
max_angular_accel: 0.9
max_vel_theta: 0.40
```

If carpet causes stalls, solve that with adaptive boost in the bridge, not by increasing global angular velocity too much.

## 6. Velocity smoother strategy

Current setup uses `OPEN_LOOP`, which is reasonable while odometry is imperfect. `CLOSED_LOOP` should only be enabled if `/odometry/filtered` is high-rate and low-latency enough. If odometry lags or is noisy, closed-loop smoothing can make command output less predictable.

Suggested next test:

```yaml
feedback: "OPEN_LOOP"
smoothing_frequency: 20.0
max_velocity: [0.22, 0.0, 0.40]
min_velocity: [0.0, 0.0, -0.40]
max_accel: [0.6, 0.0, 0.9]
max_decel: [-0.6, 0.0, -0.9]
```

Note: `min_velocity.x = 0.0` makes normal navigation forward-only at this layer. If reverse is needed only for recovery, handle it through recovery behavior or a separate explicit exception.

## 7. Consider Regulated Pure Pursuit / DWPP as a later controller experiment

DWB is flexible and critic-based, but can look jittery if local costmaps, localization, or critic weights are not stable. Nav2 Regulated Pure Pursuit regulates linear velocity around curvature and nearby obstacles, and current Nav2 documentation also mentions Dynamic Window Pure Pursuit support.

Do not switch controllers yet. First stabilize DWB. Later, create a separate branch to compare:

- DWB + RotationShim,
- Regulated Pure Pursuit,
- Regulated Pure Pursuit with Dynamic Window mode if supported in the deployed ROS/Nav2 version.

Evaluation metrics:

- goal success rate,
- minimum distance to obstacles,
- number of recoveries,
- number of replans,
- average path tracking error,
- localization quality during turns.

## 8. Use keepout and speed zones for known problematic regions

For mapped indoor spaces, define keepout zones around risky areas and speed zones in narrow passages. This should come after base navigation is stable.

Examples:

- keepout near furniture legs or map artifacts,
- speed limit zone near narrow passages,
- slow zone near anomaly inspection areas.

## 9. Better test methodology

Record bags for each test:

```text
/cmd_vel
/cmd_vel_auto
/robot_status
/scan_filtered
/local_costmap/costmap
/global_costmap/costmap
/local_costmap/published_footprint
/odometry/filtered
/amcl_pose
/tf
/tf_static
```

For each run, document:

- floor type: laminate or carpet,
- goal pose,
- obstacles present,
- whether robot touched obstacle,
- whether localization jumped,
- max `PWR_BOOST`,
- whether `FWD_ARC_ACTIVE` was triggered.

## 10. Recommended priority order

1. Implement `cmd_vel_safety_filter`.
2. Restore `ObstacleFootprint`, stronger `BaseObstacle`, local `static_layer`, and inflation tuning.
3. Test with current DWB + RotationShim.
4. Add Collision Monitor.
5. Tune AMCL and costmaps based on recorded bags.
6. Compare RPP/DWPP only after DWB baseline is stable.
7. Add keepout/speed zones for final demo map.
