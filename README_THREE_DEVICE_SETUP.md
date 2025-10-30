# Three-Device Robot Architecture Setup

## Arhitektura

Sistem se sastoji od tri uređaja:

1. **Raspberry Pi 5** - ROS2 stack u Docker containerima
2. **Raspberry Pi zero 2w** - Camera device integrated with RPI Camera module 3
2. **Arduino R4 WiFi** - motor kontrola + LED matrica (prima CommandPacket)
3. **Arduino Nano ESP32** - senzori (IMU + enkoderi + odometrija) + custom serial protokol

## Komunikacija

```
ROS2 (Pi containers) ↔ robot_bridge (USB /dev/ttyUSB1) ↔ Nano ESP32 ↔ UART ↔ UNO R4 (motori + LED)
                   ↘ LIDAR (/dev/ttyUSB0) → laser_driver
```

### Topici za komunikaciju:

- `/cmd_vel` - komande za kretanje (Twist)
- `/wheel_odom` - odometrija (Odometry)
- `/imu/data` - IMU + gyro podaci
- `/robot_status` - health / statistika bridge-a

## Hardware Setup

### Arduino R4 WiFi povezivanje:
- **UART (RX/TX)** ↔ Nano ESP32 (CommandPacket 20B)
- **PWM pinovi** → BTS7960 motor driveri
- **LED Matrix** → Status vizualizacija

### Arduino Nano ESP32 povezivanje:
- **USB** → Raspberry Pi (/dev/ttyUSB1) – SensorPacket 64B @20Hz
- **UART (TX1/RX1)** → UNO R4 (motor komande)
- **I2C → TCA9548A mux**:
   - CH0 → IMU LSM6DSO32
   - CH1 → AS5600 (lijevi)
   - CH2 → AS5600 (desni)

## Deployment

1. **Upload Arduino firmware:**
   
   **Arduino R4 WiFi kod:** `devastator_controler_r4.ino`

   **Arduino Nano ESP32 kod:** `devastator_sensors_nano.ino`

2. **Required libraries:**
   ```bash
   # UNO R4:
   - ArduinoGraphics
   - Arduino_LED_Matrix

   # Nano ESP32:
   - Adafruit LSM6DSO32
   - Wire (builtin)
   ```

3. **Konfiguracija stack-a:**
   ```bash
   cp .env.example .env
   # Edituj .env sa tvojim registry settings
   ```

4. **Deploy containers:**
   ```bash
   ./deploy.sh
   ```

## LED Matrix Visualization (R4 WiFi)

`devastator_controler_r4.ino` prikazuje:

| LED Pattern | Robot State |
|-------------|-------------|
| 🟢 Statičan uzorak | IDLE - robot miruje |
| ⬆️ Animacija naprijed | MOVING_FORWARD |
| ⬇️ Animacija nazad | MOVING_BACKWARD |
| ↩️ Animacija lijevo | TURNING_LEFT |
| ↪️ Animacija desno | TURNING_RIGHT |
| 🔴 Blink pattern | ERROR_STATE |

**Real-time feedback**: LED matrix se ažurira na 5Hz i pokazuje trenutno stanje robota!

## USB Device Detection (nova arhitektura)

Provjeri koja USB devices su dostupni:

```bash
# Provjeri dostupne USB devices
ls -la /dev/tty*

# LIDAR:
/dev/ttyUSB0

# Nano ESP32 (bridge):
/dev/ttyUSB1
```

Ako su devices na različitim putovima, edituj `.env`:

```bash
LIDAR_DEVICE=/dev/ttyUSB0
BRIDGE_SERIAL_DEVICE=/dev/ttyUSB1
```

## Monitoring

### Container status:
```bash
docker compose ps
docker compose logs -f micro_ros_agent
```

### ROS2 topici:
```bash
# Provjeri dostupne topice
ros2 topic list

# Monitor odometry
ros2 topic echo /odom

# Monitor IMU
ros2 topic echo /imu/data

# Test motor komande
ros2 topic pub /cmd_vel geometry_msgs/Twist "linear: {x: 0.1}" --once
```

## Troubleshooting

### Bridge ne vidi serijski uređaj:
```bash
ls -la /dev/ttyUSB1
sudo usermod -a -G dialout $USER
docker compose restart robot_bridge
```

### I2C komunikacija ne radi:
1. Provjeri da li su SDA/SCL pinovi ispravno povezani
2. Provjeri I2C address (0x42) u oba Arduino programa
3. Koristi I2C scanner za test

### Container build fails:
```bash
# Provjeri registry connection
docker pull microros/micro-ros-agent:humble

# Rebuild specific container
docker compose build sensor_fusion_cont
```

## Performance Tuning

### Senzor & komunikacija frekvencije:
- Serial bridge baud: 115200
- I2C clock: 400kHz
- Sensor publish: 20Hz (IMU + odometrija)
- Odometrija račun: Nano ESP32

### Network optimization:
- ROS_DOMAIN_ID=0 (sve komponente)
- CycloneDDS middleware za best performance
- Host networking za Docker containers
- Custom CycloneDDS XML config for local optimization

### Container resource limits:
- robot_bridge: 256MB RAM limit, 64MB reserved
- Automatic memory management with health checks
- Log rotation (10MB max per file, 5 backups)

### ROS2 optimizations:
- SLAM: 0.5s update interval, advanced loop closure
- Navigation: 20Hz controller frequency, DWB local planner
- Sensor fusion: 30Hz EKF with IMU + odometry
- Logging: Structured logging with rotation

## System Monitoring

### Performance monitoring:
```bash
# Pokreni monitoring script
./monitor_system.sh

# Kontinuirani monitoring (svake minute)
watch -n 60 ./monitor_system.sh

# Provjeri log files
tail -f /srv/logs/robot.log
tail -f /srv/logs/system_metrics.log
```

### Key metrics to monitor:
- **Topic frequencies**: /cmd_vel, /wheel_odom, /scan, /imu/data
- **Container health**: all containers should be "healthy"
- **Resource usage**: memory <80%, CPU <70% average
- **USB devices**: Arduino on /dev/ttyACM0, LIDAR on /dev/ttyUSB0
