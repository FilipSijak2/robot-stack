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

First run a short torque-focused retest after changing the carpet rotation
mapping:

```bash
bash scripts/calibrate_drive.sh --surface carpet \
  --rotation-only --ramp-seconds 1.5 --duration 1.5 --repeats 3
```

Only if `0.10 rad/s` still cannot break static friction, use one short extended
sweep while holding the physical motor cutoff; the higher commands can produce
substantially more PWM with the carpet profile:

```bash
bash scripts/calibrate_drive.sh --surface carpet \
  --rotation-only --extended-rotation --duration 1.0 --repeats 1
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
5. publishes another stop during cleanup, including after Ctrl+C or a failed
   measurement, and leaves manual mode selected. Resume navigation explicitly
   only after checking any previously active goal.

ROS callbacks continue running while the operator answers prompts. Odometry
must have advancing source timestamps no older than 0.5 seconds; receipt time
alone cannot make a queued old pose fresh. A stale pose during motion aborts
the trial and sends zero commands.

Each trial now commands motion for `--ramp-seconds` PLUS `--duration`.
For example, 1.5 + 1.5 means three seconds of commanded motion. The ramp phase
is an observation interval, not a change to the bridge slew settings or a
guarantee that PWM has stabilized. Adaptive boost can still change during hold.
Both phases get separate CSV/JSON rows (`phase=ramp` and `phase=hold`); summary
values use hold rows only. Speed uses the actual difference between the two
odometry source timestamps, excluding post-stop settling. Check source stamps
against the bag to align trials. Reports have `metadata.schema_version=2`.
PWM averages are restricted to each phase using callback receipt times. The
existing `/motor_pwm` message has no source timestamp, so transport latency
cannot be removed from those averages.

If cleanup reports a critical failure, switch off motor power before doing
anything else.

## Results

Reports are stored under `/srv/calibration_results/` in the container, exposed
as `srv/calibration_results/` in the stack checkout:

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

For a temporary runtime change without recreating the container, use the live
ROS 2 parameter. It controls both transition behaviors:

```bash
docker exec -it robot_bridge_cont bash -lc \
  'source /opt/ros/humble/setup.bash && ros2 param set /robot_rpi_direct_bridge motor_slew_enabled false'

docker exec -it robot_bridge_cont bash -lc \
  'source /opt/ros/humble/setup.bash && ros2 param set /robot_rpi_direct_bridge motor_slew_enabled true'
```

This temporary value resets to the `MOTOR_SLEW_ENABLED` environment setting
when `robot_bridge` restarts.
