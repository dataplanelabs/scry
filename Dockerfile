# scry — persistent, logged-in, agent-drivable browser.
# ONE long-lived headful Chromium (never tied to the VNC session) with a stable
# CDP endpoint, an Xvfb virtual display, and x11vnc + noVNC for a one-time human
# login. Disconnecting noVNC only stops the display mirror — Chromium keeps
# running, so a logged-in session (incl. session-scoped cookies) survives until
# the container/pod restarts. Everything is env-driven; see start.sh + README.
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      chromium \
      xvfb \
      x11vnc \
      novnc websockify \
      socat \
      ca-certificates \
      fonts-liberation fonts-noto-cjk \
      dumb-init procps \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html

COPY start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

# Non-root so Chromium keeps its real renderer sandbox (the node must allow
# unprivileged user namespaces). The K8s securityContext runs this uid and an
# init-container chowns the mounted /data PVC to it; the build-time chown + the
# 1777 X11 socket dir cover a plain `docker run` (no PVC, no init-container).
RUN useradd --uid 1000 --create-home --shell /usr/sbin/nologin chrome \
    && mkdir -p /data && chown chrome:chrome /data \
    && mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix
ENV HOME=/home/chrome

# Defaults make this a drop-in for the prior single-purpose chrome pod:
# profile at /data, CDP on 9222 (socat -> internal 9223), noVNC on 6080.
ENV PROFILE_DIR=/data \
    DISPLAY=:99 \
    CDP_PORT=9222 \
    CDP_INTERNAL_PORT=9223 \
    NOVNC_PORT=6080 \
    VNC_PORT=5900 \
    SCREEN=1440x900x24 \
    CHROME_EXTRA_FLAGS=""

EXPOSE 9222 6080
USER chrome
ENTRYPOINT ["dumb-init", "--"]
CMD ["/usr/local/bin/start.sh"]
