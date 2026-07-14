#!/bin/sh
# push_chrony_clients.sh — Collect chrony client metrics and push to InfluxDB
# Deployed as a cron job at /etc/cron.d/chrony-clients running every minute.
# Calls chrony_clients.sh to generate InfluxDB line protocol, then POSTs
# directly to InfluxDB via curl — bypassing Telegraf entirely since chronyc
# is not available inside the Telegraf container.
#
# Cron entry:
#   * * * * * root /opt/docker/stacks/telegraf-ntp/push_chrony_clients.sh
#
# Requires /opt/docker/stacks/telegraf-ntp/.env to provide INFLUXDB_TOKEN.
# See .env.example in the repo for the expected format.

SCRIPT_DIR="/opt/docker/stacks/telegraf-ntp"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "$(date): Error: missing ${ENV_FILE} — copy .env.example and set INFLUXDB_TOKEN" >&2
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

"${SCRIPT_DIR}/chrony_clients.sh" | curl -s -X POST \
  "${INFLUXDB_URL}/api/v2/write?bucket=${INFLUXDB_BUCKET}&org=${INFLUXDB_ORG}" \
  -H "Authorization: Token ${INFLUXDB_TOKEN}" \
  -H "Content-Type: text/plain" \
  --data-binary @-
