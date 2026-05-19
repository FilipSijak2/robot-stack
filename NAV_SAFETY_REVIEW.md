# Nav safety review proposal

Goal: keep the physical Nav2 footprint unchanged, but prevent the robot from touching static map obstacles or laser scan obstacles.

## Last three commits review

1. `v26.21.rc7`: good reduction of angular velocity and acceleration, plus first adaptive rotation power parameters. Missing: strong footprint collision critic and local static map awareness.

2. `v26.21.rc8`: good obstacle-safety direction because it added `ObstacleFootprint`, stronger obstacle cost, local `static_layer`, larger inflation, and forward-arc turn settings. Risk: motor and boost settings were aggressive, so laminate rotation could become too fast and hurt localization.

3. `v26.20.rc9` / current stack: safer for localization because it reintroduced `RotationShimController` and reduced boost. Regression for obstacle safety because it removed `ObstacleFootprint`, lowered obstacle critic weight, removed local `static_layer`, and disabled forward-arc turn.

## Recommended Nav2 direction

Keep the footprint exactly as the physical footprint and set `footprint_padding: 0.0`. Use inflation and DWB critics for clearance, not a bigger footprint.

Recommended controller changes:

```yaml
critics:
  [
    "RotateToGoal",
    "Oscillation",
    "ObstacleFootprint",
    "BaseObstacle",
    "GoalAlign",
    "PathAlign",
    "PathDist",
    "GoalDist",
  ]
ObstacleFootprint.scale: 120.0
BaseObstacle.scale: 0.20
```

Recommended local costmap changes:

```yaml
plugins: ["static_layer", "voxel_layer", "inflation_layer"]
static_layer:
  plugin: "nav2_costmap_2d::StaticLayer"
  map_subscribe_transient_local: true
inflation_layer:
  plugin: "nav2_costmap_2d::InflationLayer"
  cost_scaling_factor: 2.2
  inflation_radius: 0.75
footprint_padding: 0.0
```

Recommended global costmap changes:

```yaml
inflation_layer:
  plugin: "nav2_costmap_2d::InflationLayer"
  cost_scaling_factor: 2.2
  inflation_radius: 0.75
footprint_padding: 0.0
```

Recommended planner changes:

```yaml
expected_planner_frequency: 5.0
GridBased:
  allow_unknown: false
```

## Runtime bridge changes already applied on this branch

`config/containers/bridge_rpi_direct.env` is tuned to:

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

This is meant to be less aggressive than rc8, but stronger than the current rc9 settings on carpet.

## Test checklist

1. Verify `/local_costmap/costmap` shows static map obstacles and laser obstacles.
2. Verify the footprint in Foxglove remains the original physical footprint.
3. Send a goal near a static obstacle and confirm planned path has clearance.
4. Place a visible obstacle in `/scan_filtered` and confirm DWB avoids it.
5. Watch `/robot_status`: `PWR_BOOST` should increase only when yaw rate is too low.
6. Watch `FWD_ARC_ACTIVE`: it should activate only for near-in-place turns.
7. Test laminate before carpet.
