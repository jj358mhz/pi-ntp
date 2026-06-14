#!/usr/bin/env python3
"""
gps_satellites.py — Parse gpsd SKY JSON into InfluxDB line protocol.

Reads one SKY message from gpspipe, emits two measurements:
  gps_sky        — summary (nSat, uSat, hdop, gdop, tdop, pdop)
  gps_satellites — per-satellite (ss, el, az, used, health)

Called by push_gps_satellites.sh.

Usage:
    gpspipe -w -n 15 | grep '"class":"SKY"' | tail -1 | python3 gps_satellites.py <host> <timestamp_ns>
"""

import sys
import json

def main():
    if len(sys.argv) < 3:
        print("Usage: gps_satellites.py <host> <timestamp_ns>", file=sys.stderr)
        sys.exit(1)

    host = sys.argv[1]
    ts   = sys.argv[2]

    line = sys.stdin.read().strip()
    if not line:
        print("Error: no input", file=sys.stderr)
        sys.exit(1)

    try:
        data = json.loads(line)
    except json.JSONDecodeError as e:
        print(f"Error parsing JSON: {e}", file=sys.stderr)
        sys.exit(1)

    # Summary
    nSat = data.get('nSat', 0)
    uSat = data.get('uSat', 0)
    hdop = data.get('hdop', 0.0)
    gdop = data.get('gdop', 0.0)
    tdop = data.get('tdop', 0.0)
    pdop = data.get('pdop', 0.0)

    print(f"gps_sky,host={host} nSat={nSat}i,uSat={uSat}i,hdop={hdop},gdop={gdop},tdop={tdop},pdop={pdop} {ts}")

    # Per-satellite
    names = {0: 'GPS', 1: 'SBAS', 2: 'Galileo', 3: 'BeiDou', 5: 'QZSS', 6: 'GLONASS'}
    for sat in data.get('satellites', []):
        prn           = sat.get('PRN', 0)
        gnssid        = sat.get('gnssid', 0)
        ss            = sat.get('ss', 0.0)
        el            = sat.get('el', 0.0)
        az            = sat.get('az', 0.0)
        used          = 1 if sat.get('used', False) else 0
        health        = sat.get('health', 0)
        constellation = names.get(gnssid, 'Unknown')

        # Skip satellites with no signal and not used
        if ss <= 0 and not used:
            continue

        print(f"gps_satellites,host={host},prn={prn},constellation={constellation} "
              f"ss={ss},el={el},az={az},used={used}i,health={health}i {ts}")


if __name__ == '__main__':
    main()
