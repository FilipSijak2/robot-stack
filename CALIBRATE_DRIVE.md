# Drive calibration without wheel encoders

`scripts/calibrate_drive.sh` starts the calibration node already packaged in
`nav_cont`. The host only needs Bash and Docker; Python/rclpy run inside the ROS
2 container. The node characterizes the complete drivetrain through the normal
ROS command and safety chain. It uses `/odometry/filtered` (RF2O plus corrected
IMU) to measure body motion and does not require wheel encoders.

The script measures:

- requested versus measured linear speed;
- requested versus measured angular speed in both directions;
- forward distance, lateral drift and yaw change;
- the smallest tested command that produces measurable motion;
- left/right rotation response asymmetry.
- mean signed left/right motor PWM and peak PWM when the deployed bridge
  publishes `/motor_pwm` (reports remain valid with an older bridge image, but
  these fields will be empty).

It intentionally does not edit deployment parameters automatically. A bad
LiDAR pose, an obstructed run or a moved robot could otherwise install an unsafe
motor profile. Results are written to timestamped CSV and JSON files and can be
compared before selecting profile values.

## Prerequisites

- Run the full stack with `nav_cont`, RF2O, sensor fusion and the motor bridge.
- Use a charged battery and the final demonstration payload.
- Prepare at least one metre of clear floor in every direction.
- Keep immediate access to physical motor power.
- Keep the robot away from stairs and table edges.

## Run

From the `robot-stack` checkout on the Raspberry Pi:

```bash
bash scripts/calibrate_drive.sh --surface laminate
bash scripts/calibrate_drive.sh --surface carpet
```

Three repetitions of every forward and rotation command are run by default.
The script pauses before each movement so the operator can reposition the robot
and verify that the test area is clear. Add reverse tests only in a sufficiently
large test area:

```bash
bash scripts/calibrate_drive.sh --surface carpet --include-reverse
```

Use `--continuous` only in a bounded calibration area with a physical emergency
stop. It removes the per-movement confirmation but does not remove the initial
safety confirmation.

## Safety behavior

The script:

1. verifies that `nav_cont` and the odometry topic are available;
2. selects manual mode so Nav2 cannot compete with test commands;
3. publishes through `/cmd_vel_joy`, retaining the mux, collision monitor and
   velocity safety filter;
   it compensates `MANUAL_SPEED_SCALE` and `MANUAL_ANGULAR_SCALE` from the
   container environment so report commands represent values after the mux;
4. publishes an explicit zero command after every timed pulse;
5. publishes another stop and restores automatic mode during cleanup, including
   after Ctrl+C or a failed measurement.

If cleanup reports a critical failure, switch off motor power before doing
anything else.

## Results

Reports are stored under `calibration_results/` by default:

```text
drive-calibration-laminate-YYYYMMDD-HHMMSS.csv
drive-calibration-laminate-YYYYMMDD-HHMMSS.json
```

Run both surfaces under the same battery and payload conditions. The JSON
summary makes it easy to compare start response, speed ratio, straight-line
drift and left/right turn symmetry. Because there are no wheel encoders, treat
these as whole-robot measurements rather than independent wheel RPM.

## Select a drive profile

Profiles are persisted through `DRIVE_PROFILE` in the ignored root `.env` and
loaded after the base bridge environment. The initial profiles change only
slew/reversal dynamics; they deliberately do not guess surface calibration.

```bash
bash scripts/select_drive_profile.sh safe-demo
bash scripts/select_drive_profile.sh laminate
bash scripts/select_drive_profile.sh carpet
bash scripts/select_drive_profile.sh --show
```

The selector validates the compose configuration and recreates only
`robot_bridge`. Pass `--no-restart` to apply the profile on the next stack
start. Always select the matching profile before recording that surface.

Each profile has one master switch for motor transition shaping:

```env
MOTOR_SLEW_ENABLED=1  # enable PWM slew limiting and reversal neutral pause
MOTOR_SLEW_ENABLED=0  # disable both features
```

The rate and neutral-time parameters remain in the profile but have no effect
when this switch is `0`.

For a global override, set the same single value in the ignored root `.env`;
the compose `environment` value takes precedence over all profiles:

Set `MOTOR_SLEW_ENABLED=0` (disabled) or `MOTOR_SLEW_ENABLED=1` (enabled)
in `.env`, then apply it with:

```bash
docker compose up -d --no-deps --force-recreate robot_bridge
```
