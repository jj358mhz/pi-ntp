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
├── portainer-agent/            # Deploys to raspberrypi-ntp as a Portainer Git-backed stack
│   └── docker-compose.yml      # portainer_agent container, pinned image version
└── monitoring/
    ├── monitoring-stack/       # Deploys to raspberrypi-utility as a Portainer Git-backed stack
    │   └── .env.example        # Template — copy to .env on raspberrypi-utility, fill in real values
    ├── telegraf-ntp/           # Deploys to raspberrypi-ntp via Portainer + cron
    │   └── .env.example        # Template — copy to .env on raspberrypi-ntp, fill in real token
    └── grafana/                # Dashboard JSON files + alert rules, imported via Grafana UI
```

---

## Key Services on raspberrypi-ntp

- `gpsd` — reads GPS module, exposes NMEA via shared memory
- `chrony` — NTP server, disciplined by GPS PPS
- `telegraf` (Docker) — ships chrony metrics and CPU temp to InfluxDB
- `portainer_agent` (Docker) — Portainer management; defined in `portainer-agent/docker-compose.yml`,
  deployed as a Portainer Git-backed stack (see Making Changes below)
- `cron` — runs scripts every minute:
    - `push_chrony_clients.sh` — NTP client metrics
    - `push_gps_satellites.sh` — GPS constellation + fix metrics (via gpsd)

## Key Services on raspberrypi-utility

- `influxdb` (Docker) — time series database, bucket: `ntp`
- `grafana` (Docker) — dashboards, OIDC login via Authentik (see Authentication below)
- `cadvisor` (Docker) — Docker container resource metrics, port 8082
- `portainer` (Docker) — container management UI

---

## InfluxDB Measurements

Written by the cron scripts on `raspberrypi-ntp`:

| Measurement      | Source               | Key fields                                                                           |
|------------------|----------------------|--------------------------------------------------------------------------------------|
| `chrony_clients` | `chronyc -n clients` | `ntp_requests`, `ntp_drops`, `ntp_poll`, `last_rx`                                   |
| `gps_sky`        | gpsd SKY message     | `nSat`, `uSat`, `hdop`, `gdop`, `tdop`, `pdop`                                       |
| `gps_satellites` | gpsd SKY message     | per-satellite: `ss`, `el`, `az`, `used`, `health` (tagged by `prn`, `constellation`) |
| `gps_tpv`        | gpsd TPV message     | `mode` (0/1=no fix, 2=2D, 3=3D), `ept`, `epx`, `epy`, `epv`                          |

**Note on `gps_tpv.ept`:** this receiver appears to report a flat, unchanging value (~0.005s)
regardless of actual satellite geometry or fix quality — likely a hardcoded gpsd fallback rather
than a real per-fix computation, since this particular GPS chipset may not transmit a genuine
timestamp-uncertainty figure over NMEA. Treat `ept` as informational only; `mode` and `tdop`
(from `gps_sky`) are the metrics that reflect real, live fix quality.

---

## Making Changes

### Portainer Git-backed stacks (monitoring-stack, portainer-agent)

`monitoring/monitoring-stack/` and `portainer-agent/` are each deployed in Portainer as a
Git-backed stack pointed at this repo, with polling enabled — Portainer periodically checks the
repo and **auto-redeploys on changes to the relevant `docker-compose.yml`**, no manual `docker
compose up` or copy step required. A commit + push to `main` is enough to ship a change to these
stacks. Env vars (`INFLUXDB_TOKEN`, `INFLUXDB_PASSWORD`, `GRAFANA_PASSWORD`,
`AUTHENTIK_GRAFANA_SECRET`) are still set manually in the Portainer stack UI, not read from a
committed `.env`. This is a different model from the telegraf-ntp cron scripts below, which are
manually copied and do **not** auto-sync.

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

Current dashboards:

- **raspberrypi-ntp — GPS Constellation** — satellite signal strength, DOP, fix status (`gps_tpv.mode`),
  GPS time error estimate, and sky coverage. "Current Satellite Status" table includes a data link
  on `prn`/`constellation` that opens the relevant Wikipedia satellite list (GPS or GLONASS) in a new tab.

### Grafana alert rule changes

Export YAML from Grafana UI (Alerting → Alert rules → Export) and save to
`monitoring/grafana/alert-rules.yaml`. Note: alert queries require an explicit
`float(v: r._value)` cast on int fields like `cpu_temp` — dashboard panel queries
don't need this because `aggregateWindow(fn: mean)` already produces a float.
See `monitoring/README.md` for details.

Current alert rules:

- **raspberrypi-ntp — GPS Fix Degraded** — fires when `gps_tpv.mode < 3` (i.e. drops below 3D fix)
  for a sustained 5 minutes. Evaluation group `gps-health`, 1m interval (matches the cron push rate).
  Routed to Slack. This is the earliest available warning that PPS timing discipline may be
  degrading, ahead of any visible change in chrony's own offset.

### Cron scripts

Located at `/opt/docker/stacks/telegraf-ntp/` on `raspberrypi-ntp`:

- `chrony_clients.sh` — generates InfluxDB line protocol from `chronyc -n clients`
- `push_chrony_clients.sh` — POSTs output to InfluxDB via curl
- `gps_satellites.py` — parses gpsd SKY *and* TPV JSON into InfluxDB line protocol
  (emits `gps_sky`, `gps_satellites`, and `gps_tpv` measurements)
- `push_gps_satellites.sh` — captures one SKY + one TPV message via a single `gpspipe` read,
  calls `gps_satellites.py`, and POSTs to InfluxDB
- Cron entries: `/etc/cron.d/chrony-clients`, `/etc/cron.d/gps-satellites`

Both push scripts source `/opt/docker/stacks/telegraf-ntp/.env` for `INFLUXDB_TOKEN` and will
**fail loudly** (clear error to stderr, non-zero exit) if `.env` is missing or still contains the
placeholder value — this is intentional, so a bad deploy is caught immediately in cron logs or a
manual test run rather than silently writing unauthorized requests.

**Important:** `/opt/docker/stacks/telegraf-ntp/` on the Pi is a separate, manually-managed
deployment path — it does **not** auto-sync from the git checkout. After `git pull`, scripts must
be copied over by hand:

```bash
sudo cp ~/git/pi-ntp/monitoring/telegraf-ntp/push_gps_satellites.sh /opt/docker/stacks/telegraf-ntp/
sudo cp ~/git/pi-ntp/monitoring/telegraf-ntp/gps_satellites.py /opt/docker/stacks/telegraf-ntp/
sudo chown root:root /opt/docker/stacks/telegraf-ntp/push_gps_satellites.sh /opt/docker/stacks/telegraf-ntp/gps_satellites.py
sudo chmod +x /opt/docker/stacks/telegraf-ntp/push_gps_satellites.sh /opt/docker/stacks/telegraf-ntp/gps_satellites.py
sudo /opt/docker/stacks/telegraf-ntp/push_gps_satellites.sh   # manual test — silent exit = success
```

---

## Secrets

- Real secrets live in `.env` files on each Pi, **never committed**:
    - `raspberrypi-ntp`: `/opt/docker/stacks/telegraf-ntp/.env` → `INFLUXDB_TOKEN`
    - `raspberrypi-utility`: same directory as the monitoring-stack `docker-compose.yml`
      (Portainer-managed; find current path with
      `sudo find / -iname docker-compose.yml 2>/dev/null | grep -v '/proc\|/sys'`) →
      `INFLUXDB_TOKEN`, `INFLUXDB_PASSWORD`, `GRAFANA_PASSWORD`, `AUTHENTIK_GRAFANA_SECRET`
      (the last is the Authentik OIDC provider's client secret for Grafana — see Authentication below)
- **The `INFLUXDB_TOKEN` value must match exactly** between `telegraf-ntp/.env` on
  `raspberrypi-ntp` and `monitoring-stack/.env` on `raspberrypi-utility` — it's the same InfluxDB
  admin token (set via `DOCKER_INFLUXDB_INIT_ADMIN_TOKEN` at first container boot), used by both
  the writer (the Pi pushing metrics) and the instance itself.
- `.env.example` files in this repo are tracked in git and contain placeholders only —
  `.gitignore` blocks `.env`/`.env.*` generally but explicitly excepts `.env.example` so the
  templates survive while real secrets don't.
- `DOCKER_INFLUXDB_INIT_*` variables only take effect on a container's **first boot** against an
  empty data volume — editing `.env` after InfluxDB already has data won't rotate the token or
  password on the running instance. Rotating requires either wiping the volume (destroys data) or
  changing it through InfluxDB's own UI/CLI and then updating `.env` on both Pis to match.
- Never commit real tokens, passwords, or keys.

---

## Authentication

Grafana on `raspberrypi-utility` is behind Caddy at `https://grafana.telcomjj.com/` and uses
Authentik (`https://auth.telcomjj.com/`) as its OIDC provider — configured via
`GF_AUTH_GENERIC_OAUTH_*` env vars in `monitoring/monitoring-stack/docker-compose.yml`.

- `GF_AUTH_DISABLE_LOGIN_FORM=true` + `GF_AUTH_OAUTH_AUTO_LOGIN=true`: the password login form is
  removed and visiting Grafana redirects straight to Authentik — OAuth is the only normal path in.
- Role mapping: Authentik group `grafana-admins` → Grafana `Admin`, everyone else → `Viewer`
  (`GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH`).
- Sign-out also ends the Authentik-side session (`GF_AUTH_GENERIC_OAUTH_SIGNOUT_REDIRECT_URL`), not
  just the Grafana cookie.
- **Break-glass:** if Authentik is unavailable, re-enable the password form by setting
  `GF_AUTH_DISABLE_LOGIN_FORM=false` in the Portainer stack env and redeploying, then
  `docker exec grafana grafana cli admin reset-admin-password <newpass>`. `GRAFANA_PASSWORD` in
  `.env` is otherwise unused day-to-day now that OAuth is the primary path.

---

## Verification Commands (run on raspberrypi-ntp)

```bash
# Check NTP sync status
chronyc sources -v
chronyc tracking

# Check GPS fix and satellites
cgps
gpsmon
gpspipe -w -n 20 | grep -E '"class":"(SKY|TPV)"'

# Check NTP clients
sudo chronyc clients

# Check Telegraf
docker logs telegraf --tail 20

# Check cron output
sudo grep chrony /var/log/syslog | tail -10
sudo grep gps /var/log/syslog | tail -10

# Manually test the push scripts (silent exit = success)
sudo /opt/docker/stacks/telegraf-ntp/push_chrony_clients.sh
sudo /opt/docker/stacks/telegraf-ntp/push_gps_satellites.sh
```

Check recent writes directly in InfluxDB (Data Explorer → Script Editor, or `influx query`):

```sql
from(bucket: "ntp")
  |> range(start: -5m)
  |> filter(fn: (r) => r._measurement == "gps_tpv" or r._measurement == "gps_sky" or r._measurement == "gps_satellites")
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