#!/bin/sh
# push_chrony_clients.sh — Collect chrony client metrics and push to InfluxDB
# Deployed as a cron job at /etc/cron.d/chrony-clients running every minute.
# Calls chrony_clients.sh to generate InfluxDB line protocol, then POSTs
# directly to InfluxDB via curl — bypassing Telegraf entirely since chronyc
# is not available inside the Telegraf container.
#
# Cron entry:
#   * * * * * root /opt/docker/stacks/telegraf-ntp/push_chrony_clients.sh

INFLUXDB_URL="http://192.168.1.248:8086"
INFLUXDB_TOKEN="changeme-replace-with-your-token"
INFLUXDB_ORG="homelab"
INFLUXDB_BUCKET="ntp"

/opt/docker/stacks/telegraf-ntp/chrony_clients.sh | curl -s -X POST \
  "${INFLUXDB_URL}/api/v2/write?bucket=${INFLUXDB_BUCKET}&org=${INFLUXDB_ORG}" \
  -H "Authorization: Token ${INFLUXDB_TOKEN}" \
  -H "Content-Type: text/plain" \
  --data-binary @-
