# Branch summary: chatgpt-nav-safety-adaptive-forward

This branch collects proposed improvements for safer and smoother autonomous navigation on the Devastator robot.

## Branch goal

Improve autonomy while keeping the physical Nav2 footprint unchanged:

- avoid static map obstacles,
- avoid obstacles visible in `/scan_filtered`,
- reduce aggressive rotations on laminate,
- preserve enough rotation power on carpet,
- prefer forward motion and forward-arc turns,
- allow reverse only in a constrained and straight way,
- prepare for final demo safety zones.

## Files added or changed

### 1. `config/containers/bridge_rpi_direct.env`

Runtime tuning was updated:

```env
MIN_MOTOR_CMD=0.35
POWER_ADAPT_HIGH_RATIO=1.10
POWER_ADAPT_MAX_BOOST=0.65
POWER_ADAPT_STEP_UP=0.02
POWER_ADAPT_STEP_DOWN=0.006
FORWARD_ARC_TURN_ENABLED=1
FORWARD_ARC_TURN_MAX_LINEAR=0.04
FORWARD_ARC_TURN_INNER_CMD=0.18
```

Rationale:

- less aggressive than the previous carpet-focused settings,
- stronger than the current conservative settings,
- adaptive boost increases only when yaw feedback is too low,
- forward-arc turning is enabled for near-in-place turns.

### 2. `config/containers/cmd_vel_safety_filter.env`

Runtime configuration for the reverse-straight safety rule:

```env
CMD_VEL_SAFETY_INPUT=/cmd_vel_muxed
CMD_VEL_SAFETY_OUTPUT=/cmd_vel
CMD_VEL_REVERSE_MAX_SPEED=0.08
CMD_VEL_FORBID_REVERSE_TURNING=1
```

Purpose:

- reverse motion is allowed,
- reverse speed is limited,
- reverse + angular.z is blocked before reaching `robot_bridge`,
- if the robot must go backward, it goes straight backward.

The implementation file lives in the matching `paper` branch as `nav_cont/cmd_vel_safety_filter.py`.

### 3. `NAV_SAFETY_REVIEW.md`

Contains the review of the last three navigation commits and the recommended direction:

- keep `RotationShimController`,
- restore `ObstacleFootprint`,
- restore local `static_layer`,
- use inflation instead of enlarged footprint,
- reduce excessive replanning by tuning planner frequency and unknown-space behavior.

### 4. `AUTONOMY_IMPROVEMENT_RESEARCH.md`

Contains the larger autonomy improvement plan:

1. Add `cmd_vel_safety_filter`.
2. Restore stronger Nav2 obstacle handling.
3. Add Collision Monitor.
4. Tune AMCL and costmaps from recorded bags.
5. Add keepout/speed zones for final demo areas.
6. Compare RPP/DWPP later.
7. Optional: enable explicit LaserScan denoise filtering only after validating `/scan_filtered` against `/scan`.

### 5. `GITHUB_NAV_RESEARCH.md`

Summarizes useful upstream ROS/Nav2/GitHub components:

- Nav2 Collision Monitor,
- `twist_mux`,
- Regulated Pure Pursuit / DWPP,
- MPPI Controller,
- Keepout and Speed zones,
- Spatio-Temporal Voxel Layer,
- LaserScan denoise filtering.

### 6. `config/containers/collision_monitor_params.example.yaml`

Template for Nav2 Collision Monitor.

Initial concept:

- front stop zone,
- front slow zone,
- rear stop zone,
- footprint approach zone,
- `/scan_filtered` as first sensor source.

Suggested command chain:

```text
Nav2 /cmd_vel_auto
  -> cmd_vel_mux or velocity_smoother
  -> collision_monitor
  -> cmd_vel_safety_filter
  -> robot_bridge /cmd_vel
```

### 7. `config/containers/costmap_filters_params.example.yaml`

Template for Nav2 keepout and speed zones.

Includes example servers for:

- keepout mask map,
- speed mask map,
- Costmap Filter Info Server,
- costmap filter plugin integration.

### 8. `docs/how_to_create_keepout_speed_zones.md`

Practical guide for drawing keepout and speed zone masks on top of the existing map.

Explains:

- copying the original map,
- keeping the same resolution and origin,
- drawing zones in GIMP or similar editor,
- validating mask alignment in Foxglove/RViz,
- first testing keepout zones before speed zones.

### 9. `config/containers/scan_filter_chain.example.yaml`

Optional template for explicit LaserScan denoise filtering:

```text
/scan -> laser_filters -> /scan_filtered
```

This is a later optional improvement, not the reverse-straight safety rule.

### 10. `docs/how_to_enable_scan_denoise_filter.md`

Optional guide for enabling and validating `/scan_filtered` filtering.

Covers:

- installing `laser_filters`,
- running `scan_to_scan_filter_chain`,
- comparing `/scan` and `/scan_filtered`,
- Docker Compose integration concept.

## Files added in paper branch

The `paper` repository branch with the same name contains:

- `nav_cont/cmd_vel_safety_filter.py`,
- `NAV_SAFETY_REVIEW.md`,
- `CMD_VEL_SAFETY_FILTER_PROPOSAL.md`.

These document and partially implement the reverse-straight command safety rule.

## Recommended implementation order

1. Test current bridge runtime changes on laminate.
2. Apply Nav2 obstacle changes from `NAV_SAFETY_REVIEW.md`.
3. Wire `cmd_vel_safety_filter` into the command chain.
4. Add Collision Monitor with `/scan_filtered` only.
5. Add keepout zones for the final map.
6. Add speed zones only after keepout zones work.
7. Optional: enable explicit LaserScan denoise filtering only after validating `/scan_filtered` against `/scan`.
8. Compare RPP/DWPP only after DWB baseline is stable.

## Test checklist

Record bags with:

```text
/cmd_vel
/cmd_vel_auto
/cmd_vel_safety_status
/robot_status
/scan
/scan_filtered
/local_costmap/costmap
/global_costmap/costmap
/local_costmap/published_footprint
/odometry/filtered
/amcl_pose
/tf
/tf_static
```

During tests, check:

- robot does not touch static map obstacles,
- robot does not touch obstacles visible in `/scan_filtered`,
- footprint in Foxglove remains the original physical footprint,
- `PWR_BOOST` increases only when yaw feedback is too low,
- `FWD_ARC_ACTIVE` activates only for near-in-place forward turns,
- reverse, if introduced, is straight and speed-limited,
- `/cmd_vel_safety_status` reports when reverse turning is blocked.
