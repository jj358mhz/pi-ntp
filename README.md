# raspberrypi-ntp

A GPS-disciplined, stratum 1 NTP server built on a Raspberry Pi 5 running Debian Bookworm.
Uses a u-blox GPS module (model TBD) connected via UART, with a PPS signal on GPIO 18,
feeding [chrony](https://chrony-project.org/) for sub-microsecond time accuracy on the local network.

Inspired by: https://austinsnerdythings.com/2025/02/14/revisiting-microsecond-accurate-ntp-for-raspberry-pi-with-gps-pps-in-2025/

---

## Hardware

| Component | Details |
|-----------|---------|
| Board | Raspberry Pi 5 |
| OS | Debian GNU/Linux 12 (Bookworm), kernel 6.12 aarch64 |
| GPS Module | u-blox (model TBD) |
| GPS Connection | UART via `/dev/ttyAMA0` (serial0), 115200 baud |
| PPS Signal | GPIO 18 → `/dev/pps0` |
| IP Address | 192.168.123.123 (static, assigned via DHCP reservation) |

---

## How It Works

```
GPS Module (NMEA + PPS)
       │
       ├─ NMEA sentences → /dev/ttyAMA0 → gpsd → SHM 0 → chrony (NMEA refclock)
       └─ PPS pulse      → GPIO 18      → /dev/pps0     → chrony (PPS refclock)
                                                                │
                                              chrony serves NTP to LAN clients
                                              Stratum 1 / ~1-3ns offset
```

- **gpsd** reads the GPS module and exposes NMEA data via shared memory (SHM)
- **chrony** reads SHM 0 (NMEA) for time-of-day and `/dev/pps0` for the precise 1Hz pulse
- The PPS source is `lock`ed to NMEA so it inherits time-of-day from GPS
- Upstream NTP servers (NIST, Cloudflare) are configured as fallback/sanity check sources
- `local stratum 1` ensures the Pi continues serving time even if GPS is lost
- Clients on the LAN sync to `192.168.123.123`, achieving stratum 2

---

## Performance

Typical `chronyc sources -v` output when locked:

```
#x NMEA    0   0   377   -7374us  +/- 1000us   ← time-of-day ref, marked variable
#* PPS     0   3   377   +1585ns  +/-  637ns   ← selected source ✓
```

Typical `chronyc tracking` output:

```
Reference ID    : PPS
Stratum         : 1
System time     : 0.000001114 seconds fast
RMS offset      : 0.000000835 seconds
Skew            : 0.111 ppm
Root dispersion : 0.000007329 seconds
```

---

## Setup

### 1. OS

Flash Raspberry Pi OS Lite (64-bit, Bookworm) to SD card using Raspberry Pi Imager.
Enable SSH and set hostname to `raspberrypi-ntp` in the Imager advanced settings.

### 2. Boot Config (`/boot/firmware/config.txt`)

Add the following under the `[all]` section:

```ini
# GPS PPS signal on GPIO 18
dtoverlay=pps-gpio,gpiopin=18

# Enable UART for GPS serial connection
enable_uart=1
init_uart_baud=115200
dtparam=uart0=on

# Charge the onboard RTC battery (Pi 5)
dtparam=rtc_bbat_vchg=3000000
```

See [`config/boot-config-additions.txt`](config/boot-config-additions.txt) for the full annotated snippet.

### 3. Disable Serial Console

Edit `/boot/firmware/cmdline.txt` and remove `console=serial0,115200` if present,
so the UART is free for the GPS module. The line should look like:

```
console=tty1 root=PARTUUID=... rootfstype=ext4 fsck.repair=yes rootwait cfg80211.ieee80211_regdom=US
```

### 4. Install Packages

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y chrony gpsd gpsd-clients gpsd-tools pps-tools
```

### 5. Configure gpsd (`/etc/default/gpsd`)

```bash
DEVICES="/dev/ttyAMA0 /dev/pps0"
GPSD_OPTIONS="-n"
START_DAEMON="true"
USBAUTO="true"
BAUDRATE="115200"
```

See [`config/gpsd`](config/gpsd).

Enable and start:

```bash
sudo systemctl enable gpsd
sudo systemctl start gpsd
```

Verify GPS is getting a fix:

```bash
cgps        # live position/satellite view
gpsmon      # raw NMEA + signal strength
```

Verify PPS is firing:

```bash
sudo ppstest /dev/pps0
```

### 6. Configure chrony (`/etc/chrony/chrony.conf`)

See [`config/chrony.conf`](config/chrony.conf) for the full annotated config.

Key refclock directives:

```
refclock SHM 0 refid NMEA offset 0.105 precision 1e-3 poll 0 filter 3
refclock PPS /dev/pps0 refid PPS lock NMEA offset 0.0 poll 3 trust
```

Enable and restart:

```bash
sudo systemctl enable chrony
sudo systemctl restart chrony
```

### 7. Verify

```bash
# Check sources — look for #* next to PPS
chronyc sources -v

# Check overall sync quality
chronyc tracking

# Check clients connecting to this server
sudo chronyc clients

# Check server stats
sudo chronyc serverstats
```

---

## Files in This Repo

```
raspberrypi-ntp/
├── README.md
├── config/
│   ├── boot-config-additions.txt   # GPS/UART/PPS additions for /boot/firmware/config.txt
│   ├── chrony.conf                 # Full chrony configuration
│   └── gpsd                        # /etc/default/gpsd
├── scripts/
│   └── up                          # System update helper script
└── tools/
    ├── chrony_statistics.py        # Parse and plot chrony statistics log
    └── requirements.txt            # Python dependencies for chrony_statistics.py
```

---

## Clients

Configure any LAN host to use this server by pointing chrony or ntpd at `192.168.123.123`.

Example `/etc/chrony/chrony.conf` addition on a client:

```
server 192.168.123.123 iburst prefer
```

---

## Notes

- The `leapsectz right/UTC` directive is present in chrony.conf. If you add leap-smeared
  sources (Cloudflare NTS, Google), comment this out to avoid conflicts.
- The `testfile` (4GB) in the home directory was created during SD card speed testing
  and can be safely deleted: `rm ~/testfile`
- The `~/gps/venv` directory contains a Python venv used during GPS testing/exploration.
  It is not required for normal operation.
