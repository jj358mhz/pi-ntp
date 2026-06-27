#!/bin/sh
# push_gps_satellites.sh — Collect GPS satellite + fix metrics from gpsd and push to InfluxDB
# Run via cron every 60 seconds on raspberrypi-ntp.
#
# Captures one SKY message and one TPV message from a single gpspipe read,
# passes both to gps_satellites.py for parsing into InfluxDB line protocol,
# then POSTs directly to InfluxDB via curl.
#
# Cron entry:
#   * * * * * root /opt/docker/stacks/telegraf-ntp/push_gps_satellites.sh
#
# Measurements:
#   gps_sky        — nSat, uSat, hdop, gdop, tdop, pdop
#   gps_satellites — per-satellite: ss, el, az, used, health
#   gps_tpv        — mode (0/1=no fix, 2=2D, 3=3D), ept, epx, epy, epv

INFLUXDB_URL="http://192.168.1.248:8086"
INFLUXDB_TOKEN="changeme-replace-with-your-token"
INFLUXDB_ORG="homelab"
INFLUXDB_BUCKET="ntp"
HOST="raspberrypi-ntp"
SCRIPT_DIR="/opt/docker/stacks/telegraf-ntp"

TIMESTAMP=$(date +%s)000000000

# Single gpspipe read — grab enough lines to see both SKY and TPV go by.
# -w gives JSON, -n N reads N messages then exits.
RAW=$(gpspipe -w -n 20 2>/dev/null)

SKY=$(echo "$RAW" | grep '"class":"SKY"' | tail -1)
TPV=$(echo "$RAW" | grep '"class":"TPV"' | tail -1)

if [ -z "$SKY" ] && [ -z "$TPV" ]; then
    echo "$(date): Error: no SKY or TPV message from gpsd" >&2
    exit 1
fi

# Feed whichever messages we got (one per line) into the parser, then push.
{
    [ -n "$SKY" ] && echo "$SKY"
    [ -n "$TPV" ] && echo "$TPV"
} | python3 "${SCRIPT_DIR}/gps_satellites.py" "$HOST" "$TIMESTAMP" | \
curl -s -X POST \
  "${INFLUXDB_URL}/api/v2/write?bucket=${INFLUXDB_BUCKET}&org=${INFLUXDB_ORG}" \
  -H "Authorization: Token ${INFLUXDB_TOKEN}" \
  -H "Content-Type: text/plain" \
  --data-binary @-
