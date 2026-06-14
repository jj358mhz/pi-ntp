#!/bin/sh
# push_gps_satellites.sh — Collect GPS satellite metrics from gpsd and push to InfluxDB
# Run via cron every 60 seconds on raspberrypi-ntp.
#
# Calls gps_satellites.py to parse gpsd SKY output into InfluxDB line protocol,
# then POSTs directly to InfluxDB via curl.
#
# Cron entry:
#   * * * * * root /opt/docker/stacks/telegraf-ntp/push_gps_satellites.sh
#
# Measurements:
#   gps_sky        — nSat, uSat, hdop, gdop, tdop, pdop
#   gps_satellites — per-satellite: ss, el, az, used, health

INFLUXDB_URL="http://192.168.1.248:8086"
INFLUXDB_TOKEN="changeme-replace-with-your-token"
INFLUXDB_ORG="homelab"
INFLUXDB_BUCKET="ntp"
HOST="raspberrypi-ntp"
SCRIPT_DIR="/opt/docker/stacks/telegraf-ntp"

TIMESTAMP=$(date +%s)000000000

# Get one SKY message and parse it
SKY=$(gpspipe -w -n 15 2>/dev/null | grep '"class":"SKY"' | tail -1)

if [ -z "$SKY" ]; then
    echo "$(date): Error: no SKY message from gpsd" >&2
    exit 1
fi

# Parse and push
echo "$SKY" | python3 "${SCRIPT_DIR}/gps_satellites.py" "$HOST" "$TIMESTAMP" | \
curl -s -X POST \
  "${INFLUXDB_URL}/api/v2/write?bucket=${INFLUXDB_BUCKET}&org=${INFLUXDB_ORG}" \
  -H "Authorization: Token ${INFLUXDB_TOKEN}" \
  -H "Content-Type: text/plain" \
  --data-binary @-
