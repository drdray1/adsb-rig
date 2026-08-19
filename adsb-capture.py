#!/usr/bin/env python3
"""Log readsb's SBS-1/BaseStation stream to a file for WDGWars upload.

aircraft.json is a live snapshot (only what's overhead right now). This stream
accumulates every aircraft seen for the whole session, so one upload covers it all.

Convert at https://yggdrasil-ai-labs.github.io/adsb-to-wdgwars/ (converts in your
browser), then drag the downloaded JSON into the form on https://wdgwars.pl/profile

Python rather than shell on purpose: nc needs -d or it reads EOF on stdin and closes
immediately, and bash defers trapped signals while waiting on a foreground child, so
Ctrl-C could orphan nc and skip the summary. socket + KeyboardInterrupt is predictable.
"""
import os
import signal
import socket
import subprocess
import sys
import time
from datetime import datetime


def _stop(signum, frame):
    raise KeyboardInterrupt


# Set both explicitly. A shell without job control starts background children with
# SIGINT set to SIG_IGN, which Python inherits — so without this, a backgrounded run
# ignores Ctrl-C entirely. Handling SIGTERM too means `kill` also gets a clean summary.
signal.signal(signal.SIGINT, _stop)
signal.signal(signal.SIGTERM, _stop)

HOST, PORT = "localhost", 30003
OUT_DIR = os.path.expanduser("~/adsb/captures")


def preflight():
    if subprocess.run(["pgrep", "-f", "readsb --device-type"],
                      capture_output=True).returncode != 0:
        sys.exit("readsb isn't running. Start it first:  ~/adsb/adsb-start.sh")
    try:
        socket.create_connection((HOST, PORT), timeout=3).close()
    except OSError:
        sys.exit(f"Nothing listening on port {PORT}.\n"
                 f"readsb needs --net --net-sbs-port {PORT}; "
                 f"restart with ~/adsb/adsb-start.sh")


def main():
    preflight()
    os.makedirs(OUT_DIR, exist_ok=True)
    out = os.path.join(OUT_DIR, f"sbs-{datetime.now():%Y%m%d-%H%M%S}.csv")

    print(f"Capturing to {out}")
    print("Ctrl-C to stop. Longer sessions bank more aircraft.\n")

    icaos, messages, last_draw = set(), 0, 0.0
    sock = socket.create_connection((HOST, PORT))
    sock.settimeout(1.0)

    try:
        with open(out, "a", buffering=1) as fh:
            buf = ""
            while True:
                try:
                    chunk = sock.recv(65536).decode("utf-8", "replace")
                except socket.timeout:
                    chunk = ""
                buf += chunk
                *lines, buf = buf.split("\n")
                for line in lines:
                    if not line.strip():
                        continue
                    fh.write(line + "\n")
                    messages += 1
                    parts = line.split(",")
                    # SBS-1 field 5 (1-indexed) is the ICAO24 hex address.
                    if len(parts) > 4 and parts[4].strip():
                        icaos.add(parts[4].strip().upper())
                now = time.monotonic()
                if now - last_draw >= 2:
                    print(f"\r  {messages} messages, {len(icaos)} aircraft ",
                          end="", flush=True)
                    last_draw = now
    except KeyboardInterrupt:
        pass
    finally:
        sock.close()
        print(f"\r  {messages} messages, {len(icaos)} aircraft ")
        print()
        if messages:
            print(f"Captured {messages} messages from {len(icaos)} distinct aircraft")
        else:
            print("No data captured.")
        print(f"File: {out}")
        print()
        print("Next: convert at https://yggdrasil-ai-labs.github.io/adsb-to-wdgwars/")
        print("      then drag the downloaded JSON into https://wdgwars.pl/profile")


if __name__ == "__main__":
    main()
