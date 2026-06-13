# scry

> A persistent, logged-in, **agent-drivable** browser in a container — log in once by hand, then let agents drive it over CDP for as long as the container lives.

## What

`scry` runs **one** long-lived headful Chromium inside a container and exposes two surfaces:

- **noVNC** — a browser-based VNC view for a human to do a **one-time interactive login** (passwords, MFA, captchas, cookie-consent). You watch the real screen and type.
- **Chrome DevTools Protocol (CDP)** on `:9222` — for an **agent / automation** to drive the *same, already-logged-in* browser (navigate, click, scrape, screenshot, run JS).

The login session (cookies, localStorage, IndexedDB — the whole Chromium profile) lives on a **mounted volume**, not in the image. Disconnecting noVNC stops only the display mirror; Chromium and your session keep running until the container restarts.

Stack: headful **Chromium** + **Xvfb** virtual display + **x11vnc** + **noVNC** (websockify) + a **socat** CDP bridge.

## Why

Most "browser-in-a-container" images are stateless: every run starts cold, so anything behind a login — and especially anything behind MFA — is painful or impossible to automate. `scry` flips that:

1. A human logs in **once** via noVNC.
2. The profile persists on a volume.
3. Agents attach over CDP indefinitely and act as the logged-in user — no re-auth per task, **no credentials handed to the agent, no secrets baked into the image**.

It is deliberately **one browser, one profile, one identity** per container. Run N containers for N identities.

## Architecture

```
              one-time, interactive                        long-lived, automated
            ┌────────────────────────┐                   ┌────────────────────────┐
  HUMAN  ───┤  noVNC  :NOVNC_PORT     │      AGENT  ──────┤  CDP  :CDP_PORT (TCP)   │
 (browser   │  websockify → x11vnc    │   (CDP client)    │  socat bridge           │
  tab)      │  → VNC :VNC_PORT        │                   │  (keepalive, no idle    │
  log in    └───────────┬────────────┘                   │   cut — see hardening)  │
  once                  │ DISPLAY                         └───────────┬────────────┘
                        │ mirrors screen                              │ forwards to
   ┌────────────────────┼─────────────────────────────────────────── │ ───────────┐
   │ CONTAINER          ▼                                             ▼            │
   │            ┌───────────────┐                          ┌────────────────────┐ │
   │            │ Xvfb (DISPLAY)│                          │ socat              │ │
   │            │  $SCREEN geom │                          │ :CDP_PORT          │ │
   │            └──────┬────────┘                          │  → 127.0.0.1:      │ │
   │                   │ renders                           │     CDP_INTERNAL   │ │
   │            ┌──────┴──────────────────────────┐        └─────────┬──────────┘ │
   │            │ Chromium (headful, ONE process,  │◄─────────────────┘            │
   │            │ never tied to VNC lifecycle)     │  CDP on LOOPBACK only         │
   │            │ --remote-debugging-port          │  (Chromium M113+ refuses to   │
   │            │     =CDP_INTERNAL (127.0.0.1)    │   bind CDP to a public addr)  │
   │            │ --user-data-dir=$PROFILE_DIR     │                               │
   │            └──────────────┬───────────────────┘                              │
   │                           │ reads / writes profile                          │
   └───────────────────────────┼──────────────────────────────────────────────────┘
                               ▼
                    ┌────────────────────────┐
                    │ VOLUME  $PROFILE_DIR    │ ← cookies, localStorage, IndexedDB,
                    │ (persistent identity)   │   the login session. NOT in the image.
                    └────────────────────────┘
```

Key points:

- Chromium binds CDP to **loopback only** (`127.0.0.1:CDP_INTERNAL_PORT`). `socat` is the *only* thing that re-exposes it on `:CDP_PORT`, so the bridge — not Chrome — controls who reaches CDP (and is where the WebSocket is hardened, below).
- The browser is **one persistent process**. Its lifecycle is **never** tied to a VNC session; closing the noVNC tab does not touch Chromium.
- The profile is the only stateful thing, and it lives on the volume.

## Configuration (all env-driven)

| Env | Default | Purpose |
|-----|---------|---------|
| `PROFILE_DIR` | `/data` | Chromium `--user-data-dir`. **Mount a volume here** — this is the persistent identity. |
| `DISPLAY` | `:99` | Xvfb display Chromium renders into. |
| `CDP_PORT` | `9222` | Public-facing CDP port that `socat` listens on. |
| `CDP_INTERNAL_PORT` | `9223` | Loopback port Chromium actually binds CDP to. |
| `NOVNC_PORT` | `6080` | noVNC / websockify HTTP port for the one-time human login. |
| `VNC_PORT` | `5900` | x11vnc RFB port behind noVNC. Usually not exposed directly. |
| `SCREEN` | `1440x900x24` | Xvfb geometry `WxHxDEPTH` (also drives the window size). |
| `CHROME_EXTRA_FLAGS` | `""` | Extra Chromium flags, appended verbatim (e.g. `--lang=en-US --proxy-server=...`). |
| `VNC_PASSWORD` | `""` | Empty → `-nopw` (open!). Set → `-rfbauth` via `x11vnc -storepasswd`. **Set this.** |

Defaults are a **drop-in** for the prior single-purpose chrome pod: profile at `/data`, CDP on `9222` (socat → `9223`), noVNC on `6080`.

## Quickstart (docker run)

```sh
docker build -t scry .

docker run --rm \
  --shm-size=1g \
  -e VNC_PASSWORD='change-me' \
  -p 127.0.0.1:6080:6080 \      # noVNC — login UI   (bind to localhost!)
  -p 127.0.0.1:9222:9222 \      # CDP — agent control (bind to localhost!)
  -v scry-profile:/data \
  scry
```

Then:

1. **Log in once.** Open `http://127.0.0.1:6080/`, enter `VNC_PASSWORD`, and use the real Chromium to sign into your target site(s). MFA, captchas, consent banners — all fine, you're a human at a keyboard. `/` auto-connects, scales to fit, and derives the WebSocket scheme from the page (`https→wss`, `http→ws`) so it works both via `port-forward` and behind a TLS ingress; `/vnc.html` is the full manual UI.
2. **Drive it from an agent.** Point any CDP client at `http://127.0.0.1:9222`:
   ```sh
   curl -s http://127.0.0.1:9222/json/version   # sanity check
   ```
   Then attach Puppeteer / Playwright / chromedp via the WebSocket debugger URL from `/json/version`.

The session survives container restarts as long as the `scry-profile` volume is intact (see the cookie-durability caveat below).

> `--shm-size=1g` avoids Chromium crashes from a tiny default `/dev/shm`. The image also runs with `--disable-dev-shm-usage` as a belt-and-suspenders fallback.

## Kubernetes (StatefulSet)

A `StatefulSet` gives you a stable identity + a `PersistentVolumeClaim` for the profile — exactly what a logged-in browser wants. **Probe tuning is load-bearing here** (see "CDP-stability hardening"): a bare-TCP probe with a low `failureThreshold` is what killed a real pod mid-session.

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: scry
spec:
  serviceName: scry
  replicas: 1                       # one identity per StatefulSet; scale by adding more, not replicas
  selector:
    matchLabels: { app: scry }
  template:
    metadata:
      labels: { app: scry }
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: scry
          image: ghcr.io/dataplanelabs/scry:latest
          ports:
            - { name: cdp,   containerPort: 9222 }
            - { name: novnc, containerPort: 6080 }
          env:
            - { name: PROFILE_DIR, value: /data }
            - name: VNC_PASSWORD
              valueFrom:
                secretKeyRef: { name: scry-vnc, key: password }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: ["ALL"] }
          volumeMounts:
            - { name: profile, mountPath: /data }
            - { name: dshm,    mountPath: /dev/shm }   # back --shm-size with a Memory emptyDir
          # --- PROBES: see guidance below. Do NOT shrink these thresholds. ---
          startupProbe:               # give Chromium + Xvfb + first profile load time to come up
            tcpSocket: { port: cdp }
            periodSeconds: 10
            failureThreshold: 18      # ~180s grace for cold start / first login
          livenessProbe:              # bare TCP + GENEROUS threshold — a low one evicted a busy pod
            tcpSocket: { port: cdp }
            periodSeconds: 30
            failureThreshold: 6       # ~3 min of sustained misses before a restart
          readinessProbe:
            tcpSocket: { port: cdp }
            periodSeconds: 10
            failureThreshold: 3
      volumes:
        - name: dshm
          emptyDir: { medium: Memory, sizeLimit: 1Gi }
  volumeClaimTemplates:
    - metadata: { name: profile }
      spec:
        accessModes: [ReadWriteOnce]
        resources:
          requests: { storage: 2Gi }
```

### Probe guidance (read this before tuning)

The pod-killing incident was caused by an aggressive bare-TCP liveness probe with a low threshold: a transient blip restarted the pod and **destroyed the in-memory login session**. The TCP-on-CDP probe only proves the `socat` listener is up — it does **not** prove Chrome is healthy, which is the point: you want it conservative.

- **`startupProbe` ~180s** (`periodSeconds: 10 × failureThreshold: 18`). Chromium + the profile + Xvfb can take a while; don't let liveness fire during cold start.
- **`livenessProbe` bare TCP, `failureThreshold >= 6`, `periodSeconds: 30`.** A generous threshold tolerates the CDP WebSocket churn this image used to exhibit and the slow answers of a Chrome under load.
- **Tradeoff vs `httpGet: /json/version`.** An HTTP probe proves CDP actually *responds*, but a busy Chrome (mid-navigation, heavy page) can be slow to answer and the probe will then **kill a perfectly healthy browser**. Prefer **bare TCP + generous threshold**. If you do use `httpGet`, keep the same generous thresholds.

## CDP-stability hardening (trace-learned)

Symptom from a real trace (`019e7733`): the agent logged "browser connection lost, reconnecting" before **every** CDP action — the persistent CDP WebSocket was being dropped between calls — and a bare-TCP liveness probe with a low threshold once **restarted the pod**, destroying the in-memory session. The image hardens against all three:

### 1. Keep the CDP socket alive across idle gaps

The persistent browser WebSocket sits idle between agent actions. A naive `socat` bridge closes idle sockets, which surfaces as constant reconnects. Enable TCP keepalive on **both** legs and disable the idle close:

```sh
socat \
  TCP-LISTEN:9222,fork,reuseaddr,keepalive,keepidle=30,keepintvl=10,keepcnt=3 \
  TCP:127.0.0.1:9223,keepalive
```

- `keepalive,keepidle=30,keepintvl=10,keepcnt=3` — start probing after 30s idle, probe every 10s, drop only after 3 missed probes. Keeps a genuinely-idle-but-healthy CDP socket open instead of tearing it down between actions.
- Tune `socat -T` (idle/inactivity timeout) carefully — a quiet CDP WebSocket is the *normal* state, not a dead one. Use `-T 0` (or a value large enough that it never cuts an idle CDP socket).

### 2. Chromium flags that reduce crashes / instability

```
--disable-dev-shm-usage                   # avoid /dev/shm OOM crashes in containers
--disable-gpu                             # no GPU in the container; software render
--disable-background-timer-throttling     # don't throttle timers when "backgrounded"
--disable-backgrounding-occluded-windows  # the headful window is always occluded → don't pause it
--disable-renderer-backgrounding          # keep the renderer at full priority (we drive it via CDP)
```

The image runs Chromium as a **non-root uid (1000) with its renderer sandbox enabled** — there is **no `--no-sandbox`**. That requires the host/node to allow unprivileged user namespaces (`kernel.unprivileged_userns_clone=1`); on K8s set the pod `securityContext` to that uid and pre-own `PROFILE_DIR` (see Security). Dropping `--no-sandbox` also removes Chrome's "you are using an unsupported command-line flag" infobar that some sites (e.g. Google) react to.

The three `*-background*` flags matter specifically because this is a *headful but never-foreground* browser: Chrome would otherwise treat the window as backgrounded and throttle/suspend it, which looks like instability to the agent.

### 3. One long-lived Chromium, never tied to VNC

- Exactly **one** Chromium process for the container's life. Its lifecycle is independent of any VNC connection — closing noVNC must not kill the browser.
- The entrypoint clears a stale `SingletonLock` in `PROFILE_DIR` on startup (left behind by an unclean shutdown) so Chromium can re-open the existing profile.
- The entrypoint ends with `wait $CHROMIUM_PID` — only a real Chromium exit ends the container, so the container's health tracks the browser, not a wrapper script.

### 4. Session-cookie durability (caveat)

A long-lived Chromium keeps the login partly **in memory**, so the real durability strategy is **avoid restarts** (hence the generous probes above).

- `--user-data-dir=$PROFILE_DIR` (mount it on a volume) persists **most** cookies, localStorage, IndexedDB, and credentials across restarts.
- But **session-scoped cookies** (no expiry, cleared on browser close) live only in memory — an unexpected restart loses them and may force a re-login.
- Mitigation: persist `PROFILE_DIR` on a volume **and** keep probes lenient so Chromium isn't restarted out from under an active session. If a site logs you out after a restart, re-authenticate once via noVNC — the rest of the profile is intact.

## Security

**CDP is remote code execution.** Anyone who can reach `:9222` can navigate to `file://` URLs, read/write the logged-in session, **exfiltrate cookies**, run arbitrary JavaScript as the authenticated user, and pivot from there. noVNC is full interactive control of the same browser. Treat both as **root-equivalent access to every account this browser is logged into.**

- **NEVER expose CDP (`:9222`) or noVNC (`:6080`) publicly.** No Ingress, no LoadBalancer, no public `-p 0.0.0.0:...`. Bind to `127.0.0.1` for `docker run`; use a `ClusterIP` Service (never `LoadBalancer`/`NodePort`) in K8s and reach the ports via `kubectl port-forward` or an in-cluster sidecar.
- **Run behind a NetworkPolicy.** Default-deny ingress to the pod; allow only the specific agent workload(s) that need CDP, and only the human-login path to noVNC. CDP has **no authentication of its own** — network isolation *is* its access control.
- **Set `VNC_PASSWORD`.** Unset means the noVNC login screen is open (`-nopw`). It is the only auth gate in front of interactive control.
- **Runs non-root with the sandbox ON.** The container starts Chromium as uid 1000 and keeps the renderer sandbox (no `--no-sandbox`). This needs a node that allows unprivileged user namespaces (`kernel.unprivileged_userns_clone=1`); verify before deploying. On K8s, set `securityContext.runAsUser: 1000` and chown `PROFILE_DIR` to it (an init-container `chown -R 1000:1000 /data` handles an existing root-owned volume). If a locked-down node blocks the namespace sandbox the container will crashloop — only then fall back to `--no-sandbox` via `CHROME_EXTRA_FLAGS`, and only inside a confined pod (dropped caps, `allowPrivilegeEscalation: false`, seccomp, dedicated namespace, the NetworkPolicy above).
- **No secrets in the image.** The login and cookies live **only** on the runtime `PROFILE_DIR` volume, created when a human logs in via noVNC. The image ships **zero** credentials — anyone who pulls it gets an *empty* browser. The identity lives with the volume, so guard the volume (and its backups/snapshots) like the credentials they effectively are.
