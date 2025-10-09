# Three-Device Robot Architecture Setup

## Arhitektura

Sistem se sastoji od tri uređaja:

1. **Raspberry Pi 4** - ROS2 stack u Docker containerima
2. **Arduino R4 WiFi** - micro-ROS kontroler, motor kontrola
3. **Arduino Nano ESP32** - enkoder procesor (dual AS5600)

## Komunikacija

```
ROS2 (Pi) ↔ USB Serial ↔ Arduino R4 WiFi ↔ I2C ↔ Nano ESP32 (enkoderi)
```

### Topici za komunikaciju:

- `/cmd_vel` - komande za kretanje (Twist)
- `/odom` - odometrija iz enkodera (Odometry)  
- `/imu/data` - IMU podaci s R4 WiFi (Imu)

## Hardware Setup

### Arduino R4 WiFi povezivanje:
- **USB** → Raspberry Pi (micro-ROS agent)
- **SDA/SCL** → Arduino Nano ESP32 (I2C master)
- **PWM pinovi** → BTS7960 motor driveri
- **LSM6DS IMU** - interni na R4 WiFi

### Arduino Nano ESP32 povezivanje:
- **SDA/SCL** → Arduino R4 WiFi (I2C slave, address 0x42)
- **SDA1/SCL1** → AS5600 encoder 1 (desni kotač)
- **SDA2/SCL2** → AS5600 encoder 2 (lijevi kotač)

## Deployment

1. **Upload Arduino firmware:**
   
   **Arduino R4 WiFi kod (odaberi jednu opciju):**
   ```bash
   # Osnovna verzija (bez LED display)
   devastator_controler/devastator_r4_optimized.ino
   
   # Verzija s LED matrix vizualizacijom (preporučeno!)
   devastator_controler/devastator_r4_with_display.ino
   ```
   
   **Arduino Nano ESP32 kod:**
   ```bash
   # Upload devastator_encoders/src/main.cpp na Nano ESP32
   ```

2. **Required libraries za R4 WiFi s LED display:**
   ```bash
   # Ako koristiš verziju s LED display, instaliraj:
   # - ArduinoGraphics
   # - Arduino_LED_Matrix
   # - micro_ros_arduino
   # - Adafruit_LSM6DS
   # - ArduinoJson
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

Ako koristiš `devastator_r4_with_display.ino`, Arduino R4 WiFi će prikazivati:

| LED Pattern | Robot State |
|-------------|-------------|
| 🟢 Statičan uzorak | IDLE - robot miruje |
| ⬆️ Animacija naprijed | MOVING_FORWARD |
| ⬇️ Animacija nazad | MOVING_BACKWARD |
| ↩️ Animacija lijevo | TURNING_LEFT |
| ↪️ Animacija desno | TURNING_RIGHT |
| 🔴 Blink pattern | ERROR_STATE |

**Real-time feedback**: LED matrix se ažurira na 5Hz i pokazuje trenutno stanje robota!

## USB Device Detection

Provjeri koja USB devices su dostupni:

```bash
# Provjeri dostupne USB devices
ls -la /dev/tty*

# Arduino R4 WiFi obično se pojavi kao:
/dev/ttyACM0  # ili /dev/ttyACM1

# LIDAR obično kao:
/dev/ttyUSB0  # ili /dev/ttyUSB1
```

Ako su devices na različitim putovima, edituj `.env`:

```bash
MICROROS_DEVICE=/dev/ttyACM1
LIDAR_DEVICE=/dev/ttyUSB1
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

### Micro-ROS Agent ne može pristupiti USB:
```bash
# Provjeri permissions
ls -la /dev/ttyACM0
sudo usermod -a -G dialout $USER
# Restartuj session ili reboot
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

### Memory optimization (R4 WiFi):
- Micro-ROS agent baud rate: 115200 (balanced speed/reliability)
- I2C clock: 400kHz (fast mode)
- Encoder reading: 50Hz
- Odometry calculation: 20Hz

### Network optimization:
- ROS_DOMAIN_ID=0 (sve komponente)
- CycloneDDS middleware za best performance
- Host networking za Docker containers
- Custom CycloneDDS XML config for local optimization

### Container resource limits:
- micro_ros_agent: 256MB RAM, 0.5 CPU cores
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
- **Topic frequencies**: /cmd_vel, /odom, /scan, /imu/data
- **Container health**: all containers should be "healthy"
- **Resource usage**: memory <80%, CPU <70% average
- **USB devices**: Arduino on /dev/ttyACM0, LIDAR on /dev/ttyUSB0
