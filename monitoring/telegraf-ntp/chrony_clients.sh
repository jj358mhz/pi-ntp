#!/bin/sh
# chrony_clients.sh — Parse chronyc clients output into InfluxDB line protocol.
# Called by Telegraf exec input plugin every 60 seconds.
# Runs inside the Telegraf container as root — no sudo needed.
# chronyc is accessible via network_mode: host on udp://127.0.0.1:323

TIMESTAMP=$(date +%s)000000000
HOST="raspberrypi-ntp"

/usr/bin/chronyc -n clients | awk -v ts="$TIMESTAMP" -v host="$HOST" '
/^=+$/ { in_data=1; next }
!in_data { next }
NF < 7 { next }

# Skip localhost command-only line
$1 == "127.0.0.1" && $2 == "0" { next }

{
    client = $1
    ntp_requests = $2
    ntp_drops = $3
    ntp_poll = $4
    last_rx_raw = $6
    cmd_requests = $7
    cmd_drops = $8

    # Convert poll to integer (-1 if -)
    if (ntp_poll == "-") ntp_poll = -1

    # Convert last_rx to seconds (-1 if -)
    last_rx = -1
    if (last_rx_raw != "-") {
        n = length(last_rx_raw)
        suffix = substr(last_rx_raw, n, 1)
        val = substr(last_rx_raw, 1, n-1)
        if (suffix == "m") last_rx = int(val * 60)
        else if (suffix == "h") last_rx = int(val * 3600)
        else if (suffix == "d") last_rx = int(val * 86400)
        else last_rx = int(last_rx_raw)
    }

    printf "chrony_clients,host=%s,client=%s ntp_requests=%di,ntp_drops=%di,ntp_poll=%di,cmd_requests=%di,cmd_drops=%di,last_rx=%di %s\n",
        host, client, ntp_requests, ntp_drops, ntp_poll, cmd_requests, cmd_drops, last_rx, ts
}
'
