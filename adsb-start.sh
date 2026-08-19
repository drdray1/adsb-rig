#!/usr/bin/env bash
set -euo pipefail

ADSB_DIR="$HOME/adsb"
HTML="$ADSB_DIR/tar1090/html"
PORT=8080

# Receiver location — optional, but centers the map and enables range rings.
LAT=""   # e.g. 43.6150
LON=""   # e.g. -116.2023

GAIN="auto"   # or a fixed value: 49.6 48.0 44.5 43.4 40.2 36.4 32.8

# The dongle can only be claimed by one process.
if pgrep -f "MacOS/sdrpp" >/dev/null; then
  echo "SDR++ is running and holds the dongle. Quit it first." >&2
  exit 1
fi

# The launchd agents own the dongle whenever they're loaded — running this too
# would have two readsb processes fighting over one device.
if launchctl print "gui/$(id -u)/com.drdray1.adsb.readsb" >/dev/null 2>&1; then
  echo "The always-on agents are loaded; they already run readsb and the map." >&2
  echo "Use 'adsb-ctl status', or 'adsb-ctl stop' first if you want a manual run." >&2
  exit 1
fi

mkdir -p "$HTML/data"

LOC=()
[[ -n "$LAT" && -n "$LON" ]] && LOC=(--lat "$LAT" --lon "$LON")

# Drop --quiet to see every decoded message in the terminal.
# ${LOC[@]+"${LOC[@]}"} not "${LOC[@]}" — macOS ships bash 3.2, which errors on
# expanding an empty array under `set -u`.
# --net + --net-sbs-port serve the SBS-1/BaseStation stream that adsb-capture.sh
# logs for WDGWars uploads. --net-sbs-port defaults to 0 (off), so both are needed.
readsb --device-type rtlsdr --gain "$GAIN" ${LOC[@]+"${LOC[@]}"} \
       --write-json "$HTML/data" --write-json-every 1 \
       --db-file "$ADSB_DIR/aircraft.csv.gz" \
       --net --net-sbs-port 30003 --quiet &
READSB_PID=$!

python3 -m http.server "$PORT" --directory "$HTML" >/dev/null 2>&1 &
HTTP_PID=$!

trap 'kill $READSB_PID $HTTP_PID 2>/dev/null || true' EXIT INT TERM

sleep 2
open "http://localhost:$PORT"
echo "Tracking on http://localhost:$PORT — Ctrl-C to stop."
wait $READSB_PID
