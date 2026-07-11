# Controller-side caching proxy — the single audited egress choke point (PKG-6)

> **Demand-gated.** This is the heavier tier of package provisioning. The default posture is the
> curated allowlist + install-then-relock (PKG-1..5, see
> [package-provisioning-security.md](package-provisioning-security.md)). Turn the proxy on only when
> you want **one auditable egress path** for packages, **reproducibility under K**, or a path toward
> **air-gapped workers** — not by default.

## What it is

A **pull-through package cache** (default [Nexus OSS](https://help.sonatype.com/) all-in-one) runs on
the **controller's inner dockerd**, root-owned exactly like the CC-2 worker broker. Once on, it is the
**only** host on the fleet that reaches the public registries. Every worker:

- points its package managers (`npm`, `pip`, `go`, `apt`) at the proxy, and
- has its egress firewall **narrowed to just the proxy** — the public npm registry is dropped and the
  curated PKG-1 / PKG-4 public registries are not added.

So every package fetch is a **single, auditable hop** through the proxy, second-and-later fetches are
**cache hits** (fast + reproducible across K workers and restarts), and there is exactly one external
fetcher to log/monitor.

```
                         ┌─────────────── controller (Sysbox) ───────────────┐
   public registries ◀───┤  claude-cache-proxy  (root, inner dockerd)         │
   (npm/PyPI/Go/apt)      │        ▲            └─ claude-cache-net ─┐         │
   — the ONLY egress ─────┤        │  cache hit                      │        │
                          │   worker A ──── worker B ──── worker C ──┘        │
                          │   (egress narrowed to the proxy; no public reg)   │
                          └───────────────────────────────────────────────────┘
```

## Enable it

Set `CLAUDE_CACHE_PROXY=1` on the **controller** (alongside `CLAUDE_CONTROLLER=1` /
`CLAUDE_WORKER_BROKER=1`) **and** run workers under egress lockdown:

```bash
CLAUDE_CONTROLLER=1 CLAUDE_CACHE_PROXY=1 CLAUDE_EGRESS_LOCKDOWN=1 \
  ./bin/claude-launch cockpit --repo git@github.com:cosyte/<umbrella>.git
```

- On the controller, `entrypoint.sh` §5d runs `claude-cache-proxy start` and **blocks until it is
  `ready`** before dispatching workers (fail-closed — see below).
- The CC-2 broker forwards `CLAUDE_CACHE_PROXY=1` + `CLAUDE_CACHE_PROXY_HOST` into every worker and
  joins it to the shared `claude-cache-net`, so the worker reaches the proxy by name.
- Each worker's `entrypoint.sh` (§10c) runs `claude-cache-proxy client-apply` **before** the egress
  lockdown narrows its egress to the proxy.

`CLAUDE_EGRESS_LOCKDOWN=1` is what actually delivers the single-choke-point guarantee. Without it the
worker still points its managers at the proxy, but its egress is not narrowed — it could reach a public
registry directly. The entrypoint logs a warning in that case.

Under lockdown the firewall opens the proxy's **own port** (default `8081`, not just 22/80/443) to
**only** the proxy's IPs — the pinned host + port are derived from the same source `claude-cache-proxy`
dials (`CLAUDE_CACHE_PROXY_URL` if set, else `CLAUDE_CACHE_PROXY_HOST` + `CLAUDE_CACHE_PROXY_PORT`), so
the host the worker reaches and the host the firewall pins can never diverge. If the proxy host can't be
resolved when the firewall applies, its port is **not** opened and the worker's `client-apply` then
fail-closes — never an open-egress fallback.

## Fail-closed (the whole point)

> **Proxy down → provision refused, never a silent fallback to open/public-registry egress.**

- `claude-cache-proxy ready` polls the proxy's health endpoint and returns success **only** on a
  **2xx** response. An unreachable proxy (connect failure → HTTP `000`), a **3xx** (a mid-startup
  redirect-to-login on a Nexus context path — up but not yet serving repositories), a 5xx, or a bad
  timeout config all return failure — "unknown" is never treated as "ready". If your deployment fronts
  the health path behind a redirect, point `CLAUDE_CACHE_PROXY_HEALTH_PATH` at a 200 endpoint.
- On the **controller**, if the proxy can't start or become ready within
  `CLAUDE_CACHE_PROXY_READY_TIMEOUT`, the controller **refuses to start** — a fleet whose choke point is
  absent never comes up.
- In a **worker**, `client-apply` runs the ready gate **first** and **dies** (refusing to start the
  agent) if the proxy is unreachable. It writes no package-manager config on that path, so there is no
  half-applied state a public-registry fallback could use.

## Commands

```bash
claude-cache-proxy start         # (root, controller) launch the proxy on the inner dockerd — idempotent
claude-cache-proxy stop          # stop + remove the proxy (the cache volume is retained)
claude-cache-proxy status        # exit 0 iff the proxy container is running
claude-cache-proxy ready         # exit 0 iff the proxy's health endpoint answers (the fail-closed gate)
claude-cache-proxy url           # print the resolved base URL
claude-cache-proxy client-env    # print the per-ecosystem endpoints as KEY=VALUE (the worker contract)
claude-cache-proxy client-apply  # (in a worker) point npm/pip/go/apt at the proxy; refuse if it is down
claude-cache-proxy print-config  # dry-run: print the resolved launch plan + endpoints, touch nothing
```

## Configuration

| Env | Default | Meaning |
|---|---|---|
| `CLAUDE_CACHE_PROXY` | `0` | Master enable. The flag the controller / broker / worker entrypoint gate on. |
| `CLAUDE_CACHE_PROXY_IMAGE` | `sonatype/nexus3:latest` | The proxy image. Swap for a per-ecosystem set + matching endpoint paths if preferred. |
| `CLAUDE_CACHE_PROXY_NAME` | `claude-cache-proxy` | Proxy container name. |
| `CLAUDE_CACHE_PROXY_NET` | `claude-cache-net` | Shared docker network the proxy + every worker join. |
| `CLAUDE_CACHE_PROXY_VOLUME` | `claude-cache-proxy-data` | Persistent cache volume (survives restarts). |
| `CLAUDE_CACHE_PROXY_PORT` | `8081` | Proxy port (Nexus default). |
| `CLAUDE_CACHE_PROXY_HOST` | *(container name)* | Host workers reach the proxy at — **the one host the worker egress firewall pins.** |
| `CLAUDE_CACHE_PROXY_URL` | `http://$HOST:$PORT` | Full base URL override. |
| `CLAUDE_CACHE_PROXY_MEM` / `_CPUS` | `2g` / `2` | Proxy resource caps (Nexus is heavy). |
| `CLAUDE_CACHE_PROXY_HEALTH_PATH` | `/service/rest/v1/status` | Health endpoint (Nexus status API). |
| `CLAUDE_CACHE_PROXY_READY_TIMEOUT` | `120` | Seconds to wait for `ready`. |
| `CLAUDE_CACHE_PROXY_{NPM,PYPI,GO,APT}_PATH` | Nexus repository paths | Per-ecosystem endpoint paths — adjust for a per-ecosystem proxy set. |

The defaults target a single-container Nexus OSS. To use the per-ecosystem set (Verdaccio npm · devpi
PyPI · Athens Go · apt-cacher-ng) point `CLAUDE_CACHE_PROXY_*_PATH` (and typically run each behind one
reverse proxy so `CLAUDE_CACHE_PROXY_HOST` stays a single pinned host — the choke-point property depends
on one egress host).

## On-host verification (the manual gate)

The unit tests (`test/cache-proxy-unit.sh`, in CI) prove the **logic** docker-free: the fail-closed ready
gate, the `client-apply` refusal, the single-choke-point egress composition, and the broker/worker
wiring. The **live** proof needs a Sysbox host + a real proxy and is the manual gate:

1. Launch a controller with `CLAUDE_CACHE_PROXY=1 CLAUDE_EGRESS_LOCKDOWN=1`; confirm the proxy comes up
   and `claude-cache-proxy ready` succeeds.
2. Dispatch a worker; confirm it installs across ecosystems (`npm i`, `pip install`, `go get`) **through
   the proxy** and that the proxy is the **sole external fetcher** (the worker's egress allows only the
   proxy IP).
3. Dispatch a **second** worker for the same packages; confirm cache hits (no new public fetch).
4. Stop the proxy, dispatch a worker; confirm it **refuses to provision** (no fallback to open egress).

## Known limitations / non-goals

- **Not air-gapped yet.** The worker still reaches Claude API/OAuth + **GitHub** (git clone, `github:` /
  `aqua:` mise installs, non-proxied `go get` from GitHub) via the base allowlist — pinned, audited
  hosts, but not the proxy. The proxy fronts the **registry** ecosystems (npm/PyPI/Go-module-proxy/apt);
  fronting GitHub too (Nexus raw/proxy, Athens for Go-from-GitHub) is a follow-up toward true air-gap.
- **apt is not auto-configured.** `client-apply` auto-points **npm/pip/go** at the proxy (their
  registry-path model is uniform), but **not apt** — the correct apt redirection depends on the proxy
  type and can't be guessed: a Nexus apt *hosted-repo* (the default) needs `sources.list` rewritten to
  the repo path (`$CLAUDE_CACHE_PROXY_URL/repository/apt/`, advertised via `claude-cache-proxy
  client-env`), while an apt-cacher-ng *forward* cacher needs `Acquire::http::Proxy`. Writing one form
  blindly would be wrong (and silently a no-op) for the other and ignores HTTPS apt sources. The
  supported curated-apt story remains **PKG-4** (`CLAUDE_APT_PROVISION`); wiring apt through the proxy is
  left to the operator per their proxy type.
- **Proxy URL shape.** `CLAUDE_CACHE_PROXY_URL` is expected to be `http[s]://host[:port]` — the
  documented internal shape. A URL with embedded userinfo (`user:pw@`) or an IPv6-literal host
  (`http://[::1]:8081`) is not parsed for the firewall pin / pip trusted-host; use a plain hostname or
  IPv4 for the internal cache endpoint.
- **Controller sizing.** The proxy is an **additional** container on the controller with its own
  footprint (`CLAUDE_CACHE_PROXY_MEM`/`_CPUS`); the CC-3 `controller_envelope` sizes for K workers +
  overhead and does **not** yet account for the proxy. Add headroom on a proxy-mode controller (a
  follow-up: fold the proxy footprint into `claude-controller-size`).
- **HTTP internal endpoint.** The proxy is reached over plain HTTP on the internal docker network
  (`pip` trusts the host explicitly). Fine for an internal, root-owned, single-network hop; not exposed
  to a host port.
