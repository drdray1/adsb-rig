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

HTTP_PORT="${HTTP_PORT:-8080}"
GAIN="${GAIN:-auto}"
INTERVAL="${INTERVAL:-3600}"
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

# Never assume the SBS-1 port. wiedehopf's Linux packaging shifts the whole
# 300xx range down to 200xx, so 20003 is normal on a Pi and 30003 is not.
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

if [ ! -f "$RIG_DIR/aircraft.csv.gz" ]; then
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

## ---------------------------------------------------------------- render units

mkdir -p "$LOG_DIR" "$CONFIG_DIR"

render() {  # $1=template $2=dest
  sed -e "s|__HOME__|$HOME|g" \
      -e "s|__READSB__|$READSB_BIN|g" \
      -e "s|__PYTHON__|$PYTHON_BIN|g" \
      -e "s|__SBS_PORT__|$SBS_PORT|g" \
      -e "s|__HTTP_PORT__|$HTTP_PORT|g" \
      -e "s|__INTERVAL__|$INTERVAL|g" \
      -e "s|__GAIN__|$GAIN|g" \
      "$1" > "$2"
}

cat > "$CONFIG_DIR/env" <<EOF
# Written by install.sh — read by adsb-ctl.
SBS_PORT=$SBS_PORT
HTTP_PORT=$HTTP_PORT
LOG_DIR=$LOG_DIR
PREFIX=$PREFIX
FEEDER_INSTANCE=localhost:$SBS_PORT
EOF

if [ "$PLATFORM" = macos ]; then
  AGENTS="$HOME/Library/LaunchAgents"
  mkdir -p "$AGENTS"
  say "Installing launchd agents"
  for svc in readsb web; do
    render "$RIG_DIR/launchd/$PREFIX.$svc.plist.template" "$AGENTS/$PREFIX.$svc.plist"
    plutil -lint "$AGENTS/$PREFIX.$svc.plist" >/dev/null
    echo "  $PREFIX.$svc.plist"
  done
  if [ "$WANT_FEEDER" = yes ]; then
    render "$RIG_DIR/launchd/$PREFIX.muninn.plist.template" "$AGENTS/$PREFIX.muninn.plist"
    plutil -lint "$AGENTS/$PREFIX.muninn.plist" >/dev/null
    echo "  $PREFIX.muninn.plist"
  fi
else
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

cat <<EOF

 Then start everything:

   $RIG_DIR/adsb-ctl start
   $RIG_DIR/adsb-ctl status

 Map: http://localhost:$HTTP_PORT
EOF
