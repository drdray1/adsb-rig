#!/usr/bin/env bash
# adsb-watchdog.sh — restart readsb when it is running but no longer decoding.
#
# Why this exists:
#
#   launchd's KeepAlive (and systemd's Restart=) only react to a process that
#   *exits*. After a laptop sleep the USB bulk transfer from the dongle can come
#   back broken: readsb stays alive and busy, but the sample stream is garbage.
#   Observed in the wild as:
#
#       Lost 4 packets (-224355.0 us) on USB, MLAT could be UNSTABLE (ppm: -7571)
#       SDR ppm out of specification ... or local clock jumped!  ppm: 1250
#
#   ...with 0 aircraft tracked for hours. Nothing in the service manager can see
#   "running but useless", so the check has to look at readsb's own output.
#
# What it checks — deliberately NOT the aircraft count:
#
#   stats.json -> last1min.local.samples_processed counts samples pulled off the
#   USB stream. It keeps incrementing even when no aircraft are in range, so it
#   separates "3am, empty sky" (fine) from "stream is dead" (not fine). An
#   aircraft- or message-count check would restart the radio every quiet night.
#
# Run by com.drdray1.adsb.watchdog every CHECK_INTERVAL seconds. Safe to run by
# hand; --dry-run reports without touching anything.
set -euo pipefail

CONFIG="${ADSB_RIG_CONFIG:-$HOME/.config/adsb-rig/env}"
# shellcheck source=/dev/null
[ -f "$CONFIG" ] && . "$CONFIG"

RIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-com.drdray1.adsb}"
LOG_DIR="${LOG_DIR:-$RIG_DIR/logs}"
STATE_DIR="${STATE_DIR:-$HOME/.config/adsb-rig}"
STATE_FILE="$STATE_DIR/watchdog.state"

# Where readsb writes its json. wiedehopf's Linux packages use /run/readsb.
if [ -n "${DATA_DIR:-}" ]; then
  :
elif [ -d "$RIG_DIR/tar1090/html/data" ]; then
  DATA_DIR="$RIG_DIR/tar1090/html/data"
elif [ -d /run/readsb ]; then
  DATA_DIR=/run/readsb
else
  DATA_DIR="$RIG_DIR/tar1090/html/data"
fi

# Don't judge a radio that only just started: last1min is empty until it fills.
GRACE_SECONDS="${GRACE_SECONDS:-180}"
# stats.json is rewritten every write-json-every (1s). Older than this = wedged.
STALE_SECONDS="${STALE_SECONDS:-120}"
# Never restart more often than this. Stops a boot loop when the dongle is
# simply unplugged -- KeepAlive already handles that case correctly.
MIN_RESTART_INTERVAL="${MIN_RESTART_INTERVAL:-600}"

DRY_RUN=""
[ "${1:-}" = "--dry-run" ] && DRY_RUN=yes

mkdir -p "$LOG_DIR" "$STATE_DIR"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

now_epoch() { date +%s; }

if [ "$(uname -s)" = "Darwin" ]; then
  PLATFORM=macos
else
  PLATFORM=linux
fi

## ------------------------------------------------------------------ is it ours

# If the service isn't loaded, the user ran `adsb-ctl stop` (to free the dongle
# for SDR++, say). Resurrecting it would be hostile. Do nothing.
service_loaded() {
  if [ "$PLATFORM" = macos ]; then
    launchctl print "gui/$(id -u)/$PREFIX.readsb" >/dev/null 2>&1
  else
    systemctl is-active --quiet readsb 2>/dev/null
  fi
}

if ! service_loaded; then
  exit 0
fi

## -------------------------------------------------------------------- inspect

# Emits: "<uptime> <samples_processed> <ppm> <dropped> <lost>", or nothing on
# unreadable/partial json (readsb rewrites these files every second, so a torn
# read is possible and must not be treated as a failure).
read_health() {
  python3 - "$DATA_DIR" <<'PYEOF' 2>/dev/null || true
import json, os, sys
d = sys.argv[1]
try:
    with open(os.path.join(d, 'stats.json')) as fh:
        stats = json.load(fh)
    with open(os.path.join(d, 'status.json')) as fh:
        status = json.load(fh)
except Exception:
    sys.exit(1)
local = stats.get('last1min', {}).get('local', {}) or {}
print('%s %s %s %s %s' % (
    status.get('uptime', 0),
    local.get('samples_processed', -1),
    stats.get('estimated_ppm', 0),
    local.get('samples_dropped', 0),
    local.get('samples_lost', 0),
))
PYEOF
}

STATS="$DATA_DIR/stats.json"

if [ ! -f "$STATS" ]; then
  log "unhealthy: $STATS does not exist"
  UNHEALTHY="no stats.json"
else
  # BSD stat and GNU stat disagree on flags; try both.
  MTIME=$(stat -f %m "$STATS" 2>/dev/null || stat -c %Y "$STATS" 2>/dev/null || echo 0)
  AGE=$(( $(now_epoch) - MTIME ))

  HEALTH="$(read_health)"
  if [ -z "$HEALTH" ]; then
    # Torn read of a file rewritten every second. Not evidence of failure.
    exit 0
  fi

  set -- $HEALTH
  UPTIME="${1%%.*}"; SAMPLES="$2"; PPM="$3"; DROPPED="$4"; LOST="$5"

  UNHEALTHY=""
  if [ "${UPTIME:-0}" -lt "$GRACE_SECONDS" ]; then
    exit 0                      # still warming up
  elif [ "$AGE" -gt "$STALE_SECONDS" ]; then
    UNHEALTHY="stats.json is ${AGE}s stale (readsb has stopped writing)"
  elif [ "$SAMPLES" = "0" ]; then
    UNHEALTHY="0 samples processed in the last minute (USB stream is dead)"
  elif [ "$SAMPLES" = "-1" ]; then
    exit 0                      # field absent; nothing to judge
  fi
fi

if [ -z "${UNHEALTHY:-}" ]; then
  exit 0
fi

## -------------------------------------------------------------------- back off

LAST_RESTART=0
[ -f "$STATE_FILE" ] && LAST_RESTART=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
case "$LAST_RESTART" in *[!0-9]*|'') LAST_RESTART=0 ;; esac

SINCE=$(( $(now_epoch) - LAST_RESTART ))
if [ "$SINCE" -lt "$MIN_RESTART_INTERVAL" ]; then
  log "unhealthy ($UNHEALTHY) but last restart was ${SINCE}s ago; backing off"
  exit 0
fi

## -------------------------------------------------------------------- act

log "unhealthy: $UNHEALTHY"
log "  ppm=${PPM:-?} samples_dropped=${DROPPED:-?} samples_lost=${LOST:-?}"

if [ -n "$DRY_RUN" ]; then
  log "  --dry-run: would restart readsb"
  exit 0
fi

if [ "$PLATFORM" = macos ]; then
  # kickstart -k kills and relaunches in one step, leaving launchd's own
  # bookkeeping intact -- unlike bootout/bootstrap, which can race.
  launchctl kickstart -k "gui/$(id -u)/$PREFIX.readsb"
else
  # Untested on real hardware; readsb on Linux is a system service owned by
  # wiedehopf's installer, so this needs privileges the watchdog may not have.
  systemctl restart readsb 2>/dev/null || sudo -n systemctl restart readsb 2>/dev/null || {
    log "  cannot restart readsb (needs privileges); leaving it alone"
    exit 0
  }
fi

now_epoch > "$STATE_FILE"
log "  restarted readsb"
