#!/usr/bin/env bash
# radar-capture.sh: record raw radar traffic + NMEA 2000 on the HALPI2 for
# Mayara bug reports (e.g. MarineYachtRadar/mayara-server#722).
#
# Runs ON the HALPI2. The HALPI2 is where Mayara runs, so it already receives
# every spoke; no bridge or port mirror needed. See docs/radar-capture.md.
#
#   sudo ./radar-capture.sh check            # preflight, run this first
#   sudo ./radar-capture.sh start [label]    # start recording (detached, survives SSH drop)
#   sudo ./radar-capture.sh mark "text"      # timestamped note + live target snapshot
#   sudo ./radar-capture.sh status
#   sudo ./radar-capture.sh stop             # stop, collect logs/settings, gzip
#
# Tunables (env): RADAR_IP, CAN_IF, OUT_BASE, MAX_MINUTES, MIN_FREE_MB
set -euo pipefail

# Ask Mayara where the radar is (DHCP can move it); fall back to the last known address.
RADAR_IP=${RADAR_IP:-$(curl -s -m 3 http://localhost:6502/signalk/v2/api/vessels/self/radars 2>/dev/null \
  | python3 -c 'import json,sys; print(next(iter(json.load(sys.stdin)["radars"].values()))["radarIpAddress"])' 2>/dev/null \
  || echo 192.168.88.237)}
CAN_IF=${CAN_IF:-}
OUT_BASE=${OUT_BASE:-/var/lib/radar-capture}
MAX_MINUTES=${MAX_MINUTES:-45}
MIN_FREE_MB=${MIN_FREE_MB:-2048}
UNIT=radar-capture
MAYARA=http://localhost:6502/signalk/v2/api/vessels/self/radars
SK=http://localhost:3000
RADARS=(nav6820A nav6820B)
# Radar host + Navico multicast groups (src/lib/brand/navico/protocol.rs): spokes,
# reports, and Mayara's own heading (239.238.55.73) / nav + speed (236.6.7.x) to the HALO.
FILTER="host $RADAR_IP or dst net 236.6.7.0/24 or dst net 236.6.9.0/24 or dst host 239.238.55.73"
SELF=$(readlink -f "$0")

die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "run with sudo"; }
now() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }
net_if() { ip -o route get "$RADAR_IP" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p'; }
can_if() { # explicit CAN_IF, else first real CAN interface, else any can*/vcan*
  [[ -n $CAN_IF ]] && { echo "$CAN_IF"; return; }
  { ip -o link show type can 2>/dev/null | awk -F': ' '{print $2}'; ls /sys/class/net | grep -E '^v?can[0-9]'; } | head -1 || true
}
mayara_ctr() { docker ps --format '{{.Names}}' 2>/dev/null | grep -i mayara | head -1 || true; }
latest() { ls -1d "$OUT_BASE"/*/ 2>/dev/null | tail -1 | sed 's:/$::' || true; }
free_mb() { df -Pm "$OUT_BASE" | awk 'NR==2{print $4}'; }

snapshot() { # $1 = dir, $2 = tag
  mkdir -p "$1/settings"
  for r in "${RADARS[@]}"; do
    curl -s -m 5 "$MAYARA/$r/controls"     > "$1/settings/$2-controls-$r.json" || true
    curl -s -m 5 "$MAYARA/$r/capabilities" > "$1/settings/$2-capabilities-$r.json" || true
    curl -s -m 5 "$MAYARA/$r/targets"      > "$1/settings/$2-targets-$r.json" || true
  done
  curl -s -m 5 http://localhost:6502/signalk > "$1/settings/$2-mayara-server.json" || true
  curl -s -m 5 "$SK/signalk/v1/api/sources" > "$1/settings/$2-sk-sources.json" || true
}

cmd_check() {
  need_root
  local ok=1 ifc can ctr n
  for t in tcpdump candump curl gzip; do
    command -v $t >/dev/null || { echo "✗ $t missing: sudo apt install tcpdump can-utils"; ok=0; }
  done
  [[ $ok == 1 ]] || exit 1
  ifc=$(net_if); [[ -n $ifc ]] && echo "✓ radar $RADAR_IP reachable via $ifc (mtu $(cat /sys/class/net/$ifc/mtu))" || { echo "✗ no route to radar $RADAR_IP"; ok=0; }
  if [[ -n $ifc ]]; then
    # Count only packets FROM the radar: $FILTER also matches Mayara's own
    # heading/nav packets to the HALO, which flow even when the radar is off.
    local probe; probe=$(mktemp --suffix=.pcap)
    timeout 6 tcpdump -i "$ifc" -nn -s 0 -c 5000 -w "$probe" "src host $RADAR_IP" >/dev/null 2>&1 || true
    n=$(tcpdump -nn -r "$probe" 2>/dev/null | wc -l)
    # Spokes exceed the 1500 MTU, so while transmitting they arrive as IP fragments.
    local frags; frags=$(tcpdump -nn -r "$probe" 'ip[6:2] & 0x3fff != 0' 2>/dev/null | wc -l)
    rm -f "$probe"
    if (( n == 0 )); then echo "✗ nothing received from the radar in 6 s (powered on? cabled?)"; ok=0
    elif (( frags > 100 )); then echo "✓ radar TRANSMITTING: $n packets from $RADAR_IP in 6 s, $frags spoke fragments"
    else echo "✓ radar in STANDBY: $n packets from $RADAR_IP in 6 s, no spokes yet (fine: start in standby, then transmit)"; fi
  fi
  can=$(can_if)
  if [[ -n $can ]]; then
    n=$( (timeout 3 candump -L "$can" 2>/dev/null || true) | wc -l)
    [[ $n -gt 50 ]] && echo "✓ NMEA 2000 on $can: $n frames in 3 s" || { echo "✗ only $n CAN frames on $can in 3 s"; ok=0; }
  else echo "✗ no CAN interface found (set CAN_IF=...)"; ok=0; fi
  ctr=$(mayara_ctr); [[ -n $ctr ]] && echo "✓ Mayara container: $ctr" || { echo "✗ Mayara container not found"; ok=0; }
  mkdir -p "$OUT_BASE"; echo "✓ $(free_mb) MB free in $OUT_BASE (stops below $MIN_FREE_MB MB, or after $MAX_MINUTES min)"
  echo "— nav6820B settings (the maintainer wants these as in #722):"
  curl -s -m 5 "$MAYARA/nav6820B/controls" | python3 -c '
import json,sys,math
c=json.load(sys.stdin); v=lambda k:(c.get(k) or {}).get("value")
spd={0:"Normal",1:"Medium",2:"Fast"}.get(v("arpaDetectMaxSpeed"),v("arpaDetectMaxSpeed"))
gz=c.get("guardZone1") or {}
print("  ARPA max speed: %s (want Fast) | doppler: %s | doppler auto-track: %s (want 1) | range: %s m"
      % (spd, v("doppler"), v("dopplerAutoTrack"), v("range")))
print("  guard zone 1: %s-%s m, %.0f-%.0f deg, enabled=%s (want 5000-6000 m)"
      % (gz.get("startDistance"), gz.get("endDistance"), math.degrees(gz.get("value", 0)),
         math.degrees(gz.get("endValue", 0)), gz.get("enabled")))' 2>/dev/null || echo "  (could not read Mayara controls)"
  [[ $ok == 1 ]] && echo "READY" || { echo "NOT READY"; exit 1; }
}

cmd_start() {
  need_root
  systemctl is-active --quiet "$UNIT" && die "already recording: $(latest) (use: $0 status / stop)"
  local label=${1:-halo} dir
  dir="$OUT_BASE/$(date -u +%Y%m%dT%H%M%SZ)-${label//[^A-Za-z0-9_-]/_}"
  mkdir -p "$dir"
  systemd-run --unit="$UNIT" --collect -p TimeoutStopSec=900 -p KillMode=mixed \
    --setenv=RADAR_IP="$RADAR_IP" --setenv=CAN_IF="$CAN_IF" --setenv=MAX_MINUTES="$MAX_MINUTES" \
    --setenv=MIN_FREE_MB="$MIN_FREE_MB" --setenv=OUT_BASE="$OUT_BASE" \
    "$SELF" _record "$dir" >/dev/null
  sleep 2
  systemctl is-active --quiet "$UNIT" || { journalctl -u "$UNIT" -n 30 --no-pager; die "recorder failed to start"; }
  echo "Recording → $dir"
  echo "  mark:   sudo $0 mark \"vessel 1 splitting now\""
  echo "  status: sudo $0 status"
  echo "  stop:   sudo $0 stop"
}

cmd_record() { # runs under systemd
  local dir=$1 ifc can t0 pids=()
  ifc=$(net_if); can=$(can_if); t0=$(date -u +%s)
  echo "$(now) start if=$ifc can=$can radar=$RADAR_IP filter: $FILTER" >> "$dir/marks.txt"
  snapshot "$dir" start
  tcpdump -i "$ifc" -nn -s 0 -B 65536 -w "$dir/radar.pcap" "$FILTER" 2> "$dir/tcpdump.log" & pids+=($!)
  [[ -n $can ]] && { candump -L "$can" > "$dir/n2k.candump" 2> "$dir/candump.log" & pids+=($!); }
  finalize() {
    trap - TERM INT
    kill -INT "${pids[@]}" 2>/dev/null || true; wait "${pids[@]}" 2>/dev/null || true
    local t1; t1=$(date -u +%s)
    echo "$(now) stop" >> "$dir/marks.txt"
    snapshot "$dir" end
    local ctr; ctr=$(mayara_ctr)
    [[ -n $ctr ]] && docker logs --since "$t0" --until "$t1" "$ctr" > "$dir/mayara.log" 2>&1 || true
    curl -s -m 20 "$SK/signalk/v2/api/history/values?paths=navigation.position,navigation.headingTrue,navigation.courseOverGroundTrue,navigation.speedOverGround&from=$(date -u -d @$t0 +%FT%TZ)&to=$(date -u -d @$t1 +%FT%TZ)&resolution=1" \
      > "$dir/own-ship-history.json" || true
    gzip -f "$dir/radar.pcap" "$dir/n2k.candump" 2>/dev/null || true
    chmod -R a+rX "$dir"
    exit 0
  }
  trap finalize TERM INT
  while sleep 15; do
    (( $(free_mb) < MIN_FREE_MB )) && { echo "$(now) auto-stop: disk below $MIN_FREE_MB MB" >> "$dir/marks.txt"; finalize; }
    (( $(date -u +%s) - t0 > MAX_MINUTES * 60 )) && { echo "$(now) auto-stop: $MAX_MINUTES min limit" >> "$dir/marks.txt"; finalize; }
    for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null || { echo "$(now) auto-stop: a recorder died (see *.log)" >> "$dir/marks.txt"; finalize; }; done
  done
}

cmd_mark() {
  need_root
  local dir; dir=$(latest); [[ -n $dir ]] || die "no capture directory"
  local ts; ts=$(now)
  echo "$ts ${*:-mark}" >> "$dir/marks.txt"
  mkdir -p "$dir/marks"
  for r in "${RADARS[@]}"; do curl -s -m 5 "$MAYARA/$r/targets" > "$dir/marks/$ts-targets-$r.json" || true; done
  echo "marked at $ts: ${*:-mark}"
}

cmd_status() {
  local dir; dir=$(latest)
  if systemctl is-active --quiet "$UNIT"; then
    echo "RECORDING → $dir (started $(head -1 "$dir/marks.txt" | cut -c1-19))"
    ls -la "$dir" | grep -E "pcap|candump" || true
    echo "free: $(free_mb) MB"; tail -5 "$dir/marks.txt"
  else
    echo "not recording${dir:+; last capture: $dir}"
  fi
}

cmd_stop() {
  need_root
  systemctl is-active --quiet "$UNIT" || die "not recording"
  local dir; dir=$(latest)
  echo "stopping + compressing (may take a minute)…"
  systemctl stop "$UNIT"
  echo "— $dir"; ls -la "$dir"
  grep -hE "captured|received|dropped" "$dir/tcpdump.log" || true
  echo "— marks:"; cat "$dir/marks.txt"
}

case ${1:-help} in
  check)   cmd_check ;;
  start)   shift; cmd_start "$@" ;;
  _record) shift; cmd_record "$@" ;;
  mark)    shift; cmd_mark "$@" ;;
  status)  cmd_status ;;
  stop)    cmd_stop ;;
  *)       sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
