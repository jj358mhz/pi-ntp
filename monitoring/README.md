# Monitoring

Chrony NTP metrics pipeline for `raspberrypi-ntp` using Telegraf, InfluxDB v2, and Grafana.

---

## Architecture

```
raspberrypi-ntp (192.168.123.123)
├── Telegraf container
│   ├── inputs.chrony → queries chronyd via UDP 127.0.0.1:323
│   │   metrics: tracking, sources, sourcestats
│   ├── inputs.file → /sys/class/thermal/thermal_zone0/temp → cpu_temp
│   ├── inputs.file → /sys/class/rtc/rtc0/battery_voltage → rtc_battery_voltage
│   └── outputs.influxdb_v2 → http://192.168.1.248:8086
└── cron (every 60s)
    ├── push_chrony_clients.sh
    │   ├── chrony_clients.sh → chronyc -n clients → InfluxDB line protocol
    │   └── curl POST → http://192.168.1.248:8086 → chrony_clients measurement
    └── push_gps_satellites.sh
        ├── gpspipe → one SKY + one TPV message → gps_satellites.py → InfluxDB line protocol
        └── curl POST → http://192.168.1.248:8086 → gps_sky + gps_satellites + gps_tpv measurements

raspberrypi-utility (192.168.1.248)
├── InfluxDB v2 container
│   └── bucket: ntp
│       ├── measurement: chrony               (tracking data)
│       ├── measurement: chrony_sources       (per-source offsets + reachability)
│       ├── measurement: chrony_sourcestats   (per-source statistics)
│       ├── measurement: chrony_clients       (per-client NTP request counts)
│       ├── measurement: cpu_temp             (Pi 5 CPU temperature in millidegrees)
│       ├── measurement: rtc_battery_voltage  (Pi 5 onboard RTC backup battery, microvolts)
│       ├── measurement: gps_sky              (satellite count + DOP values)
│       ├── measurement: gps_satellites       (per-satellite signal strength + status)
│       └── measurement: gps_tpv              (fix mode + time/position error estimates)
├── Grafana container
│   ├── OIDC login via Authentik (https://auth.telcomjj.com/), behind Caddy at grafana.telcomjj.com
│   ├── Dashboard: raspberrypi-ntp — GPS Stratum 1 NTP Server
│   ├── Dashboard: raspberrypi-ntp — NTP Clients
│   └── Dashboard: raspberrypi-ntp — GPS Constellation
└── cAdvisor container — Docker container resource metrics, port 8082
```

---

## Prerequisites

- Docker installed on both Pis
- Portainer agent running on `raspberrypi-ntp` (see main README)
- ZBF rule allowing `LAN-NTP → LAN-Core` on TCP 8086 in UniFi

---

## Deployment

### Step 1 — Generate InfluxDB token

On `raspberrypi-utility`:

```bash
openssl rand -hex 32
```

Save this token — you'll need it in both stacks. **It must be identical on both Pis** — it's the
same InfluxDB admin token, used both to initialize the instance and to authenticate every write
to it.

### Step 2 — Deploy monitoring stack on `raspberrypi-utility`

This stack is deployed as a **Git-backed Portainer stack** pointed at this repo, with polling
enabled — Portainer periodically re-pulls `monitoring-stack/docker-compose.yml` and redeploys
automatically on changes, so a commit + push to `main` ships the change without a manual
`docker compose up`. Environment variables are still set by hand in the Portainer stack UI, not
read from a committed `.env`.

In Portainer → `local` environment → Stacks → Add Stack:

- Name: `monitoring`
- Repository: this repo, path `monitoring-stack/docker-compose.yml`, polling enabled
- Add environment variables (Advanced mode):

```
INFLUXDB_TOKEN=your-generated-token
INFLUXDB_PASSWORD=your-strong-password
GRAFANA_PASSWORD=your-strong-password
AUTHENTIK_GRAFANA_SECRET=your-authentik-oidc-client-secret
```

**Note:** `INFLUXDB_TOKEN`/`INFLUXDB_PASSWORD` are read by `DOCKER_INFLUXDB_INIT_*` env vars in the
compose file, which only take effect on the container's **first boot** against an empty data
volume. Changing them later won't rotate anything on an already-initialized instance.

**Grafana auth:** login is OAuth-only via Authentik (`GF_AUTH_DISABLE_LOGIN_FORM=true`,
`GF_AUTH_OAUTH_AUTO_LOGIN=true`) — `GRAFANA_PASSWORD` is a break-glass fallback only, not used
day-to-day. See `CLAUDE.md` → Authentication for the full OIDC config and break-glass steps.

### Step 3 — Create Telegraf config on `raspberrypi-ntp`

```bash
sudo mkdir -p /opt/docker/stacks/telegraf-ntp
sudo chown pi:pi /opt/docker/stacks/telegraf-ntp
cp telegraf-ntp/telegraf.conf /opt/docker/stacks/telegraf-ntp/telegraf.conf
```

Edit `telegraf.conf` and set your InfluxDB URL and token.

### Step 4 — Deploy Telegraf stack on `raspberrypi-ntp`

In Portainer → `ntp` environment → Stacks → Add Stack:

- Name: `telegraf-ntp`
- Paste contents of [`telegraf-ntp/docker-compose.yml`](telegraf-ntp/docker-compose.yml)
- Add environment variable (Advanced mode):

```
INFLUXDB_TOKEN=your-generated-token
```

### Step 5 — Set up cron jobs on `raspberrypi-ntp`

```bash
# Copy all scripts
sudo cp telegraf-ntp/chrony_clients.sh /opt/docker/stacks/telegraf-ntp/
sudo cp telegraf-ntp/push_chrony_clients.sh /opt/docker/stacks/telegraf-ntp/
sudo cp telegraf-ntp/gps_satellites.py /opt/docker/stacks/telegraf-ntp/
sudo cp telegraf-ntp/push_gps_satellites.sh /opt/docker/stacks/telegraf-ntp/
sudo chmod +x /opt/docker/stacks/telegraf-ntp/*.sh
sudo chown root:root /opt/docker/stacks/telegraf-ntp/*.sh /opt/docker/stacks/telegraf-ntp/*.py

# Create .env with the real token (same value as Step 1)
sudo cp telegraf-ntp/.env.example /opt/docker/stacks/telegraf-ntp/.env
sudo nano /opt/docker/stacks/telegraf-ntp/.env
sudo chmod 600 /opt/docker/stacks/telegraf-ntp/.env
sudo chown root:root /opt/docker/stacks/telegraf-ntp/.env

# Test before trusting cron — silent exit on both = success
sudo /opt/docker/stacks/telegraf-ntp/push_chrony_clients.sh
sudo /opt/docker/stacks/telegraf-ntp/push_gps_satellites.sh

# Install cron jobs
echo "* * * * * root /opt/docker/stacks/telegraf-ntp/push_chrony_clients.sh" | sudo tee /etc/cron.d/chrony-clients
echo "* * * * * root /opt/docker/stacks/telegraf-ntp/push_gps_satellites.sh" | sudo tee /etc/cron.d/gps-satellites
```

Both push scripts source `.env` for `INFLUXDB_TOKEN` at runtime and exit with a clear error
(rather than silently writing unauthorized requests) if `.env` is missing or still has the
placeholder value — if the manual test above fails, check `.env` first.

**Note:** `/opt/docker/stacks/telegraf-ntp/` is a deployment path, not a git checkout — it does
not auto-update on `git pull`. Re-run the relevant `cp`/`chmod`/`chown` lines above any time the
scripts change in this repo.

### Step 6 — Add InfluxDB data source in Grafana

Browse to `http://raspberrypi-utility:3000`:

1. Connections → Add new connection → InfluxDB
2. Query Language: **Flux**
3. URL: `http://influxdb:8086`
4. Organization: `homelab`
5. Token: your token
6. Default Bucket: `ntp`
7. Save & Test

### Step 7 — Import Grafana dashboards

Dashboards → New → Import → Upload JSON file:

- [`grafana/raspberrypi-ntp-dashboard.json`](grafana/raspberrypi-ntp-dashboard.json) — NTP server metrics
- [`grafana/raspberrypi-ntp-clients-dashboard.json`](grafana/raspberrypi-ntp-clients-dashboard.json) — client monitoring
- [`grafana/raspberrypi-ntp-gps-dashboard.json`](grafana/raspberrypi-ntp-gps-dashboard.json) — GPS constellation

**Note on dashboard JSON format:**

- `raspberrypi-ntp-dashboard.json` uses the Grafana v13 API format (`dashboard.grafana.app/v2`) and requires **Grafana
  v13+**
- The datasource is referenced by internal ID (`efodpma1sz474d`) — if importing on a different Grafana instance, edit
  the JSON and replace all occurrences of `efodpma1sz474d` with your own InfluxDB datasource name
- `raspberrypi-ntp-clients-dashboard.json` uses the classic format and works on Grafana v10+
- The GPS Constellation dashboard's "Current Satellite Status" table includes a data link on the
  `prn`/`constellation` column that opens the relevant Wikipedia satellite list (GPS or GLONASS)
  in a new tab — useful for looking up which physical satellite (SVN) a given PRN currently maps to

---

## Files

```
monitoring/
├── README.md
├── monitoring-stack/
│   ├── docker-compose.yml          # InfluxDB v2 + Grafana + cAdvisor (raspberrypi-utility)
│   └── .env.example
├── telegraf-ntp/
│   ├── docker-compose.yml          # Telegraf container (raspberrypi-ntp)
│   ├── telegraf.conf               # Chrony + CPU temp + RTC battery voltage inputs
│   ├── chrony_clients.sh           # Generates InfluxDB line protocol from chronyc clients
│   ├── push_chrony_clients.sh      # Wraps chrony_clients.sh and POSTs to InfluxDB
│   ├── gps_satellites.py           # Parses gpsd SKY + TPV JSON into InfluxDB line protocol
│   ├── push_gps_satellites.sh      # Captures SKY+TPV via gpspipe, calls gps_satellites.py, POSTs to InfluxDB
│   └── .env.example
└── grafana/
    ├── raspberrypi-ntp-dashboard.json          # NTP server metrics dashboard
    ├── raspberrypi-ntp-clients-dashboard.json  # NTP client monitoring dashboard
    ├── raspberrypi-ntp-gps-dashboard.json      # GPS constellation dashboard
    └── alert-rules.yaml                        # Alert rules (provisioning export)
```

---

## Alerting

### CPU temperature

CPU temperature on `raspberrypi-ntp` is monitored by two Grafana alert rules, routed to Slack.

| Rule            | Condition     | Pending period           | Severity |
|-----------------|---------------|--------------------------|----------|
| Warning (70°C)  | `last() > 70` | 2m                       | warning  |
| Critical (80°C) | `last() > 80` | None (fires immediately) | critical |

- **Folder:** `Raspberry Pi Monitoring`
- **Evaluation group:** `pi-temp-checks`, evaluated every 2m
- **Data source:** InfluxDB (`efodpma1sz474d`), bucket `ntp`, measurement `cpu_temp`
- **Contact point:** Slack app `Grafana Alerts` → `#grafana-alerts`, via incoming webhook
- **Labels:** `host=raspberrypi-ntp`, `severity={warning|critical}`, `alertname=CPUTempHigh`

**Important Flux gotcha:** unlike the dashboard panel queries (which use `aggregateWindow(fn: mean)`
and get an implicit float), alert rule queries here use `last()` on the raw `cpu_temp` field, which
stays an **int**. Dividing an int by a float literal (`1000.0`) throws `type conflict: float != int`
in Flux's alert evaluator. The fix is an explicit cast:

```flux
|> map(fn: (r) => ({r with _value: float(v: r._value) / 1000.0}))
```

### GPS fix status

| Rule             | Condition        | Pending period | Severity |
|------------------|------------------|----------------|----------|
| GPS Fix Degraded | `last(mode) < 3` | 5m             | critical |

- **Folder:** `Raspberry Pi Monitoring`
- **Evaluation group:** `gps-health`, evaluated every 1m (matches the cron push rate)
- **Data source:** InfluxDB (`efodpma1sz474d`), bucket `ntp`, measurement `gps_tpv`, field `mode`
- **Contact point:** same Slack contact point as the CPU temp alerts
- 5-minute pending period is intentional — a momentary dip to 2D fix from a brief obstruction
  shouldn't page; only a sustained loss of 3D fix should. This is the earliest available signal
  that PPS timing discipline may be degrading, ahead of any visible change in chrony's own offset.

No alert rules exist yet for `rtc_battery_voltage` — pending a baseline observation period (see
below).

Provisioning export: [`grafana/alert-rules.yaml`](grafana/alert-rules.yaml). To restore on a fresh
Grafana instance, re-import via **Alerting → Alert rules → Export/Import**, and recreate the
Slack contact point manually (webhook URLs aren't included in the export).

---

## Chrony Metrics Reference

### `chrony` measurement (tracking)

| Field             | Unit    | Description                         |
|-------------------|---------|-------------------------------------|
| `system_time`     | seconds | Current clock offset from NTP time  |
| `last_offset`     | seconds | Offset of the last clock update     |
| `rms_offset`      | seconds | Long-term RMS average of offsets    |
| `frequency`       | ppm     | Clock frequency error               |
| `residual_freq`   | ppm     | Residual frequency after correction |
| `skew`            | ppm     | Estimated error in frequency        |
| `root_delay`      | seconds | Network delay to reference          |
| `root_dispersion` | seconds | Dispersion accumulated to reference |
| `update_interval` | seconds | Interval between clock updates      |

Tags: `host`, `leap_status`, `reference_id`, `stratum`

### `chrony_sources` measurement (per-source)

| Field                      | Unit          | Description                                         |
|----------------------------|---------------|-----------------------------------------------------|
| `latest_measurement`       | seconds       | Most recent offset measurement                      |
| `latest_measurement_error` | seconds       | Error of most recent measurement                    |
| `reachability`             | octal (0-255) | 8-poll reachability register; 255 = fully reachable |
| `poll`                     | log2(seconds) | Current polling interval                            |
| `sample`                   | integer       | Number of samples in filter                         |

Tags: `host`, `peer`, `mode`, `state`, `stratum`

### `chrony_sourcestats` measurement (per-source statistics)

| Field                | Unit    | Description                          |
|----------------------|---------|--------------------------------------|
| `offset`             | seconds | Estimated offset of source           |
| `offset_error`       | seconds | Error bound on offset estimate       |
| `residual_frequency` | ppm     | Residual frequency after regression  |
| `skew`               | ppm     | Estimated skew of source frequency   |
| `stddev`             | seconds | Standard deviation of offset samples |
| `samples`            | integer | Number of samples in regression      |
| `runs`               | integer | Runs of same-sign residuals          |
| `span_seconds`       | seconds | Time span of sample set              |

Tags: `host`, `peer`, `reference_id`

### `chrony_clients` measurement (per-client)

Collected via cron every 60 seconds using `chronyc -n clients`.

| Field          | Unit          | Description                                    |
|----------------|---------------|------------------------------------------------|
| `ntp_requests` | integer       | Total NTP requests from this client            |
| `ntp_drops`    | integer       | Dropped NTP requests                           |
| `ntp_poll`     | log2(seconds) | Current poll interval (-1 if unknown)          |
| `cmd_requests` | integer       | chronyc command requests                       |
| `cmd_drops`    | integer       | Dropped command requests                       |
| `last_rx`      | seconds       | Seconds since last NTP request (-1 if unknown) |

Tags: `host`, `client` (client IP address)

### `cpu_temp` measurement

Collected via Telegraf `inputs.file` every 10 seconds from `/sys/class/thermal/thermal_zone0/temp`.
Values are in millidegrees Celsius — divide by 1000 in Grafana queries.

Tags: `host`

### `rtc_battery_voltage` measurement

Collected via Telegraf `inputs.file` every 60 seconds from `/sys/class/rtc/rtc0/battery_voltage`.
This is the Pi 5's onboard RTC backup battery (connected via the J5/BAT connector), trickle-charged
to 3.0V via `dtparam=rtc_bbat_vchg=3000000` in `config.txt`. Distinct from the GPS module's ML1220
backup cell, which has no software-readable voltage.

Value is in microvolts — divide by 1,000,000 in Grafana queries.

Tags: `host`

### `gps_sky` measurement (sky summary)

Collected via cron every 60 seconds from gpsd SKY report.

| Field  | Unit    | Description                      |
|--------|---------|----------------------------------|
| `nSat` | integer | Total satellites visible         |
| `uSat` | integer | Satellites used in fix           |
| `hdop` | float   | Horizontal dilution of precision |
| `gdop` | float   | Geometric dilution of precision  |
| `tdop` | float   | Time dilution of precision       |
| `pdop` | float   | Position dilution of precision   |

Tags: `host`

### `gps_satellites` measurement (per-satellite)

Collected via cron every 60 seconds from gpsd SKY report. Only satellites with signal (ss > 0) or used in fix are
emitted.

| Field    | Unit    | Description                      |
|----------|---------|----------------------------------|
| `ss`     | dB-Hz   | Signal strength                  |
| `el`     | degrees | Elevation angle                  |
| `az`     | degrees | Azimuth                          |
| `health` | integer | Satellite health (1=healthy)     |

Tags: `host`, `prn` (satellite PRN number), `constellation` (GPS/GLONASS/Galileo/BeiDou/SBAS/QZSS), `used` (true/false — whether satellite is used in fix)

### `gps_tpv` measurement (fix status)

Collected via cron every 60 seconds from gpsd TPV report, captured in the same `gpspipe` read as
the SKY report used for `gps_sky`/`gps_satellites` above.

| Field  | Unit    | Description                                    |
|--------|---------|------------------------------------------------|
| `mode` | integer | Fix mode: 0/1 = no fix, 2 = 2D fix, 3 = 3D fix |
| `ept`  | seconds | gpsd's estimated timestamp error               |
| `epx`  | meters  | Estimated longitude error                      |
| `epy`  | meters  | Estimated latitude error                       |
| `epv`  | meters  | Estimated vertical error                       |

Tags: `host`

**`mode` is the most operationally important field here** — a sustained drop below 3 is the
earliest available warning that PPS timing discipline may be degrading (see the GPS Fix Degraded
alert above).

**`ept` appears to be a flat, unchanging value (~0.005s) on this receiver**, regardless of actual
satellite geometry or signal quality. This strongly suggests the chipset doesn't transmit a real
per-fix timestamp-uncertainty figure over NMEA, and gpsd is falling back to a hardcoded default
rather than computing it live. Treat `ept` (and `epx`/`epy`/`epv`) as informational only — `mode`
and `gps_sky.tdop` are the fields that reflect genuine, live fix quality.

---

## Notes

- Telegraf runs with `network_mode: host` and `debug = true` — the debug flag
  was required to initialize the output connection correctly on startup
- The chrony input plugin connects via `udp://127.0.0.1:323` (not the unix socket)
- `serverstats` metric is excluded — it requires chrony command authentication;
  `cmdallow 127.0.0.1` is present in `chrony.conf` for future use
- Client metrics use a cron+curl approach because `chronyc` binary dependencies
  are not available inside the Telegraf container
- GPS metrics use `gpspipe` to query gpsd on the host — Python 3 is required on
  `raspberrypi-ntp` (installed by default on Bookworm). A single `gpspipe -n 20`
  read captures both the SKY and TPV message types needed for all three GPS
  measurements; `gps_satellites.py` auto-detects message class line-by-line
  rather than assuming a fixed order, so it degrades gracefully if one message
  type doesn't appear in a given read
- CPU temperature is collected in millidegrees; use `|> map(fn: (r) => ({r with _value: r._value / 1000.0}))` in Flux
  queries
- Alert rule queries (as opposed to dashboard panel queries) require an explicit `float(v: r._value)`
  cast before dividing — `last()` preserves the raw int type, and Flux won't implicitly promote
  int ÷ float the way `aggregateWindow(fn: mean)` does
- RTC battery voltage uses a slower 60s poll interval than CPU temp (10s) since it changes
  much more slowly — no alert thresholds are set yet pending a baseline observation period
- The UniFi ZBF rule `Allow_NTP_to_InfluxDB` permits TCP 8086 from `LAN-NTP`
  zone to `192.168.1.248`
- Both `push_chrony_clients.sh` and `push_gps_satellites.sh` source `.env` for `INFLUXDB_TOKEN`
  rather than hardcoding it, and exit with a clear error if `.env` is missing or still has the
  placeholder value — see `CLAUDE.md` → Secrets for the full token-management/rotation notes