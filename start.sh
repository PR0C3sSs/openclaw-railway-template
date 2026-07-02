#!/bin/bash
# Boot wrapper: bring the /data-resident gbrain sidecar stack (tailscaled,
# tailscale serve, gbrain HTTP server, claude bridge, autopilot, pricing patch)
# back up before alphaclaw starts, then install a system-cron keepalive so the
# stack self-heals every 2 minutes — with zero dependence on agent crons.
bash /app/keepalive.sh || true

mkdir -p /data/.gbrain
{
  echo 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/data/.local/bin'
  echo '*/2 * * * * root /bin/bash /app/keepalive.sh >> /data/.gbrain/keepalive.log 2>&1'
} > /etc/cron.d/gbrain-keepalive
chmod 644 /etc/cron.d/gbrain-keepalive

exec alphaclaw start
