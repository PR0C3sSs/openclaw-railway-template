#!/bin/bash
# Boot wrapper: bring the /data-resident gbrain sidecar stack (tailscaled,
# tailscale serve, gbrain HTTP server, claude bridge, autopilot, pricing patch)
# back up before alphaclaw starts, then install a system-cron keepalive so the
# stack self-heals every 2 minutes — with zero dependence on agent crons.
#
# alphaclaw MUST start even if the keepalive stalls or dies: the outer timeout
# is the hard ceiling on how long boot may spend on sidecars, and every phase
# echoes to container stdout so Railway deploy logs show exactly where boot is.
echo "[start] keepalive: begin"
timeout 120 bash /app/keepalive.sh </dev/null >/dev/null 2>&1
echo "[start] keepalive: done rc=$? (124=timeout; details in /data/.gbrain/keepalive.log)"

mkdir -p /data/.gbrain
{
  echo 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/data/.local/bin'
  echo '*/2 * * * * root timeout 300 /bin/bash /app/keepalive.sh >/dev/null 2>&1'
} > /etc/cron.d/gbrain-keepalive
chmod 644 /etc/cron.d/gbrain-keepalive
echo "[start] cron keepalive installed"

echo "[start] exec alphaclaw"
exec alphaclaw start
