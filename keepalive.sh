#!/bin/bash
# gbrain stack keepalive — runs every ensure-*.sh on /data independently so one
# failing step never blocks the rest. Driven by system cron (*/2, installed by
# start.sh) and by start.sh once at boot. Deliberately has ZERO dependency on
# openclaw/agent/model availability: agent crons proved circular on 2026-07-02
# when a container restart killed the claude bridge, which killed the very
# agent crons that were supposed to revive it.
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
    echo "$(date -u +%FT%TZ) $name MISSING $script"
    return
  fi
  out=$(bash "$script" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "$(date -u +%FT%TZ) $name rc=$rc ${out:0:200}"
  fi
}

run tailscaled  /data/.tailscale/ensure-tailscale.sh
run serve-map   /data/.tailscale/ensure-gbrain-serve.sh
run gbrain-http /data/.gbrain/ensure-http-server.sh
run bridge      /data/gbrain-claude-bridge/ensure-proxy.sh
run price-patch /data/.gbrain/ensure-gbrain-pricing-patch.sh
run autopilot   /data/.gbrain/ensure-autopilot.sh

date -u +%FT%TZ > "$STAMP"
