#!/usr/bin/env bash
# uninstall.sh — remove the services. Leaves your data alone.
#
# Does NOT delete: captures/, logs/, the aircraft database, or your API key at
# ~/.config/muninn/api.key. Remove those by hand if you actually want them gone.
set -euo pipefail

RIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="com.drdray1.adsb"
CONFIG="$HOME/.config/adsb-rig/env"
# shellcheck source=/dev/null
[ -f "$CONFIG" ] && . "$CONFIG"
FEEDER_INSTANCE="${FEEDER_INSTANCE:-localhost:30003}"

case "$(uname -s)" in
  Darwin)
    DOMAIN="gui/$(id -u)"
    AGENTS="$HOME/Library/LaunchAgents"
    for svc in readsb web muninn watchdog; do
      launchctl bootout "$DOMAIN/$PREFIX.$svc" 2>/dev/null && echo "  stopped  $svc" || true
      if [ -f "$AGENTS/$PREFIX.$svc.plist" ]; then
        rm -f "$AGENTS/$PREFIX.$svc.plist"
        echo "  removed  $PREFIX.$svc.plist"
      fi
    done
    ;;
  Linux)
    UNIT="adsb-feeder@${FEEDER_INSTANCE}.service"
    systemctl --user disable --now "$UNIT" 2>/dev/null && echo "  disabled $UNIT" || true
    rm -f "$HOME/.config/systemd/user/adsb-feeder@.service"
    systemctl --user daemon-reload 2>/dev/null || true
    echo "  removed  adsb-feeder@.service"
    echo
    echo "  readsb and tar1090 were installed by their own installers — this"
    echo "  script does not touch them."
    ;;
  *) echo "unsupported platform" >&2; exit 2 ;;
esac

cat <<EOF

 Services removed. Left in place on purpose:
   $RIG_DIR/captures/   captured observations
   $RIG_DIR/logs/       logs
   $RIG_DIR/muninn/     feeder checkout and venv
   $RIG_DIR/tar1090/    map assets
   ~/.config/muninn/api.key   your API key

 Revoke the key at wdgwars.pl/profile if you're done with it.
EOF
