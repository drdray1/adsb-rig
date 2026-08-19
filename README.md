# adsb-rig

A local ADS-B receiving station for **macOS** and **Raspberry Pi / Linux**. Decodes
1090 MHz with an RTL-SDR dongle, serves a live map on localhost, and optionally feeds
aircraft to an upstream service.

Your own FlightRadar, running on your own hardware, with the data staying on your machine
unless you explicitly turn on a feeder.

```
RTL-SDR dongle ──> readsb ──┬──> tar1090 map          http://localhost:8080
                            ├──> SBS-1 TCP :30003     Muninn, Virtual Radar
                            ├──> Beast   TCP :30005   piaware, fr24feed, RadarBox
                            ├──> aggregators         adsb.fi, airplanes.live, ...
                            └──> optional feeder ──>  WDGWars (via Muninn)
```

## What you need

- An RTL-SDR dongle. Developed against a **NooElec NESDR SMArt v5** (RTL2832U + R820T).
- A 1090 MHz antenna. A quarter wave is only **~6.9 cm** — the stubby whip in most kits is
  close to ideal here, unlike at FM/airband frequencies where it's far too short.
- macOS with Homebrew, or a Raspberry Pi running Raspberry Pi OS. A Pi 4/5 is
  comfortable; a Pi Zero 2 W works with caveats (see below).

Reception is dominated by antenna placement, not software. ADS-B is line-of-sight: a window
with open sky beats any amount of gain tuning, and getting the dongle away from USB 3 ports
and power strips matters more than most settings in this repo.

## Install

### macOS

```bash
git clone https://github.com/drdray1/adsb-rig ~/adsb
cd ~/adsb && ./install.sh
```

Installs `readsb` via Homebrew, fetches the tar1090 map assets and the aircraft database,
renders launchd agents, and (if you opt in) sets up the feeder.

### Raspberry Pi / Linux

Install the decoder with its own standard installer first — this project does **not**
reimplement it, and its systemd unit would collide with a second one:

```bash
sudo bash -c "$(wget -qO - https://raw.githubusercontent.com/wiedehopf/adsb-scripts/master/readsb-install.sh)"
sudo bash -c "$(wget -qO - https://raw.githubusercontent.com/wiedehopf/tar1090/master/install.sh)"
```

Then:

```bash
git clone https://github.com/drdray1/adsb-rig ~/adsb
cd ~/adsb && ./install.sh
```

It detects the existing readsb, finds which SBS-1 port it actually serves, and installs
only the feeder as a systemd **user** unit.

> **Heads up:** the Linux path is written but has **not been run on real hardware** yet.
> The shell logic, port detection, and unit rendering are tested; an actual Pi install
> isn't. Reports welcome.

#### Raspberry Pi Zero 2 W

It works, but the Zero 2 W has real constraints — worth knowing before you build on one:

- **Use Raspberry Pi OS Lite (64-bit).** 512 MB of RAM is the binding limit. readsb, the
  map and the feeder fit comfortably; a desktop on top does not.
- **Power is the most common failure.** An RTL-SDR pulls ~300 mA, and the Zero 2 W feeds it
  through a single micro-USB OTG port. Use a solid 2.5 A+ supply, and a *powered* hub if
  you add anything else. Brownouts show up as the dongle vanishing mid-run, which reads
  like a software fault but isn't.
- **CPU:** the quad-core Cortex-A53 handles 1090 MHz decoding fine — unlike the original
  Zero W, which is single-core ARMv6 and genuinely marginal. If it runs hot or you're
  sharing the board with other work, install with `PREAMBLE=75`.
- **SD card wear:** readsb writes JSON every second. On Linux, wiedehopf's packaging
  already points that at `/run` (tmpfs, in RAM), so the card isn't hammered. Don't
  "helpfully" redirect it onto the card.
- **2.4 GHz Wi-Fi only.** Fine for this — the upstream data rate is tiny — but the radio
  sits close to the dongle, so keep the antenna away from the board.

## Usage

```bash
./adsb-ctl start      # bring everything up
./adsb-ctl stop       # release the SDR for other radio software
./adsb-ctl status     # what's running, ports, live aircraft count
./adsb-ctl logs       # follow logs (optionally: logs readsb|web|muninn)
./adsb-ctl restart
```

On macOS the agents auto-start at login. On Linux, a headless Pi needs lingering so user
units run without an active login:

```bash
sudo loginctl enable-linger $USER
```

**Only one process can hold the dongle.** Run `./adsb-ctl stop` before using SDR++, GQRX or
similar, and `./adsb-ctl start` afterwards.

### Capturing a session by hand

```bash
./adsb-capture.py     # logs the SBS-1 stream to captures/, Ctrl-C for a summary
```

Useful for offline conversion, one-off uploads, or debugging. Note that
`aircraft.json` is a *snapshot* of what's overhead right now, whereas the SBS-1 stream
accumulates everything seen across the session.

## Feeding other services

This isn't tied to any one upstream. readsb can expose the same data several ways — add
these to the readsb arguments (in the launchd template on macOS, or `/etc/default/readsb`
on Linux) and point any consumer at them:

| Flag | Output | Typical consumer |
|---|---|---|
| `--net-bo-port` | Beast binary (**on by default here, :30005**) | piaware, fr24feed, RadarBox |
| `--net-sbs-port` | SBS-1 / BaseStation text | this repo's feeder, Virtual Radar |
| `--net-ro-port` | Raw AVR Mode-S | pyModeS and friends |
| `--net-vrs-port` | VRS JSON | Virtual Radar Server |
| `--net-connector IP,PORT,PROTOCOL` | Outbound push | remote aggregators |

Anything local can also just read `tar1090/html/data/aircraft.json`.

> On a Pi, wiedehopf's packaging shifts the whole port range: SBS-1 is on **20003**, not
> 30003. `install.sh` reads `/etc/default/readsb` and probes rather than assuming.

### Feeding aggregators

Copy `feeds.conf.example` to `feeds.conf`, uncomment what you want, and re-run
`./install.sh`. Each active line becomes a readsb `--net-connector`, so readsb dials
**out** — nothing is exposed to the internet and no inbound firewall rules are needed.

```
feed.adsb.fi             30004   beast_reduce_plus_out
feed.airplanes.live      30004   beast_reduce_plus_out
```

`install.sh` generates a UUID once at `~/.config/adsb-rig/uuid` and passes it with
`--uuid`, so your receiver identity stays stable across reinstalls.

| Service | Host | Port | Type |
|---|---|---|---|
| Airplanes.live | `feed.airplanes.live` | 30004 | non-profit |
| ADSB.fi | `feed.adsb.fi` | 30004 | non-profit |
| ADSB.lol | `in.adsb.lol` | 30004 | non-profit |
| Planespotters | `feed.planespotters.net` | 30004 | non-profit |
| The Air Traffic | `feed.theairtraffic.com` | 30004 | non-profit |
| ADSBExchange | `feed1.adsbexchange.com` | 30004 | community |
| AVDelphi | `data.avdelphi.com` | 24999 | — |
| Fly Italy ADSB | `dati.flyitalyadsb.com` | 4905 | — |

All use `beast_reduce_plus_out` — Beast format with reduced throughput plus the UUID,
which is what these services expect. Endpoints come from the
[sdr-enthusiasts ultrafeeder](https://github.com/sdr-enthusiasts/docker-adsb-ultrafeeder)
project; `feed.adsb.fi:30004` was verified to accept a live connection. Aggregators do move
hosts occasionally, so check their own docs if one stops connecting.

**Not covered here:**

- **MLAT** needs a separate `mlat-client` daemon and your exact coordinates. The ports
  above are ADS-B only.
- **FlightAware, FlightRadar24, RadarBox, PlaneFinder** run their own feeder clients with
  their own accounts and keys. They read **Beast** rather than connecting the way the
  aggregators above do — see below.

### FlightAware (PiAware)

readsb serves Beast on **30005** by default here, which is what `piaware`, `fr24feed`,
RadarBox and PlaneFinder all read. You do **not** need dump1090-fa; this rig replaces it.

`piaware` is packaged for Raspberry Pi OS only — there's no macOS build — so this is the
one thing that genuinely wants the Pi rather than the Mac.

```bash
wget https://www.flightaware.com/adsb/piaware/files/packages/pool/piaware/f/flightaware-apt-repository/flightaware-apt-repository_1.3_all.deb
sudo dpkg -i flightaware-apt-repository_1.3_all.deb
sudo apt update && sudo apt install piaware
```

**Skip `sudo apt install dump1090-fa`** — that step in FlightAware's guide is for people
without a decoder. You have readsb. Instead point piaware at it:

```bash
sudo piaware-config receiver-type other
sudo piaware-config receiver-host 127.0.0.1
sudo piaware-config receiver-port 30005     # see the port note below
sudo systemctl restart piaware
```

> **Port gotcha:** `30005` is right on macOS with this repo's config. On a Pi running
> wiedehopf's readsb, Beast is on **20005** — the same 300xx → 200xx shift that moves
> SBS-1 to 20003. Check `/etc/default/readsb` before assuming.

Then claim the receiver to your account:

```bash
cat /var/cache/piaware/feeder_id
# open https://www.flightaware.com/adsb/piaware/claim/<that-id>
```

Feeding FlightAware earns a free Enterprise account (they list it at $99.95/mo).

`receiver-type` accepts `rtlsdr, beast, radarcape, relay, other`; `receiver-host` and
`receiver-port` apply to `relay` and `other`. **MLAT** comes along with piaware but needs
your receiver's exact coordinates set on FlightAware's site to contribute.

### The WDGWars feeder (optional)

[WDGWars](https://wdgwars.pl) is a real-world wardriving/hacking game that accepts ADS-B
captures. Uploads go through [Muninn](https://github.com/Yggdrasil-AI-labs/adsb-to-wdgwars),
which speaks an HMAC-signed envelope and handles retries.

```bash
./install.sh --with-feeder
# then, so the key never lands in shell history or a script argument:
./muninn/.venv/bin/python ./muninn/muninn.py --save-key 'YOUR_KEY'
./muninn/.venv/bin/python ./muninn/muninn.py --whoami    # verify
```

Generate a **dedicated** key at `wdgwars.pl/profile → API Keys` so revoking it doesn't
break your other tools. It's stored at `~/.config/muninn/api.key` (mode `0600`) and never
in this repo.

The feeder uploads hourly by default and only sends aircraft that are new or changed, so a
quiet hour sends nothing at all. Change `INTERVAL` when installing, or edit the rendered
unit.

## Tuning

| What | Where | Notes |
|---|---|---|
| Gain | `GAIN=auto ./install.sh` | Or a fixed value from the tuner's table: `49.6 44.5 40.2 36.4 32.8`. Higher isn't automatically better — a strong nearby transmitter can overload the front end. |
| Receiver location | add `--lat`/`--lon` to the readsb args | Optional. Centers the map and enables range rings. |
| Upload interval | `INTERVAL=3600 ./install.sh` | Seconds. |
| Beast port | `BEAST_PORT=30005 ./install.sh` | What vendor feeder clients read. |
| Map port | `HTTP_PORT=8080 ./install.sh` | Bound to `127.0.0.1` deliberately. |
| CPU load | `PREAMBLE=75 ./install.sh` | `--preamble-threshold`. readsb's own help: *"lower threshold → more CPU usage (default: 58, pi zero / pi 1: 75, hot CPU 42)"*. Raising it trades a little sensitivity for noticeably less CPU. **readsb has no sample-rate option** — this is the knob. |

## Troubleshooting

**`no supported devices found` in the log** — the dongle is unplugged, not a software fault.
Both service managers retry, so replugging recovers on its own (~5s on macOS). Confirm
independently with `rtl_test`.

**The map loads but there are no aircraft** — usually antenna placement. Check
`./adsb-ctl status` for a live count. Hex codes with no positions means you're receiving but
too weak for full position messages.

**The feeder's log looks dead** — silence is normal. Muninn only logs and uploads when
aircraft with *positions* have changed; no new aircraft means no line at all.

**`ERR_CONNECTION_REFUSED` on the map** — check `logs/web.log`. macOS ships bash 3.2, where
expanding an *empty array* under `set -u` aborts the script (`LOC[@]: unbound variable`).
Use `${ARR[@]+"${ARR[@]}"}`, never `"${ARR[@]}"`, in anything here.

**A shell capture with `nc` records nothing** — `nc` needs `-d` when backgrounded, or its
stdin hits EOF and it closes the connection immediately. This is why `adsb-capture.py` is
Python: that plus bash deferring trapped signals while waiting on a foreground child made
the shell version unreliable.

**Nothing in the feeder log for minutes at a time** — `PYTHONUNBUFFERED=1` must be set in
the unit, or Python block-buffers stdout to the log file.

**Using SDR++ afterwards and it crashes on Play** — hit refresh, then explicitly re-select
the device in the dropdown before pressing Play. Its gain table is only populated by
selecting the device, and it will segfault indexing an empty one.

## Credits

- [readsb](https://github.com/wiedehopf/readsb) and
  [tar1090](https://github.com/wiedehopf/tar1090) — wiedehopf
- [Muninn](https://github.com/Yggdrasil-AI-labs/adsb-to-wdgwars) — Yggdrasil-AI-labs
- [WDGWars](https://wdgwars.pl) — LOCOSP

The launchd labels use a `com.drdray1.*` prefix. Harmless, and trivially changed in
`launchd/*.template` plus `PREFIX` in `adsb-ctl` if you'd rather it were yours.

## License

MIT — see [LICENSE](LICENSE).
