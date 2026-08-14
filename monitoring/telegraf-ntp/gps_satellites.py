#!/usr/bin/env python3
"""
gps_satellites.py — Parse gpsd SKY and TPV JSON into InfluxDB line protocol.

Reads one SKY message and one TPV message from gpspipe, emits up to three
measurements:
  gps_sky        — satellite/DOP summary (nSat, uSat, hdop, gdop, tdop, pdop)
  gps_satellites — per-satellite (ss, el, az, used, health)
  gps_tpv        — fix mode and time/position error estimates (mode, ept, epx, epy, epv)

Called by push_gps_satellites.sh.

Usage:
    gps_satellites.py <host> <timestamp_ns> --sky <sky_json_line> --tpv <tpv_json_line>

Or, simpler — read both from stdin separated by a newline, in either order,
auto-detecting class from each line. This is how push_gps_satellites.sh calls it:

    printf '%s\n%s\n' "$SKY" "$TPV" | python3 gps_satellites.py <host> <timestamp_ns>
"""

import sys
import json


def parse_sky(data, host, ts):
    """Emit gps_sky summary and gps_satellites per-satellite lines."""
    nSat = data.get('nSat', 0)
    uSat = data.get('uSat', 0)
    hdop = data.get('hdop', 0.0)
    gdop = data.get('gdop', 0.0)
    tdop = data.get('tdop', 0.0)
    pdop = data.get('pdop', 0.0)

    print(f"gps_sky,host={host} nSat={nSat}i,uSat={uSat}i,hdop={hdop},gdop={gdop},tdop={tdop},pdop={pdop} {ts}")

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

        print(f"gps_satellites,host={host},prn={prn},constellation={constellation},used={used} "
              f"ss={ss},el={el},az={az},health={health}i {ts}")


def parse_tpv(data, host, ts):
    """Emit gps_tpv: fix mode (0/1=no fix, 2=2D, 3=3D), position, and error estimates."""
    mode = data.get('mode', 0)
    ept  = data.get('ept', 0.0)    # estimated timestamp error (seconds) — closest analog to cgps "Time offset"
    epx  = data.get('epx', 0.0)    # longitude error estimate, meters
    epy  = data.get('epy', 0.0)    # latitude error estimate, meters
    epv  = data.get('epv', 0.0)    # vertical error estimate, meters
    lat  = data.get('lat', 0.0)    # latitude, decimal degrees
    lon  = data.get('lon', 0.0)    # longitude, decimal degrees
    alt  = data.get('altMSL', 0.0) # altitude above mean sea level, meters
    eph = data.get('eph', 0.0)   # estimated horizontal position error, meters
    sep = data.get('sep', 0.0)   # estimated spherical (3D) position error, meters
    print(f"gps_tpv,host={host} mode={mode}i,ept={ept},epx={epx},epy={epy},epv={epv},lat={lat},lon={lon},alt={alt},eph={eph},sep={sep} {ts}")


def main():
    if len(sys.argv) < 3:
        print("Usage: gps_satellites.py <host> <timestamp_ns>", file=sys.stderr)
        sys.exit(1)

    host = sys.argv[1]
    ts   = sys.argv[2]

    raw = sys.stdin.read().strip()
    if not raw:
        print("Error: no input", file=sys.stderr)
        sys.exit(1)

    emitted_any = False

    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue

        try:
            data = json.loads(line)
        except json.JSONDecodeError as e:
            print(f"Warning: skipping unparseable line: {e}", file=sys.stderr)
            continue

        msg_class = data.get('class')

        if msg_class == 'SKY':
            try:
                parse_sky(data, host, ts)
                emitted_any = True
            except Exception as e:
                print(f"Warning: failed to parse SKY message: {e}", file=sys.stderr)

        elif msg_class == 'TPV':
            try:
                parse_tpv(data, host, ts)
                emitted_any = True
            except Exception as e:
                print(f"Warning: failed to parse TPV message: {e}", file=sys.stderr)

        # Silently ignore other classes (VERSION, DEVICES, etc.)

    if not emitted_any:
        print("Error: no SKY or TPV messages found in input", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
