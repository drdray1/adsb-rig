#!/usr/bin/env bash
# install.sh — set up the local ADS-B station.
#
#   ./install.sh                 interactive
#   ./install.sh --with-feeder   install the optional WDGWars feeder too
#   ./install.sh --no-feeder     decoder + map only
#
# Never takes an API key as an argument — that would put it in shell history.
# It prints the --save-key command for you to run instead.
#
# bash 3.2 compatible (macOS ships 2007-era bash).
set -euo pipefail

RIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.config/adsb-rig"
LOG_DIR="$RIG_DIR/logs"
PREFIX="com.drdray1.adsb"

# Local, gitignored settings: receiver position and tuning. Sourced before the
# defaults below so a value set here becomes the default; the file uses the
# ${VAR:=} form so a real environment variable still overrides it.
if [ -f "$RIG_DIR/station.conf" ]; then
  # shellcheck source=/dev/null
  . "$RIG_DIR/station.conf"
fi

HTTP_PORT="${HTTP_PORT:-8080}"
BEAST_PORT="${BEAST_PORT:-30005}"
GAIN="${GAIN:-auto}"
INTERVAL="${INTERVAL:-3600}"
CHECK_INTERVAL="${CHECK_INTERVAL:-300}"
SBS_PORT=""
WANT_FEEDER=""

MUNINN_REPO="https://github.com/Yggdrasil-AI-labs/adsb-to-wdgwars"
TAR1090_REPO="https://github.com/wiedehopf/tar1090"
DB_URL="https://github.com/wiedehopf/tar1090-db/raw/csv/aircraft.csv.gz"

while [ $# -gt 0 ]; do
  case "$1" in
    --with-feeder) WANT_FEEDER=yes ;;
    --no-feeder)   WANT_FEEDER=no ;;
    -h|--help)     sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '    warning: %s\n' "$*" >&2; }
die()  { printf '\n error: %s\n' "$*" >&2; exit 1; }

case "$(uname -s)" in
  Darwin) PLATFORM=macos ;;
  Linux)  PLATFORM=linux ;;
  *) die "unsupported platform: $(uname -s)" ;;
esac

need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

say "Platform: $PLATFORM"
need git
need python3
need curl

PYTHON_BIN="$(command -v python3)"
py_ok=$(python3 -c 'import sys; print(1 if sys.version_info>=(3,10) else 0)')
[ "$py_ok" = "1" ] || die "Python 3.10+ required (found $(python3 -V))"

## ---------------------------------------------------------------- decoder

READSB_BIN=""
if [ "$PLATFORM" = macos ]; then
  if ! command -v readsb >/dev/null 2>&1; then
    say "Installing readsb via Homebrew"
    command -v brew >/dev/null 2>&1 || die "Homebrew required: https://brew.sh"
    brew install readsb
  fi
  READSB_BIN="$(command -v readsb)"
  SBS_PORT="${SBS_PORT:-30003}"
  [ -n "$SBS_PORT" ] || SBS_PORT=30003
else
  # On Linux, readsb is installed and managed by its own upstream installer.
  # We detect and integrate rather than fighting its systemd unit.
  if ! command -v readsb >/dev/null 2>&1 && ! systemctl list-unit-files 2>/dev/null | grep -q '^readsb'; then
    cat >&2 <<EOF

 readsb is not installed. This project does not reimplement its installer —
 use the standard one, then re-run this script:

   sudo bash -c "\$(wget -qO - https://raw.githubusercontent.com/wiedehopf/adsb-scripts/master/readsb-install.sh)"

 Optional map (recommended on Pi):

   sudo bash -c "\$(wget -qO - https://raw.githubusercontent.com/wiedehopf/tar1090/master/install.sh)"

EOF
    exit 1
  fi
  READSB_BIN="$(command -v readsb || echo /usr/bin/readsb)"
fi

# Never assume the SBS-1 port. A stock wiedehopf install uses 30003 (verified on
# a Pi 4 / Debian 13); it only shifts to 20003 when installed with the
# `push-30004` argument, which lets readsb coexist with an existing dump1090-fa.
# Read the config first, probe second.
detect_sbs_port() {
  local p
  if [ -f /etc/default/readsb ]; then
    p=$(grep -oE -- '--net-sbs-port[ =][0-9]+' /etc/default/readsb 2>/dev/null \
        | grep -oE '[0-9]+' | head -1 || true)
    if [ -n "${p:-}" ]; then echo "$p"; return; fi
  fi
  for p in 30003 20003; do
    if nc -z localhost "$p" >/dev/null 2>&1; then echo "$p"; return; fi
  done
  echo 30003
}

if [ "$PLATFORM" = linux ]; then
  SBS_PORT="$(detect_sbs_port)"
  say "Detected SBS-1 port: $SBS_PORT"
  nc -z localhost "$SBS_PORT" >/dev/null 2>&1 \
    || warn "nothing listening on $SBS_PORT yet — enable --net-sbs-port in /etc/default/readsb"
fi

## ---------------------------------------------------------------- map assets

if [ "$PLATFORM" = macos ] || [ ! -d /usr/local/share/tar1090 ]; then
  if [ ! -d "$RIG_DIR/tar1090" ]; then
    say "Fetching tar1090 web assets"
    git clone --depth 1 "$TAR1090_REPO" "$RIG_DIR/tar1090"
  fi
  mkdir -p "$RIG_DIR/tar1090/html/data"
fi

# Only needed for the readsb instance this repo launches (macOS). On Linux
# readsb is a system service that already has its own database from wiedehopf's
# installer -- downloading 8 MB here would be dead weight.
if [ "$PLATFORM" = macos ] && [ ! -f "$RIG_DIR/aircraft.csv.gz" ]; then
  say "Fetching aircraft database (hex -> registration/type)"
  curl -L --fail -o "$RIG_DIR/aircraft.csv.gz" "$DB_URL"
fi

## ---------------------------------------------------------------- feeder

if [ -z "$WANT_FEEDER" ]; then
  printf '\nInstall the optional WDGWars feeder? It uploads aircraft to your\n'
  printf 'WDGWars account and needs an API key. The decoder and map work without it.\n'
  printf 'Install feeder? [y/N]: '
  read -r reply < /dev/tty || reply=n
  case "$reply" in [Yy]*) WANT_FEEDER=yes ;; *) WANT_FEEDER=no ;; esac
fi

if [ "$WANT_FEEDER" = yes ]; then
  if [ ! -d "$RIG_DIR/muninn" ]; then
    say "Installing Muninn (ADS-B -> WDGWars feeder)"
    git clone --depth 1 "$MUNINN_REPO" "$RIG_DIR/muninn"
  fi
  [ -d "$RIG_DIR/muninn/.venv" ] || python3 -m venv "$RIG_DIR/muninn/.venv"
  "$RIG_DIR/muninn/.venv/bin/pip" install -q -r "$RIG_DIR/muninn/requirements.txt"
fi

## ---------------------------------------------------------------- extra feeds

mkdir -p "$LOG_DIR" "$CONFIG_DIR"

# A UUID identifies this receiver to aggregators using beast_reduce_plus_out.
# Generated once and reused, so your feeder identity is stable across installs.
UUID_FILE="$CONFIG_DIR/uuid"
if [ ! -f "$UUID_FILE" ]; then
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid > "$UUID_FILE"
  else
    python3 -c 'import uuid;print(uuid.uuid4())' > "$UUID_FILE"
  fi
  chmod 600 "$UUID_FILE"
fi
UUID="$(cat "$UUID_FILE")"

# Build the <string> entries for readsb's --net-connector args, one pair per
# active feeds.conf line. Written to a temp file that sed splices into the plist.
CONNECTOR_XML="$(mktemp)"
# Plain-argument form of the same thing. macOS splices the XML above into a
# plist; Linux has no plist -- readsb there is wiedehopf's system service reading
# /etc/default/readsb -- so it needs the args as a flat string.
RIG_NET_ARGS=""
RIG_DEC_ARGS=""
FEED_COUNT=0
if [ -f "$RIG_DIR/feeds.conf" ]; then
  while read -r host port proto rest; do
    case "${host:-}" in ''|\#*) continue ;; esac
    [ -z "${port:-}" ] && continue
    [ -z "${proto:-}" ] && proto=beast_reduce_plus_out
    {
      printf '\t\t<string>--net-connector</string>\n'
      printf '\t\t<string>%s,%s,%s</string>\n' "$host" "$port" "$proto"
    } >> "$CONNECTOR_XML"
    RIG_NET_ARGS="$RIG_NET_ARGS --net-connector $host,$port,$proto"
    FEED_COUNT=$((FEED_COUNT + 1))
    echo "  feeding $host:$port ($proto)"
  done < "$RIG_DIR/feeds.conf"
fi

if [ "$FEED_COUNT" -gt 0 ]; then
  say "Extra feeds: $FEED_COUNT"
  {
    printf '\t\t<string>--uuid</string>\n'
    printf '\t\t<string>%s</string>\n' "$UUID"
  } >> "$CONNECTOR_XML"
  RIG_NET_ARGS="$RIG_NET_ARGS --uuid $UUID"
elif [ -f "$RIG_DIR/feeds.conf" ]; then
  echo "  feeds.conf has no active entries (all commented out)"
fi

# CPU relief for weak boards. readsb documents this itself: "lower threshold ->
# more CPU usage (default: 58, pi zero / pi 1: 75, hot CPU 42)". readsb has no
# sample-rate knob — this is the one that matters.
# Receiver position. Centres the map and enables range rings. Not sufficient
# for MLAT, which needs the real antenna position to a few metres.
if [ -n "${LAT:-}" ] && [ -n "${LON:-}" ]; then
  {
    printf '\t\t<string>--lat</string>\n'
    printf '\t\t<string>%s</string>\n' "$LAT"
    printf '\t\t<string>--lon</string>\n'
    printf '\t\t<string>%s</string>\n' "$LON"
  } >> "$CONNECTOR_XML"
  if [ "$PLATFORM" = linux ]; then
    # readsb-set-location writes --lat/--lon into DECODER_OPTIONS itself. Two
    # tools editing the same setting would fight, so defer rather than duplicate.
    echo "  receiver position: on Linux this is owned by readsb-set-location, not"
    echo "    station.conf. Apply it with:  sudo readsb-set-location $LAT $LON"
  else
    echo "  receiver position $LAT, $LON"
  fi
elif [ -n "${LAT:-}${LON:-}" ]; then
  warn "LAT and LON must both be set; ignoring the one that is."
fi

if [ -n "${PREAMBLE:-}" ]; then
  {
    printf '\t\t<string>--preamble-threshold</string>\n'
    printf '\t\t<string>%s</string>\n' "$PREAMBLE"
  } >> "$CONNECTOR_XML"
  RIG_DEC_ARGS="$RIG_DEC_ARGS --preamble-threshold $PREAMBLE"
  echo "  preamble-threshold $PREAMBLE"
fi

## ------------------------------------------------- apply args on Linux

# On Linux readsb is wiedehopf's system service, configured by shell-style
# variables in /etc/default/readsb. systemd's EnvironmentFile does NOT expand
# variables, so `NET_OPTIONS="$NET_OPTIONS --net-connector ..."` would be passed
# through literally and break readsb. The line has to be rewritten in full.
#
# A snapshot of the original value is kept under /var/lib/adsb-rig so repeated
# runs rebuild from the original rather than compounding duplicates.
apply_readsb_var() {  # $1=VARNAME  $2=args to append
  local var="$1" extra="$2"
  [ -z "$extra" ] && return 0
  if ! sudo -n true 2>/dev/null; then
    warn "need sudo to write /etc/default/readsb; skipping: $var$extra"
    return 0
  fi
  sudo python3 - "$var" "$extra" <<'PYEOF'
import os, shutil, sys
var, extra = sys.argv[1], sys.argv[2].strip()
conf = '/etc/default/readsb'
base_dir = '/var/lib/adsb-rig'
os.makedirs(base_dir, exist_ok=True)
base_path = os.path.join(base_dir, var + '.base')

with open(conf) as fh:
    lines = fh.readlines()
idx = next((i for i, l in enumerate(lines) if l.startswith(var + '=')), None)
if idx is None:
    print('  %s not present in %s; nothing changed' % (var, conf))
    sys.exit(0)

current = lines[idx].split('=', 1)[1].strip().strip('"')
if os.path.exists(base_path):
    base = open(base_path).read().strip()
else:
    base = current
    with open(base_path, 'w') as fh:
        fh.write(base)

new = (base + ' ' + extra).strip()
if new == current:
    print('  %s already up to date' % var)
    sys.exit(0)

backup = conf + '.adsb-rig.bak'
if not os.path.exists(backup):
    shutil.copy2(conf, backup)
    print('  backed up %s -> %s' % (conf, backup))
lines[idx] = '%s="%s"\n' % (var, new)
with open(conf, 'w') as fh:
    fh.writelines(lines)
print('  %s updated' % var)
PYEOF
}

## ---------------------------------------------------------------- render units

# plutil -lint accepts XML that stricter parsers reject (notably "--" inside an
# XML comment, which is illegal). Validate with a real XML parser too.
validate_plist() {
  plutil -lint "$1" >/dev/null || die "invalid plist: $1"
  python3 - "$1" <<'PYEOF' || die "plist is not well-formed XML: $1"
import plistlib, sys
with open(sys.argv[1], 'rb') as fh:
    plistlib.load(fh)
PYEOF
}

render() {  # $1=template $2=dest
  # `r` splices the connector XML in after the marker line, `d` then deletes the
  # marker itself — sed still emits the read file, so the order is correct.
  sed -e "s|__HOME__|$HOME|g" \
      -e "s|__READSB__|$READSB_BIN|g" \
      -e "s|__PYTHON__|$PYTHON_BIN|g" \
      -e "s|__SBS_PORT__|$SBS_PORT|g" \
      -e "s|__HTTP_PORT__|$HTTP_PORT|g" \
      -e "s|__BEAST_PORT__|$BEAST_PORT|g" \
      -e "s|__INTERVAL__|$INTERVAL|g" \
      -e "s|__CHECK_INTERVAL__|$CHECK_INTERVAL|g" \
      -e "s|__GAIN__|$GAIN|g" \
      -e "/__CONNECTORS__/r $CONNECTOR_XML" \
      -e "/__CONNECTORS__/d" \
      "$1" > "$2"
}

cat > "$CONFIG_DIR/env" <<EOF
# Written by install.sh — read by adsb-ctl.
SBS_PORT=$SBS_PORT
HTTP_PORT=$HTTP_PORT
BEAST_PORT=$BEAST_PORT
LOG_DIR=$LOG_DIR
PREFIX=$PREFIX
FEEDER_INSTANCE=localhost:$SBS_PORT
DATA_DIR=$RIG_DIR/tar1090/html/data
EOF

if [ "$PLATFORM" = macos ]; then
  AGENTS="$HOME/Library/LaunchAgents"
  mkdir -p "$AGENTS"
  say "Installing launchd agents"
  for svc in readsb web watchdog; do
    render "$RIG_DIR/launchd/$PREFIX.$svc.plist.template" "$AGENTS/$PREFIX.$svc.plist"
    validate_plist "$AGENTS/$PREFIX.$svc.plist"
    echo "  $PREFIX.$svc.plist"
  done
  if [ "$WANT_FEEDER" = yes ]; then
    render "$RIG_DIR/launchd/$PREFIX.muninn.plist.template" "$AGENTS/$PREFIX.muninn.plist"
    validate_plist "$AGENTS/$PREFIX.muninn.plist"
    echo "  $PREFIX.muninn.plist"
  fi
else
  # Apply feed connectors / tuning to the system readsb before touching units.
  if [ -n "$RIG_NET_ARGS" ] || [ -n "$RIG_DEC_ARGS" ]; then
    say "Applying readsb options to /etc/default/readsb"
    apply_readsb_var NET_OPTIONS "$RIG_NET_ARGS"
    apply_readsb_var DECODER_OPTIONS "$RIG_DEC_ARGS"
    if sudo -n true 2>/dev/null; then
      sudo systemctl restart readsb && echo "  restarted readsb"
    else
      echo "  run: sudo systemctl restart readsb"
    fi
  fi

  UNIT_DIR="$HOME/.config/systemd/user"
  mkdir -p "$UNIT_DIR"
  if [ "$WANT_FEEDER" = yes ]; then
    say "Installing systemd user unit"
    render "$RIG_DIR/systemd/adsb-feeder@.service.template" "$UNIT_DIR/adsb-feeder@.service"
    systemctl --user daemon-reload
    echo "  adsb-feeder@.service"
    echo
    echo "  Headless Pi? user units need lingering to run without a login:"
    echo "    sudo loginctl enable-linger $USER"
  fi
fi

## ---------------------------------------------------------------- next steps

say "Installed"
if [ "$WANT_FEEDER" = yes ]; then
  cat <<EOF

 One step left — save your WDGWars API key (generate it at
 wdgwars.pl/profile -> API Keys). Run this yourself so the key stays out of
 any script argument or log:

   $RIG_DIR/muninn/.venv/bin/python $RIG_DIR/muninn/muninn.py --save-key 'YOUR_KEY'

 Verify it with:

   $RIG_DIR/muninn/.venv/bin/python $RIG_DIR/muninn/muninn.py --whoami
EOF
fi

if [ "$PLATFORM" = macos ]; then
  MAP_URL="http://localhost:$HTTP_PORT"
else
  # tar1090 via lighttpd, installed by wiedehopf's script -- not by us.
  MAP_URL="http://$(hostname -I 2>/dev/null | awk '{print $1}')/tar1090"
fi

cat <<EOF

 Then start everything:

   $RIG_DIR/adsb-ctl start
   $RIG_DIR/adsb-ctl status

 Map: $MAP_URL
EOF
