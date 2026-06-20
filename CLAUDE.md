# CLAUDE.md

This file provides context for Claude Code when working in this repository.

---

## What This Repo Is

Configuration, documentation, and monitoring stack for a GPS-disciplined Stratum 1 NTP server
built on a Raspberry Pi 5. This is primarily a **documentation and config repo** — there are no
build steps, no tests, and no CI/CD pipeline.

---

## Hardware

| Host                  | Role                   | IP              | VLAN          |
|-----------------------|------------------------|-----------------|---------------|
| `raspberrypi-ntp`     | NTP server (Pi 5)      | 192.168.123.123 | LAN-NTP (123) |
| `raspberrypi-utility` | Monitoring host (Pi 4) | 192.168.1.248   | LAN-Core (1)  |

GPS module: Waveshare NEO-M8T GNSS Timing HAT (u-blox NEO-M8T)

- UART on `/dev/ttyAMA0` (serial0), 115200 baud
- PPS on GPIO 18 → `/dev/pps0`

---

## Repo Structure

```
├── config/                     # Config files that deploy to raspberrypi-ntp
│   ├── 99-gps-baud.rules       → /etc/udev/rules.d/
│   ├── cmdline.txt             → /boot/firmware/cmdline.txt
│   ├── config.txt              → /boot/firmware/config.txt
│   ├── chrony.conf             → /etc/chrony/chrony.conf
│   └── gpsd                    → /etc/default/gpsd
├── scripts/
│   └── up                      → ~/bin/up on raspberrypi-ntp
├── tools/
│   └── chrony_statistics.py    # Standalone analysis tool, runs locally
└── monitoring/
    ├── monitoring-stack/       # Deploys to raspberrypi-utility via Portainer
    ├── telegraf-ntp/           # Deploys to raspberrypi-ntp via Portainer + cron
    └── grafana/                # Dashboard JSON files + alert rules, imported via Grafana UI
```

---

## Key Services on raspberrypi-ntp

- `gpsd` — reads GPS module, exposes NMEA via shared memory
- `chrony` — NTP server, disciplined by GPS PPS
- `telegraf` (Docker) — ships chrony metrics and CPU temp to InfluxDB
- `portainer_agent` (Docker) — Portainer management
- `cron` — runs scripts every minute:
    - `push_chrony_clients.sh` — NTP client metrics
    - `push_gps_satellites.sh` — GPS constellation metrics (via gpsd)

## Key Services on raspberrypi-utility

- `influxdb` (Docker) — time series database, bucket: `ntp`
- `grafana` (Docker) — dashboards
- `portainer` (Docker) — container management UI

---

## Making Changes

### Config file changes

Edit the file in `config/`, then manually copy to the Pi:

```bash
scp config/chrony.conf pi@raspberrypi-ntp:/tmp/
ssh pi@raspberrypi-ntp "sudo cp /tmp/chrony.conf /etc/chrony/chrony.conf && sudo systemctl restart chrony"
```

### Telegraf config changes

Edit `monitoring/telegraf-ntp/telegraf.conf`, copy to Pi, restart via Portainer or:

```bash
scp monitoring/telegraf-ntp/telegraf.conf pi@raspberrypi-ntp:/opt/docker/stacks/telegraf-ntp/
ssh pi@raspberrypi-ntp "docker restart telegraf"
```

### Grafana dashboard changes

Export JSON from Grafana UI and save to `monitoring/grafana/`.

### Grafana alert rule changes

Export YAML from Grafana UI (Alerting → Alert rules → Export) and save to
`monitoring/grafana/alert-rules.yaml`. Note: alert queries require an explicit
`float(v: r._value)` cast on int fields like `cpu_temp` — dashboard panel queries
don't need this because `aggregateWindow(fn: mean)` already produces a float.
See `monitoring/README.md` for details.

### Cron scripts

Located at `/opt/docker/stacks/telegraf-ntp/` on `raspberrypi-ntp`:

- `chrony_clients.sh` — generates InfluxDB line protocol from `chronyc -n clients`
- `push_chrony_clients.sh` — POSTs output to InfluxDB via curl
- `gps_satellites.py` — parses gpsd SKY JSON into InfluxDB line protocol
- `push_gps_satellites.sh` — calls gps_satellites.py and POSTs to InfluxDB
- Cron entries: `/etc/cron.d/chrony-clients`, `/etc/cron.d/gps-satellites`

---

## Secrets

- InfluxDB token is in `push_chrony_clients.sh` on the Pi — **not committed to the repo**
- The `.env.example` files use placeholder values only
- Never commit real tokens, passwords, or keys

---

## Verification Commands (run on raspberrypi-ntp)

```bash
# Check NTP sync status
chronyc sources -v
chronyc tracking

# Check GPS fix and satellites
cgps
gpsmon
gpspipe -w -n 5 | grep SKY | python3 -m json.tool

# Check NTP clients
sudo chronyc clients

# Check Telegraf
docker logs telegraf --tail 20

# Check cron output
sudo grep chrony /var/log/syslog | tail -10
sudo grep gps /var/log/syslog | tail -10
```

---

## Network

- UniFi Dream Machine SE (`unifi-josephine`)
- Zone-Based Firewall (ZBF)
- DNAT rule redirects UDP 123 from LAN-IoT to 192.168.123.123
- ZBF rule `Allow_NTP_to_InfluxDB` permits TCP 8086 from LAN-NTP to 192.168.1.248
- Pi-hole DNS at 192.168.53.53
- **Use IP addresses, not hostnames** in config files — mDNS `.local` resolution is unreliable across VLANs (NTP Pi on
  192.168.123.x, utility Pi on 192.168.1.x)
