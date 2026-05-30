#!/bin/sh
# Launch ONE long-lived Chromium + Xvfb + x11vnc + noVNC + socat CDP bridge.
# Chromium's lifecycle is independent of the VNC session, so a human login
# persists for an agent driving CDP. If Chromium dies, the script exits so the
# orchestrator (e.g. K8s) restarts the container. All knobs are env-driven.
set -eu

PROFILE="${PROFILE_DIR:-/data}"
DISP="${DISPLAY:-:99}"
CDP_PORT="${CDP_PORT:-9222}"
CDP_INTERNAL_PORT="${CDP_INTERNAL_PORT:-9223}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
VNC_PORT="${VNC_PORT:-5900}"
SCREEN="${SCREEN:-1440x900x24}"
CHROME_EXTRA_FLAGS="${CHROME_EXTRA_FLAGS:-}"
VNC_PASSWORD="${VNC_PASSWORD:-}"
export DISPLAY="$DISP"

# Window size derived from SCREEN (WxHxDEPTH) so Chromium fills the display.
WIN_W="$(echo "$SCREEN" | cut -dx -f1)"
WIN_H="$(echo "$SCREEN" | cut -dx -f2)"

mkdir -p "$PROFILE"
# Clear any stale SingletonLock from an unclean restart (would block Chromium).
rm -f "$PROFILE"/Singleton* 2>/dev/null || true

# Virtual display.
Xvfb "$DISP" -screen 0 "$SCREEN" -ac +extension RANDR >/tmp/xvfb.log 2>&1 &
sleep 2

# The one persistent Chromium. CDP binds loopback (M113 requires non-public
# bind); socat re-exposes it on CDP_PORT. Stability flags (WHY each matters):
#   --no-sandbox / --disable-dev-shm-usage : containers lack the namespaces and
#       have a tiny /dev/shm; without these Chromium crashes on heavy pages.
#   --disable-gpu             : no GPU in the container; SwiftShader churn can
#       wedge the renderer.
#   --disable-background-timer-throttling / --disable-backgrounding-occluded-
#       windows / --disable-renderer-backgrounding : a headful tab nobody is
#       looking at gets throttled/suspended, which stalls CDP commands and
#       drops the long-lived debugger socket. Keep the page hot.
#   --no-zygote              : the zygote forking model is flaky under
#       --no-sandbox in minimal containers; spawn renderers directly.
chromium \
  --no-sandbox \
  --disable-dev-shm-usage \
  --disable-gpu \
  --disable-background-timer-throttling \
  --disable-backgrounding-occluded-windows \
  --disable-renderer-backgrounding \
  --no-zygote \
  --user-data-dir="$PROFILE" \
  --remote-debugging-port="$CDP_INTERNAL_PORT" \
  --remote-debugging-address=127.0.0.1 \
  --remote-allow-origins='*' \
  --no-first-run --no-default-browser-check \
  --password-store=basic \
  --window-size="${WIN_W},${WIN_H}" --start-maximized \
  --restore-last-session \
  $CHROME_EXTRA_FLAGS \
  about:blank >/tmp/chromium.log 2>&1 &
CHROMIUM_PID=$!

# Forward pod SIGTERM to Chromium and wait for its clean exit so cookies + session
# state flush to /data before SIGKILL. Without this, a clean shutdown purges the
# session-scoped login cookie and the next boot starts logged out. Paired with
# --restore-last-session above, which re-adopts session cookies on every boot.
term() {
  kill -TERM "$CHROMIUM_PID" 2>/dev/null || true
  wait "$CHROMIUM_PID" 2>/dev/null || true
  exit 0
}
trap term TERM INT

# Bridge 0.0.0.0:CDP_PORT -> 127.0.0.1:CDP_INTERNAL_PORT for the CDP client.
# Hardened for a long-lived debugger WebSocket (trace 019e7733: the socket was
# dropped between every action, forcing reconnects):
#   keepalive + keepidle/keepintvl/keepcnt : probe the TCP path so an idle-but-
#       alive CDP connection is kept open instead of silently half-closing.
#   -T 0 : disable socat's inactivity timeout so an idle CDP socket is NEVER
#       cut (a busy agent may pause between commands).
sleep 4
socat -T 0 \
  TCP-LISTEN:"$CDP_PORT",fork,reuseaddr,keepalive,keepidle=30,keepintvl=10,keepcnt=3 \
  TCP:127.0.0.1:"$CDP_INTERNAL_PORT",keepalive \
  >/tmp/socat.log 2>&1 &

# Human view: x11vnc mirrors the display (disconnect does NOT stop Chromium).
# Empty VNC_PASSWORD => -nopw (open, intended for cluster-internal only). Set it
# => hash via x11vnc -storepasswd and serve with -rfbauth.
if [ -n "$VNC_PASSWORD" ]; then
  x11vnc -storepasswd "$VNC_PASSWORD" /tmp/vncpass >/dev/null 2>&1
  AUTH="-rfbauth /tmp/vncpass"
else
  AUTH="-nopw"
fi
# shellcheck disable=SC2086
x11vnc -display "$DISP" -forever -shared $AUTH -rfbport "$VNC_PORT" -quiet \
  >/tmp/x11vnc.log 2>&1 &
sleep 1
websockify --web /usr/share/novnc "$NOVNC_PORT" "localhost:$VNC_PORT" \
  >/tmp/novnc.log 2>&1 &

# Tie container life to Chromium: exit (→ restart) only if Chromium dies. Loop so
# the TERM trap can fire, flush cookies, and exit cleanly instead of being
# SIGKILLed. The CDP bridge and VNC stack are disposable; the session is the asset.
while kill -0 "$CHROMIUM_PID" 2>/dev/null; do
  wait "$CHROMIUM_PID" 2>/dev/null && break
done
echo "chromium exited; shutting down" >&2
