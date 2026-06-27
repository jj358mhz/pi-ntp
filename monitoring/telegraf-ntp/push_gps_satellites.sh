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
# Requires /opt/docker/stacks/telegraf-ntp/.env to provide INFLUXDB_TOKEN.
# See .env.example in the repo for the expected format.
#
# Measurements:
#   gps_sky        — nSat, uSat, hdop, gdop, tdop, pdop
#   gps_satellites — per-satellite: ss, el, az, used, health
#   gps_tpv        — mode (0/1=no fix, 2=2D, 3=3D), ept, epx, epy, epv

SCRIPT_DIR="/opt/docker/stacks/telegraf-ntp"
ENV_FILE="${SCRIPT_DIR}/.env"
HOST="raspberrypi-ntp"

if [ ! -f "$ENV_FILE" ]; then
    echo "$(date): Error: missing ${ENV_FILE} -- copy .env.example and set INFLUXDB_TOKEN" >&2
    exit 1
fi

# shellcheck disable=SC1090
. "$ENV_FILE"

if [ -z "$INFLUXDB_TOKEN" ] || [ "$INFLUXDB_TOKEN" = "changeme-must-match-monitoring-stack-token" ]; then
    echo "$(date): Error: INFLUXDB_TOKEN not set in ${ENV_FILE}" >&2
    exit 1
fi

INFLUXDB_URL="http://192.168.1.248:8086"
INFLUXDB_ORG="homelab"
INFLUXDB_BUCKET="ntp"

TIMESTAMP=$(date +%s)000000000

# Single gpspipe read -- grab enough lines to see both SKY and TPV go by.
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