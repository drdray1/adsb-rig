#!/usr/bin/env bash
# gain-sweep.sh — find the best tuner gain by measurement instead of guesswork.
#
# Linux only: it works by rewriting RECEIVER_OPTIONS in /etc/default/readsb,
# which is how wiedehopf's system readsb is configured. macOS keeps gain in the
# launchd plist, so this would need a different mechanism there.
#
#   ./gain-sweep.sh                      defaults: 7 gains, 240s each, 2 passes
#   DWELL=300 PASSES=3 ./gain-sweep.sh   longer and more repeats
#   GAINS="49.6 44.5" ./gain-sweep.sh    just these two
#
# WHY PASSES MATTER: air traffic changes minute to minute, and message counts
# follow traffic far more strongly than they follow gain. A single pass measures
# the sky, not the radio. Each pass visits the gains in the opposite order, so a
# rising or falling traffic trend hurts both ends equally instead of flattering
# whichever gain happened to run during the busy stretch.
#
# Run it against real traffic. At 5am with three aircraft up, the result is noise
# with a confident-looking number attached.
set -euo pipefail

CONF=/etc/default/readsb
GAINS="${GAINS:-58 49.6 48.0 44.5 43.4 42.1 40.2}"
DWELL="${DWELL:-240}"      # seconds of measurement per gain
SETTLE="${SETTLE:-30}"     # discarded after each restart (AGC/tracks settling)
PASSES="${PASSES:-2}"
OUT="${OUT:-$HOME/adsb/gain-sweep.csv}"

command -v readsb >/dev/null || { echo "readsb not found" >&2; exit 1; }
[ -f "$CONF" ] || { echo "$CONF not found -- Linux/system readsb only" >&2; exit 1; }
sudo -n true 2>/dev/null || { echo "need passwordless sudo to edit $CONF" >&2; exit 1; }

ORIGINAL=$(grep '^RECEIVER_OPTIONS' "$CONF" | sed -E 's/.*--gain ([^ "]+).*/\1/')
echo "current gain: $ORIGINAL"

restore() {
  echo
  echo "restoring gain to $ORIGINAL"
  set_gain "$ORIGINAL" || true
  sudo systemctl restart readsb || true
}
trap restore EXIT INT TERM

set_gain() {
  sudo python3 - "$CONF" "$1" <<'PYEOF'
import re, sys
conf, gain = sys.argv[1], sys.argv[2]
with open(conf) as fh:
    lines = fh.readlines()
for i, l in enumerate(lines):
    if l.startswith('RECEIVER_OPTIONS='):
        lines[i] = re.sub(r'--gain [^ "]+', '--gain ' + gain, l)
        break
with open(conf, 'w') as fh:
    fh.writelines(lines)
PYEOF
}

# Emits: accepted0 accepted1 valid positions maxdist_nm strong signal noise
snapshot() {
  python3 - <<'PYEOF'
import json
try:
    s = json.load(open('/run/readsb/stats.json'))
except Exception:
    print('0 0 0 0 0 0 0 0'); raise SystemExit
t = s.get('total', {}) or {}
l = t.get('local', {}) or {}
acc = l.get('accepted') or [0, 0]
md = t.get('max_distance') or 0
print('%d %d %d %d %.1f %d %s %s' % (
    acc[0] if len(acc) > 0 else 0,
    acc[1] if len(acc) > 1 else 0,
    t.get('messages_valid', 0) or 0,
    t.get('position_count_total', 0) or 0,
    md / 1852.0,
    l.get('strong_signals', 0) or 0,
    l.get('signal', 0), l.get('noise', 0)))
PYEOF
}

echo "pass,gain,accepted,accepted_1err,valid,positions,max_nm,strong,signal,noise,aircraft" > "$OUT"
echo "writing $OUT"

for pass_no in $(seq 1 "$PASSES"); do
  # Alternate direction each pass so a traffic trend cannot favour one end.
  if [ $((pass_no % 2)) -eq 1 ]; then order="$GAINS"; else order=$(echo "$GAINS" | tr ' ' '\n' | tail -r 2>/dev/null || echo "$GAINS" | tr ' ' '\n' | tac); fi

  for g in $order; do
    printf 'pass %s  gain %-5s ' "$pass_no" "$g"
    set_gain "$g"
    sudo systemctl restart readsb
    sleep "$SETTLE"
    before=$(snapshot)
    sleep "$DWELL"
    after=$(snapshot)

    set -- $before; b_acc=$1; b_acc1=$2; b_val=$3; b_pos=$4
    set -- $after;  a_acc=$1; a_acc1=$2; a_val=$3; a_pos=$4
    a_md=$5; a_strong=$6; a_sig=$7; a_noise=$8

    ac=$(python3 -c "import json;print(len(json.load(open('/run/readsb/aircraft.json'))['aircraft']))" 2>/dev/null || echo 0)
    d_acc=$((a_acc - b_acc)); d_acc1=$((a_acc1 - b_acc1))
    d_val=$((a_val - b_val)); d_pos=$((a_pos - b_pos))

    echo "$pass_no,$g,$d_acc,$d_acc1,$d_val,$d_pos,$a_md,$a_strong,$a_sig,$a_noise,$ac" >> "$OUT"
    printf 'msgs %-8s positions %-6s max %-6s nm  strong %s\n' "$d_acc" "$d_pos" "$a_md" "$a_strong"
  done
done

echo
echo "=== summary (mean across passes) ==="
python3 - "$OUT" <<'PYEOF'
import csv, sys
from collections import defaultdict
rows = list(csv.DictReader(open(sys.argv[1])))
agg = defaultdict(list)
for r in rows:
    agg[r['gain']].append(r)
print('%-7s %-10s %-10s %-8s %-8s' % ('gain', 'msgs/pass', 'pos/pass', 'max_nm', 'strong'))
scored = []
for g, rs in agg.items():
    n = len(rs)
    msgs = sum(int(r['accepted']) for r in rs) / n
    pos = sum(int(r['positions']) for r in rs) / n
    mx = max(float(r['max_nm']) for r in rs)
    st = sum(int(r['strong']) for r in rs) / n
    scored.append((pos, msgs, g, mx, st))
    print('%-7s %-10.0f %-10.0f %-8.1f %-8.0f' % (g, msgs, pos, mx, st))
scored.sort(reverse=True)
print()
print('best by positions decoded: gain %s' % scored[0][2])
print('(positions is the better metric -- a position needs two good messages,')
print(' so it rewards clean decodes rather than raw message count.)')
PYEOF
