#!/bin/bash
# Boot-hang regression test for start.sh/keepalive.sh.
# Reproduces the 2026-07-02 outage: an ensure script spawns a daemon that
# inherits stdout and never exits. Old keepalive (command substitution) hangs
# forever; fixed keepalive must reach "exec alphaclaw" quickly anyway.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
rm -rf "$T"; mkdir -p "$T/data/.tailscale" "$T/data/.gbrain" "$T/data/gbrain-claude-bridge" "$T/app" "$T/etc/cron.d" "$T/data/.local/bin"

# --- mock ensure scripts on fake /data ---
cat > "$T/data/.tailscale/ensure-tailscale.sh" <<'EOF'
#!/bin/bash
echo "mock tailscaled ok"
EOF
# THE HOSTILE ONE: daemon inherits our stdout/stderr and never exits
cat > "$T/data/.gbrain/ensure-http-server.sh" <<'EOF'
#!/bin/bash
( while true; do sleep 60; done ) &
echo "mock gbrain started (daemon holds stdout)"
EOF
cat > "$T/data/.tailscale/ensure-gbrain-serve.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$T/data/gbrain-claude-bridge/ensure-proxy.sh" <<'EOF'
#!/bin/bash
exit 3
EOF
cat > "$T/data/.gbrain/ensure-gbrain-pricing-patch.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$T/data/.gbrain/ensure-autopilot.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
# tailscale stub: report Running so the readiness wait exits on iteration 1
cat > "$T/data/.local/bin/tailscale" <<'EOF'
#!/bin/bash
echo '{"BackendState": "Running"}'
EOF
chmod +x "$T"/data/.tailscale/*.sh "$T"/data/.gbrain/*.sh "$T"/data/gbrain-claude-bridge/*.sh "$T/data/.local/bin/tailscale"

localize() { # rewrite absolute paths into the sandbox; neuter exec
  sed -e "s|/data/|$T/data/|g" -e "s|/app/|$T/app/|g" -e "s|/etc/cron.d/|$T/etc/cron.d/|g" \
      -e "s|exec alphaclaw start|echo BOOT_REACHED_ALPHACLAW|" "$1" > "$2"
}

echo "== control: OLD keepalive (merge 6788890) must hang =="
git -C "$REPO" show 6788890:keepalive.sh > "$HERE/old-keepalive.sh"
localize "$HERE/old-keepalive.sh" "$T/app/keepalive-old.sh"
timeout 15 bash "$T/app/keepalive-old.sh" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 124 ]; then echo "PASS: old version hangs (rc=124), bug reproduced"; else echo "UNEXPECTED: old version rc=$rc (bug not reproduced)"; fi
pkill -f "while true; do sleep 60" 2>/dev/null

echo "== fixed keepalive.sh must finish fast =="
localize "$REPO/keepalive.sh" "$T/app/keepalive.sh"
start=$SECONDS
timeout 30 bash "$T/app/keepalive.sh"; rc=$?
dur=$((SECONDS-start))
[ "$rc" -eq 0 ] && [ -f "$T/data/.gbrain/keepalive.stamp" ] && echo "PASS: fixed keepalive rc=0 in ${dur}s, stamp written" || { echo "FAIL: rc=$rc dur=${dur}s"; exit 1; }
grep -q "bridge rc=3" "$T/data/.gbrain/keepalive.log" && echo "PASS: failure of one script logged, others not blocked" || { echo "FAIL: bridge failure not logged"; exit 1; }

echo "== full start.sh must reach alphaclaw =="
localize "$REPO/start.sh" "$T/app/start.sh"
start=$SECONDS
OUT=$(timeout 60 bash "$T/app/start.sh"); rc=$?
dur=$((SECONDS-start))
echo "$OUT" | grep -q "BOOT_REACHED_ALPHACLAW" && [ "$rc" -eq 0 ] && echo "PASS: start.sh reached alphaclaw in ${dur}s despite hostile daemon" || { echo "FAIL: rc=$rc dur=${dur}s out=$OUT"; exit 1; }
grep -q "keepalive.sh" "$T/etc/cron.d/gbrain-keepalive" && echo "PASS: cron entry installed" || { echo "FAIL: cron entry missing"; exit 1; }

pkill -f "while true; do sleep 60" 2>/dev/null
echo "== ALL PASS =="
