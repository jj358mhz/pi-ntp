# raspberrypi-ntp

A GPS-disciplined, stratum 1 NTP server built on a Raspberry Pi 5 running Debian Bookworm.
Uses a Waveshare NEO-M8T GNSS Timing HAT connected via UART, with a PPS signal on GPIO 18,
feeding [chrony](https://chrony-project.org/) for sub-microsecond time accuracy on the local network.

Inspired
by: https://austinsnerdythings.com/2025/02/14/revisiting-microsecond-accurate-ntp-for-raspberry-pi-with-gps-pps-in-2025/

---

## Hardware

| Component           | Details                                                                                     |
|---------------------|---------------------------------------------------------------------------------------------|
| Board               | Raspberry Pi 5                                                                              |
| OS                  | Debian GNU/Linux 12 (Bookworm), kernel 6.12 aarch64                                         |
| GPS Module          | [Waveshare NEO-M8T GNSS Timing HAT](https://www.waveshare.com/wiki/NEO-M8T_GNSS_TIMING_HAT) |
| GNSS Constellations | GPS, BeiDou, Galileo, GLONASS (concurrent, up to 3)                                         |
| GPS Connection      | UART via `/dev/ttyAMA0` (serial0), 115200 baud                                              |
| PPS Signal          | GPIO 18 → `/dev/pps0`                                                                       |
| Backup Battery      | ML1220 rechargeable cell (preserves ephemeris for hot starts)                               |
| IP Address          | 192.168.123.123 (static, assigned via DHCP reservation)                                     |

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
- Upstream NTP servers (NIST, Cloudflare, Apple, US pool) are configured as fallback/sanity check sources
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

The GPS-relevant additions are under the `[all]` section at the bottom. Copy [`config/config.txt`](config/config.txt) to
`/boot/firmware/config.txt`, or manually add:

```ini
# GPS PPS signal on GPIO 18
dtoverlay = pps-gpio,gpiopin=18

# Enable UART for GPS serial connection
enable_uart = 1
init_uart_baud = 115200
dtparam = uart0=on

# Charge the onboard RTC battery (Pi 5)
dtparam = rtc_bbat_vchg=3000000
```

See [`config/config.txt`](config/config.txt) for the full annotated file.

### 3. Disable Serial Console

The UART serial console (`console=serial0,115200`) must be absent from `/boot/firmware/cmdline.txt`
so the GPS module has exclusive use of the UART. This is already the case on this build — see
[`config/cmdline.txt`](config/cmdline.txt).

If setting up from scratch, check that your `cmdline.txt` does **not** contain `console=serial0,115200`.
Remove it if present. The line should look like:

```
console=tty1 root=PARTUUID=2fa0ed8f-02 rootfstype=ext4 fsck.repair=yes rootwait cfg80211.ieee80211_regdom=US
```

### 4. udev Rule — GPS Baud Rate

The NEO-M8T defaults to 9600 baud but is configured here at 115200. A udev rule ensures
the baud rate is set correctly when the device is added at boot:

```bash
sudo cp config/99-gps-baud.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
```

See [`config/99-gps-baud.rules`](config/99-gps-baud.rules).

### 5. Install Packages

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y chrony gpsd gpsd-clients gpsd-tools pps-tools
```

### 6. Configure gpsd (`/etc/default/gpsd`)

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

### 7. Configure chrony (`/etc/chrony/chrony.conf`)

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

### 8. Verify

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
├── README.md
├── CLAUDE.md
├── config/
│   ├── 99-gps-baud.rules           # /etc/udev/rules.d/ — sets ttyAMA0 to 115200 baud
│   ├── cmdline.txt                 # /boot/firmware/cmdline.txt (serial console removed)
│   ├── config.txt                  # /boot/firmware/config.txt
│   ├── chrony.conf                 # /etc/chrony/chrony.conf
│   └── gpsd                        # /etc/default/gpsd
├── scripts/
│   └── up                          # System update helper script
├── tools/
│   ├── chrony_statistics.py        # Parse and plot chrony statistics log
│   └── requirements.txt            # Python dependencies for chrony_statistics.py
└── monitoring/                     # Telegraf + InfluxDB + Grafana monitoring stack
    ├── README.md                   # Monitoring setup and metrics reference
    ├── monitoring-stack/           # InfluxDB v2 + Grafana (deploy on raspberrypi-utility)
    ├── telegraf-ntp/               # Telegraf + cron scripts (deploy on raspberrypi-ntp)
    └── grafana/                    # Dashboard JSON files
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
- The `~/gps/venv` directory on the Pi contains a Python venv used during GPS testing/exploration.
  It is not required for normal operation.
