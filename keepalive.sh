#!/bin/bash
# gbrain stack keepalive — runs every ensure-*.sh on /data independently so one
# failing step never blocks the rest. Driven by system cron (*/2, installed by
# start.sh) and by start.sh once at boot. Deliberately has ZERO dependency on
# openclaw/agent/model availability: agent crons proved circular on 2026-07-02
# when a container restart killed the claude bridge, which killed the very
# agent crons that were supposed to revive it.
#
# HARD RULE learned from the 2026-07-02 boot-hang outage: NEVER capture an
# ensure script's output with command substitution. The ensure scripts spawn
# daemons; any daemon that inherits our stdout pipe keeps $(...) waiting
# forever even after the script itself exits — which held up start.sh and
# failed the whole deployment. All script output goes to the log FILE (an fd
# daemons may safely keep open), and every script gets a hard timeout.
LOG_SELF="/data/.gbrain/keepalive.log"
TS_LOG="/data/.tailscale/tailscaled.log"
STAMP="/data/.gbrain/keepalive.stamp"

mkdir -p /data/.gbrain /data/.tailscale

# keep logs bounded: keepalive ~5MB, tailscaled ~50MB (keep newest half)
for spec in "$LOG_SELF:5242880" "$TS_LOG:52428800"; do
  path="${spec%:*}"; cap="${spec##*:}"
  size=$(stat -c%s "$path" 2>/dev/null || echo 0)
  if [ "$size" -gt "$cap" ]; then
    tail -c $((cap / 2)) "$path" > "${path}.tmp" 2>/dev/null && mv "${path}.tmp" "$path"
  fi
done

run() {
  name="$1"; script="$2"
  if [ ! -f "$script" ]; then
    echo "$(date -u +%FT%TZ) $name MISSING $script" >> "$LOG_SELF"
    return
  fi
  # </dev/null: no stdin; >>file: daemons inheriting these fds cannot block us;
  # timeout: a wedged script dies instead of stalling boot or piling up crons.
  timeout 45 bash "$script" </dev/null >>"$LOG_SELF" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "$(date -u +%FT%TZ) $name rc=$rc (124=timeout)" >> "$LOG_SELF"
  fi
}

run tailscaled  /data/.tailscale/ensure-tailscale.sh

# On a cold boot tailscaled needs a few seconds to reach Running; if we race
# ahead, the serve mapping no-ops and ensure-http-server.sh detects no tailnet
# DNS name and starts gbrain WITHOUT --public-url — and once it's healthy no
# later round will restart it to fix the flag. When already Running this
# breaks out on the first iteration.
for _ in $(seq 1 20); do
  state=$(timeout 3 /data/.local/bin/tailscale --socket=/var/run/tailscale/tailscaled.sock status --json 2>/dev/null \
    | sed -n 's/.*"BackendState": "\([^"]*\)".*/\1/p' | head -1)
  [ "$state" = "Running" ] && break
  sleep 1
done

run serve-map   /data/.tailscale/ensure-gbrain-serve.sh
run gbrain-http /data/.gbrain/ensure-http-server.sh
run bridge      /data/gbrain-claude-bridge/ensure-proxy.sh
run price-patch /data/.gbrain/ensure-gbrain-pricing-patch.sh
run autopilot   /data/.gbrain/ensure-autopilot.sh

date -u +%FT%TZ > "$STAMP"
