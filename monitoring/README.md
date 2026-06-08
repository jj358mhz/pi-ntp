# Monitoring

Chrony NTP metrics pipeline for `raspberrypi-ntp` using Telegraf, InfluxDB v2, and Grafana.

---

## Architecture

```
raspberrypi-ntp (192.168.123.123)
├── Telegraf container
│   ├── inputs.chrony → queries chronyd via UDP 127.0.0.1:323
│   │   metrics: tracking, sources, sourcestats
│   └── outputs.influxdb_v2 → http://192.168.1.248:8086
└── cron (every 60s)
    └── push_chrony_clients.sh
        ├── chrony_clients.sh → chronyc -n clients → InfluxDB line protocol
        └── curl POST → http://192.168.1.248:8086 → chrony_clients measurement

raspberrypi-utility (192.168.1.248)
├── InfluxDB v2 container
│   └── bucket: ntp
│       ├── measurement: chrony             (tracking data)
│       ├── measurement: chrony_sources     (per-source offsets + reachability)
│       ├── measurement: chrony_sourcestats (per-source statistics)
│       └── measurement: chrony_clients     (per-client NTP request counts)
└── Grafana container
    ├── Dashboard: raspberrypi-ntp — GPS Stratum 1 NTP Server
    └── Dashboard: raspberrypi-ntp — NTP Clients
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

Save this token — you'll need it in both stacks.

### Step 2 — Deploy monitoring stack on `raspberrypi-utility`

In Portainer → `local` environment → Stacks → Add Stack:

- Name: `monitoring`
- Paste contents of [`monitoring-stack/docker-compose.yml`](monitoring-stack/docker-compose.yml)
- Add environment variables (Advanced mode):

```
INFLUXDB_TOKEN=your-generated-token
INFLUXDB_PASSWORD=your-strong-password
GRAFANA_PASSWORD=your-strong-password
```

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

### Step 5 — Set up client metrics cron job on `raspberrypi-ntp`

```bash
# Copy scripts
sudo cp telegraf-ntp/chrony_clients.sh /opt/docker/stacks/telegraf-ntp/
sudo cp telegraf-ntp/push_chrony_clients.sh /opt/docker/stacks/telegraf-ntp/
sudo chmod +x /opt/docker/stacks/telegraf-ntp/chrony_clients.sh
sudo chmod +x /opt/docker/stacks/telegraf-ntp/push_chrony_clients.sh

# Set your InfluxDB token in push_chrony_clients.sh
sudo nano /opt/docker/stacks/telegraf-ntp/push_chrony_clients.sh

# Install cron job
echo "* * * * * root /opt/docker/stacks/telegraf-ntp/push_chrony_clients.sh" | sudo tee /etc/cron.d/chrony-clients
```

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

---

## Files

```
monitoring/
├── README.md
├── monitoring-stack/
│   ├── docker-compose.yml          # InfluxDB v2 + Grafana (raspberrypi-utility)
│   └── .env.example
├── telegraf-ntp/
│   ├── docker-compose.yml          # Telegraf container (raspberrypi-ntp)
│   ├── telegraf.conf               # Chrony tracking/sources/sourcestats inputs
│   ├── chrony_clients.sh           # Generates InfluxDB line protocol from chronyc clients
│   ├── push_chrony_clients.sh      # Wraps chrony_clients.sh and POSTs to InfluxDB
│   └── .env.example
└── grafana/
    ├── raspberrypi-ntp-dashboard.json          # NTP server metrics dashboard
    └── raspberrypi-ntp-clients-dashboard.json  # NTP client monitoring dashboard
```

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

---

## Notes

- Telegraf runs with `network_mode: host` and `debug = true` — the debug flag
  was required to initialize the output connection correctly on startup
- The chrony input plugin connects via `udp://127.0.0.1:323` (not the unix socket)
- `serverstats` metric is excluded — it requires chrony command authentication;
  `cmdallow 127.0.0.1` is present in `chrony.conf` for future use
- Client metrics use a cron+curl approach because `chronyc` binary dependencies
  are not available inside the Telegraf container
- The UniFi ZBF rule `Allow_NTP_to_InfluxDB` permits TCP 8086 from `LAN-NTP`
  zone to `192.168.1.248`