# Claude Code container

Self-hosted Docker image for running multiple isolated, long-lived Claude Code
sessions on a homelab box. One container = one session = one git repo, reachable
two ways at once: SSH into a persistent tmux session, and the Claude mobile
app's Remote Control (Code tab).

Auth is your Claude **Max** subscription via OAuth. No API keys — the entrypoint
hard-fails if `ANTHROPIC_API_KEY` is set so you never accidentally bill per
token.

## Quick start

```bash
cp .env.example .env          # edit if you want; defaults are sane
make build                    # builds the image for this host's arch
make login                    # one-time OAuth — opens a URL, you paste a code
./bin/claude-launch first-project --repo git@github.com:you/first-project.git
```

`claude-launch` prints the exact SSH command and the name to look for in the
app. SSH in and you're dropped straight into the running Claude session:

```
ssh -p 2200 claude@your-homelab
```

Open the Claude mobile app → Code tab → `first-project` has a green dot.

Stop and resume later without losing the workspace or conversation history:

```bash
./bin/claude-stop  first-project
./bin/claude-launch first-project       # resumes; no --repo needed
```

Run as many in parallel as you like — each gets its own SSH port and app
session. `./bin/claude-list` shows them all. Put `bin/` on your `PATH` to drop
the `./bin/` prefix.

## Architecture

```
 host                                   container: claude-<project>
 ┌────────────────────────┐             ┌──────────────────────────────────┐
 │ ./bin/claude-launch ───┼── docker ──▶│ entrypoint.sh (root)             │
 │                        │   run -d    │   ├─ refuse ANTHROPIC_API_KEY     │
 │ ssh -p 22NN ───────────┼────────────▶│   ├─ sshd  (port 22 ⇄ host 22NN) │
 │                        │             │   ├─ merge baked-in config       │
 │                        │             │   ├─ clone / use /workspace      │
 │                        │             │   └─ gosu claude ▶ tmux "claude" │
 │                        │             │            └─ claude \           │
 │                        │             │                 --dangerously-   │
 │                        │             │                 skip-permissions │
 │                        │             │                 --remote-control │
 │                        │             │                 "<project>"      │
 └────────────────────────┘             └───────┬──────────────────────────┘
                                                 │ outbound HTTPS only
 Claude mobile app  ◀───── Remote Control ───────┘  (no inbound port)

 volumes:
   claude-auth          (shared)  OAuth credentials   → /auth
   claude-sshkeys       (shared)  SSH host keys        → /etc/ssh/host-keys
   claude-config-<proj> (per ctr) sessions + state     → /home/claude/.claude
   claude-ws-<proj>     (per ctr) the git repo         → /workspace
```

Why credentials and config are split: a single shared `~/.claude` across
containers would corrupt concurrent sessions and collide on the `/workspace`
project key. Credentials are shared (one login, all containers); per-container
config keeps sessions independent and resumable. The entrypoint keeps the
credentials file converged across containers. Details and the deviation
rationale: [docs/architecture.md](docs/architecture.md).

## Unattended autopilot

A container has two modes, selected by `CLAUDE_AUTOPILOT`:

- **interactive** (default) — the main tmux pane is a Remote Control + SSH
  session (`claude-session`), as above.
- **autopilot** (`CLAUDE_AUTOPILOT=1`) — the main pane instead runs a **headless
  Claude loop** (`claude-autopilot`): every `CLAUDE_AUTOPILOT_INTERVAL` seconds
  it fires `claude -p "$CLAUDE_AUTOPILOT_CMD"` (default `/next`) and prints the
  result. No Remote Control link (the watchdog is skipped); SSH still attaches
  to the live pane so you can watch it. Each run is a fresh session — perfect for
  a session-independent command like `/next` that recovers its state from disk.

Point one autopilot container at a repo whose continuous-build command you want
run hands-off:

```bash
CLAUDE_AUTOPILOT=1 CLAUDE_AUTOPILOT_CMD=/next CLAUDE_AUTOPILOT_INTERVAL=3600 \
  ./bin/claude-launch cockpit --repo git@github.com:cosyte/<umbrella>.git
```

On a rate/usage-limit failure the loop parses the actual reset time (from the
run output or a reset epoch in the JSON) and sleeps until then — better shared-
quota throughput than blind waiting — and falls back to exponential backoff (up
to `CLAUDE_AUTOPILOT_BACKOFF_MAX`, default 6h) when no reset time is found, so a
hot error loop still can't burn your quota. Each run logs its `total_cost_usd`
(plus turns and duration) so the shared subscription's spend is attributable per
container. Per-run JSON logs land in `CLAUDE_AUTOPILOT_LOG_DIR` (default
`~/.claude/autopilot-logs`); `claude-logs` still shows the entrypoint/sshd log.

By default each cycle is a fresh session (suits session-independent commands
like `/next` that recover state from disk). Set `CLAUDE_AUTOPILOT_RESUME=1` to
instead carry the exact conversation forward via `--resume <session_id>` (the ID
is captured from each run's JSON and persisted on the container's config volume)
— use it for a single stateful long-running task rather than a queue-driven one.

**Durable task queue.** A blind timer is the wrong primitive for fleet work, so
`CLAUDE_AUTOPILOT_QUEUE=1` turns the loop into a queue consumer: it claims the
oldest pending prompt file (atomic `mv`, so it's restart- and race-safe), runs it
as a one-shot task, and files it under `done/` or `failed/`. When the queue
drains it falls back to `CLAUDE_AUTOPILOT_CMD` (`/next`) on the interval — so a
queued container is *also* a continuous-build container. Enqueue from inside the
container (SSH in, then):

```bash
claude-enqueue "Upgrade the lockfile and make the tests pass"
echo "Triage the failing CI run and open a fix PR" | claude-enqueue
claude-enqueue --priority 0 "Urgent: patch the CVE in deps"   # lower = sooner
```

The queue lives on the per-container config volume (`~/.claude/autopilot-queue/`)
so it survives restarts; `CLAUDE_AUTOPILOT_QUEUE_DELAY` (default 10s) paces tasks
while draining.

**Event-driven routing.** `CLAUDE_SCM_OBSERVER=1` runs a poller (tmux window
`scm`) that turns the queue from pull to push: every `CLAUDE_SCM_INTERVAL`
(default 300s) it lists the workspace repo's open PRs via `gh` and enqueues a
task for each **new** actionable event — a failing CI check, a *changes
requested* review, or a merge conflict — so the container reacts to repo events
instead of only a clock. Events are keyed by PR + head commit, so a given
failure is routed once and re-fires only when new commits land (never every
poll). Polling (not webhooks) keeps the outbound-only posture — no inbound port.
Choose signals with `CLAUDE_SCM_EVENTS=ci,review,conflict`, scope with
`CLAUDE_SCM_PR_FILTER` (e.g. `--author @me`); it needs a GitHub remote and, for
private repos, `GH_TOKEN`. Pair it with `CLAUDE_AUTOPILOT=1` +
`CLAUDE_AUTOPILOT_QUEUE=1` so the same container consumes what it observes.

**Fleet observability.** Set `CLAUDE_OTEL_ENABLED=1` (or just an
`OTEL_EXPORTER_OTLP_ENDPOINT`) to export Claude Code's native per-call cost/token
telemetry to any OpenTelemetry backend — Langfuse, an OTel collector, Grafana.
Each container is tagged `service.instance.id=<project>` so the fleet view
separates agents, and the auth header stays in process env (never written to the
config volume). `CLAUDE_OTEL_TRACES=1` adds the (beta) trace export that
trace-first backends like Langfuse need. Full var list in `.env.example`.

**Auth + quota.** Autopilot uses the same Max-subscription OAuth as every other
container (the entrypoint refuses `ANTHROPIC_API_KEY`). A single Max plan is
shared across all running containers via the converged `claude-auth` volume, so
mind the plan's 5-hour and weekly limits when choosing the interval and how many
autopilot containers run at once — a too-tight cadence exhausts the subscription.

**Controller mode** (`CLAUDE_CONTROLLER=1`, CC-6) is a third main-pane mode, for a
Sysbox-nested controller that also dispatches nested workers via the umbrella's
`PAR-*` lease/scheduler/bump-worker control plane instead of just running `/next`
in-process. Its effective worker slots default to `1` — which collapses it,
byte-identical, to exactly the autopilot loop above — and only ramp past that on
an explicit `CLAUDE_CONTROLLER_MAX_SLOTS` override once the umbrella's `PAR-4.1`
and `PAR-7.1` land. See `docs/substrate.md`'s "Controller mode (CC-6)" section for
the full design; most containers should keep using plain `CLAUDE_AUTOPILOT=1`.

## Environment variables

Set in `.env` (auto-loaded by the scripts and passed into containers). Real env
vars override `.env`. Full reference: `.env.example`.

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDE_IMAGE` | `claude-code-box:latest` | Image tag built/run |
| `CLAUDE_CODE_VERSION` | `2.1.144` | Pinned Claude Code npm version (min 2.1.52) |
| `NODE_VERSION` | `24` | Base Node LTS |
| `UV_VERSION` | `latest` | `uv` version (pin for reproducibility) |
| `PNPM_VERSION` | `latest` | `pnpm` version baked in (pin for reproducibility) |
| `CLAUDE_UID`/`CLAUDE_GID`/`CLAUDE_USER` | `1000`/`1000`/`claude` | Container user |
| `CLAUDE_MODEL` | `opus` | Model the session runs. Defaults to the best available model (the `opus` alias always resolves to the latest Opus). Any Claude Code alias (`opus`/`sonnet`/`haiku`/`opusplan`/`default`) or a full id like `claude-opus-4-8`; `default` defers to Claude Code's pick. Per-container via `claude-launch --model`, per-repo via `claude-compose-gen --model REPO=MODEL`. Honored by both the interactive session and autopilot |
| `CLAUDE_PERMISSION_MODE` | `bypassPermissions` | `default`/`acceptEdits`/`plan`/`bypassPermissions`. Honored by both the interactive session and autopilot; `acceptEdits` is the safer fleet posture (gates shell/network) |
| `CLAUDE_SECRET_GUARD` | `1` | `1` installs a fleet-wide git pre-commit hook that blocks committing secrets (`.env`, `*.pem`, `*.key`, `id_rsa`, PRIVATE KEY blocks). Bypass once with `git commit --no-verify`; extend via `CLAUDE_SECRET_GUARD_EXTRA` |
| `CLAUDE_AUTOPILOT` | `0` | `1` = unattended mode: main pane runs a headless `claude -p` loop instead of Remote Control (see [Unattended autopilot](#unattended-autopilot)) |
| `CLAUDE_AUTOPILOT_CMD` | `/next` | What the autopilot loop runs each cycle |
| `CLAUDE_AUTOPILOT_INTERVAL` | `3600` | Seconds between successful autopilot runs |
| `CLAUDE_AUTOPILOT_MAX_RUNS` | `0` | Stop after N autopilot runs (`0` = unlimited) |
| `CLAUDE_AUTOPILOT_RESUME` | `0` | `1` = carry the conversation forward via `--resume <session_id>` each cycle instead of a fresh session |
| `CLAUDE_AUTOPILOT_QUEUE` | `0` | `1` = consume prompt files from a durable task queue (`claude-enqueue`), falling back to `/next` when empty (see [Unattended autopilot](#unattended-autopilot)) |
| `CLAUDE_SCM_OBSERVER` | `0` | `1` = poll the repo's PRs via `gh` and route CI failures / change requests / merge conflicts into the queue (`CLAUDE_SCM_*` tune it; see `.env.example`) |
| `CLAUDE_OTEL_ENABLED` | `0` | `1` (or setting `OTEL_EXPORTER_OTLP_ENDPOINT`) exports Claude Code's per-call cost/token telemetry to an OTLP backend, tagged per container. `CLAUDE_OTEL_TRACES=1` adds traces; see `.env.example` for the `OTEL_*` vars |
| `CLAUDE_EXTRA_ARGS` | — | Extra args to `claude` (or `--extra-args`) |
| `CLAUDE_MCP_ENABLED` | — | CSV of baked MCP servers to load (empty = all) |
| `WITH_BROWSER` | `0` | Build arg: 1 bakes Chromium + chrome-devtools-mcp (+~200 MB). `make build-browser` flips it. |
| `CLAUDE_BROWSER` | auto | Tri-state for the chrome-devtools MCP: unset = auto (a browser image self-enables it), `1`/`--browser` = force on (fails loud on a lean image), `0`/`--no-browser` = opt out. |
| `GIT_REPO_URL`/`_BRANCH`/`_DEPTH` | — | Clone source (or use `--repo`/`--branch`/`--depth`) |
| `GIT_AUTHOR_NAME`/`_EMAIL` (+`COMMITTER`) | host git config | Commit identity |
| `GIT_SSH_KEY` | `~/.ssh/claude-git-key` | Host SSH key for git, mounted read-only |
| `SSH_AUTHORIZED_KEYS` | `~/.ssh/authorized_keys` | Host pubkeys allowed to SSH in (read-only) |
| `SSH_PORT_RANGE_START`/`_END` | `2200`/`2299` | Auto-assigned host SSH port range |
| `CLAUDE_SSH_HOST` | this host's name | Hostname shown in the connect line |
| `CLAUDE_SSH_BIND` | — | Bind the SSH port to one host interface (e.g. `127.0.0.1`); empty = all |
| `CLAUDE_CPU_LIMIT`/`CLAUDE_MEM_LIMIT` | `2`/`4g` | Per-container resource caps |
| `CLAUDE_MEM_RESERVATION` | 75% of `CLAUDE_MEM_LIMIT` | Soft memory floor (`--memory-reservation`) |
| `CLAUDE_PIDS_LIMIT` | `2048` | Fork-bomb guard (`--pids-limit`) |
| `CLAUDE_SHM_SIZE` | `2g` | `/dev/shm` size |
| `CLAUDE_HARDEN_CAPS` | `1` | `1` = `--cap-drop ALL` + minimal `--cap-add` (drops NET_RAW/MKNOD/SETFCAP); `0` = Docker defaults. `no-new-privileges` is always set. Override the set with `CLAUDE_MIN_CAPS` |
| `CLAUDE_EGRESS_LOCKDOWN` | `0` | `1` = default-deny network firewall (iptables, IP-pinned allowlist) applied at boot before the unprivileged agent starts. Extend with `CLAUDE_EGRESS_EXTRA_HOSTS`. Fail-open on error |
| `CLAUDE_EGRESS_PACKAGES` | `0` | `1` = additively allowlist the curated **package registries** (PyPI, crates.io, Go proxy, `mise.run`, `ghcr.io`) so agent-driven `pip`/`cargo`/`go`/`mise` installs work under lockdown. Opt-in and curated (not open); nothing else broadens. Debian/apt system libs are **not** here (they need the rootful worker tier). See [docs/package-provisioning-security.md](docs/package-provisioning-security.md) |
| `CLAUDE_BROKER_GIT_KEY` | `0` | `1` = hold the SSH deploy key in a root ssh-agent (agent signs/pushes but can't read the key bytes) instead of a readable `~/.ssh/id_ed25519` |
| `CLAUDE_WORKER_UMBRELLA` | `/workspace` (if it looks right) | Umbrella root override for `claude-worker-run` — must have both `.gitmodules` and `scripts/isolate.sh`; refuses (fail closed) otherwise |
| `CLAUDE_WORKER_HEARTBEAT_SECS` | `60` | Seconds between `claude-worker-run`'s best-effort `scripts/lease.sh renew` calls |
| `CLAUDE_REAPER_INTERVAL` | `300` | Seconds between `claude-reaper --loop` cycles (controller mode) |
| `CLAUDE_REAPER_SPOOL_TTL` | `3600` | Seconds before an orphaned broker-spool file (`responses/`, `requests/`, `staging/`) is pruned by `claude-reaper` |
| `CLAUDE_DISK_FLOOR_MIB` | `10240` | Free-space floor (MiB) on `CLAUDE_DISK_DATA_ROOT`; the broker refuses a launch below it |
| `CLAUDE_DISK_DATA_ROOT` | `/var/lib/docker` | The inner dockerd data-root nested worker layers land on — what the disk floor and `claude-disk-gc` watch |
| `CLAUDE_DISK_GC_INTERVAL` | `3600` | Seconds between `claude-disk-gc --loop` cycles (controller mode) |
| `CLAUDE_CONTROLLER` | `0` | `1` = controller mode (CC-6): main pane runs `claude-controller`, wiring this substrate to the umbrella `PAR-*` lease/scheduler/bump-worker. Implies `CLAUDE_WORKER_BROKER=1` (refuses at boot if that's explicitly `0`). Takes priority over `CLAUDE_AUTOPILOT` if both are set; no Remote Control link either way |
| `CLAUDE_CONTROLLER_MAX_SLOTS` | `1` | Ceiling on worker slots the controller may use: effective slots = `min(K, this)`. **Defaults to 1 regardless of K** — the controller never auto-ramps; raising it is a deliberate operator action gated by the umbrella's `PAR-7.1` founder ramp (and needs `PAR-4.1` first). `1` collapses to today's autopilot, byte-identical |
| `CLAUDE_CONTROLLER_UMBRELLA` | `/workspace` (if it looks right) | Umbrella root override for `claude-controller` — must have both `.gitmodules` and `scripts/reconcile.sh`; refuses (fail closed) otherwise |
| `CLAUDE_CONTROLLER_INTERVAL` | `60` | Seconds between controller dispatch cycles (the slots>1 loop) |
| `CLAUDE_CONTROLLER_SOCKET_WAIT` | `90` | Seconds the entrypoint blocks, in controller mode, for the inner docker socket to be confirmed `root:root 600` before starting the agent's tmux session |
| `CLAUDE_WORKER_RUN_LOG_DIR` | `$HOME/.claude/worker-run-logs` | Where `claude-worker-run` writes its per-run JSON log + the secret-free `run-<item>-<ts>.meta.json` sidecar `claude-fleet-view` reads for spend |
| `CLAUDE_FLEET_HOST_CPUS` / `CLAUDE_FLEET_HOST_MEM_MIB` | `nproc` / `/proc/meminfo` | Host capacity override for `claude-fleet-view`'s headroom line (test/drill seam) |
| `CLAUDE_FLEET_DOCKER` | `docker` | The docker binary `claude-fleet-view` queries for active `claude.worker=1` containers (test seam) |
| `CLAUDE_STOP_TIMEOUT` | `20` | Graceful stop timeout (s) |
| `AUTH_VOLUME`/`SSHKEYS_VOLUME` | `claude-auth`/`claude-sshkeys` | Shared volume names |
| `ANTHROPIC_API_KEY` | unset | **Must stay unset** — entrypoint hard-fails otherwise |

## Volume / mount reference

| Path in container | Source | Scope | Holds |
|---|---|---|---|
| `/auth` | `claude-auth` volume | shared | `.credentials.json` (OAuth) |
| `/etc/ssh/host-keys` | `claude-sshkeys` volume | shared | SSH host keys (stable fingerprint) |
| `/home/claude/.claude` | `claude-config-<proj>` volume | per container | Sessions, history, merged config, plugins |
| `/workspace` | `claude-ws-<proj>` volume *or* `--workspace` bind | per container | The git repo |
| `/etc/claude/authorized_keys` | host `SSH_AUTHORIZED_KEYS` | read-only | Who may SSH in |
| `/etc/claude/git-key` | host `GIT_SSH_KEY` | read-only | Git push key |
| `/opt/claude-config` | baked into image | image | Bake-in template merged on start |

Anything baked in is overridable by mounting onto the target path (e.g. mount
your own `CLAUDE.md` onto `/home/claude/.claude/CLAUDE.md`).

## Customizing the baked-in config

`claude-config/` is copied into the image and merged into `~/.claude` on start
(only filling what's absent, so per-container state is never clobbered). It
holds `CLAUDE.md`, `mcp/`, `plugins/`, `commands/`, `skills/`. MCP secrets are
**never baked** — use `${VAR}` placeholders, supply values at runtime via
`.env`. Full guide: [docs/customizing-bakeins.md](docs/customizing-bakeins.md).

## Launcher commands

```
claude-launch <name> [--repo URL | --workspace PATH] [--branch B] [--depth N]
                      [--port N] [--model NAME] [--mcp NAME ...] [--browser|--no-browser]
                      [--extra-args "…"] [--expose H:C ...] [--dev-cmd "…"]
claude-list                       table of all sessions
claude-attach <name>              attach to its live tmux session (local host)
claude-stop  <name>               graceful stop (state preserved)
claude-rm    <name> [--yes] [--purge]   remove (+volumes with --purge)
claude-logs  <name> [-n LINES]    tail the entrypoint/sshd log
claude-sysbox-verify [--check]    prove the Sysbox-nested substrate (CC-1)
claude-broker-verify [--keep]     prove the root-owned worker broker (CC-2)
claude-controller-size [--flags]  K-derived controller envelope + capacity check (CC-3)
claude-sizing-verify [--keep]     prove limits enforce inside + OOM/fork isolation (CC-3)
claude-worker-run <repo> <item>   one-shot worker driver: isolate + exactly one /work-on (CC-4)
claude-reaper [--loop]            reap dead worker containers + prune the broker spool (CC-4)
claude-worker-lifecycle-verify [--check] [--keep]   prove one-shot-then-vanish + reaping (CC-4)
claude-disk-gc [--loop]           GC the inner daemon's image/build-cache layers (CC-5)
claude-disk-verify [--check] [--keep]   prove the disk-space floor + gc + image reuse (CC-5)
claude-controller                 wire the substrate to the umbrella PAR-* lease/scheduler/bump-worker (CC-6)
claude-controller-verify [--check] [--keep]   prove controller-mode dispatch + non-double-ship (CC-6)
claude-fleet-view [--json]        per-worker item/repo/spend + host cpu/mem/disk headroom vs the K budget (CC-7)
```

Inside a controller (`CLAUDE_WORKER_BROKER=1`), the unprivileged agent asks the
root broker for a worker with `claude-worker-request <repo> <item-id>` — see
[Security notes](#security-notes).

Inside an autopilot container (over SSH), `claude-enqueue "<prompt>"` adds a task
to the durable queue (`CLAUDE_AUTOPILOT_QUEUE=1`); `--priority N` orders it
(lower runs sooner), and a prompt can also be piped on stdin.

`--expose HOST:CONTAINER` publishes an extra port (e.g. a dev server) and
`--dev-cmd` auto-starts a command on boot in a tmux `dev` window — the
single-container equivalents of `claude-compose-gen`'s `--expose`/`--dev-cmd`.
Resuming a stopped container reuses its creation-time env, ports, and mounts,
so changed `.env` values or new launch options need a `claude-rm` + relaunch.

`make launch ARGS="…"`, `make stop ARGS="…"` etc. wrap these if you prefer Make.

### Many repos at once

`claude-compose-gen` writes a multi-service `docker-compose.yml` with one
session container per repo in a GitHub org:

```
claude-compose-gen --org ORG --out FILE [--active REPOS]... [--dormant-profile NAME]
                   [--expose REPO:HOSTPORT:CONTAINERPORT]...
                   [--dev-cmd REPO=COMMAND]...
                   [--cpu REPO=N]... [--mem REPO=SIZE]... [--model REPO=MODEL]...
                   [--browser REPOS]...
                   [--marketplace REPO=NAME=URL]... [--plugin REPO=PLUGIN[,...]]...
                   [--include GLOB] [--exclude GLOB] [--forks] [--archived]
claude-compose-gen --out FILE repo-a repo-b:dev      # explicit list, no gh needed
```

`--out` must be a path **outside this repo** (a deploy location); the
generator refuses to write inside the repo. **SSH ports are stable**: when
`--out` already exists each repo keeps its previously assigned port and only
new repos take the next free one, so adding a repo never reshuffles running
containers. `--expose` publishes a dev-server port for a repo; `--dev-cmd`
auto-starts that dev server on container boot in its own tmux `dev` window.

Two gotchas the example below handles (both bit us in practice):

- The dev server must bind **`0.0.0.0`**, not localhost, or the published
  port reaches nothing inside the container.
- `npm run <script>` needs `-- ` before forwarded flags; `pnpm`/`yarn`
  forward them **without** `--` (passing a literal `--` makes Astro/Vite
  ignore `--host` and silently bind localhost). So detect the package
  manager. `pnpm`/`yarn`/`npm` are baked into the image — no runtime
  package-manager download.

Verified working example (Astro/Vite/Next dev server, any package manager):

```
claude-compose-gen --org ORG --out FILE --active my-site \
  --expose my-site:4321:4321 \
  --dev-cmd 'my-site=if [ -f pnpm-lock.yaml ]; then PM=pnpm; SEP=; elif [ -f yarn.lock ]; then PM=yarn; SEP=; else PM=npm; SEP=--; fi; [ -d node_modules ] || $PM install; exec $PM run dev $SEP --host 0.0.0.0 --port 4321'
```

Then `http://<host>:4321` serves the live dev site; SSH in and
`tmux select-window -t claude:dev` to watch its output (`claude-dev` reruns
it).

**Runtime plugin marketplaces.** `--marketplace REPO=NAME=URL` and
`--plugin REPO=PLUGIN[,…]` write `CLAUDE_EXTRA_MARKETPLACES` /
`CLAUDE_EXTRA_PLUGINS` onto a service. The entrypoint merges these into
Claude Code's `settings.json` on every boot — no image rebuild, no manual
edit. Existing `settings.json` entries win on conflict (so per-container user
choices stick). Same syntax as the single-container `claude-launch
--marketplace` / `--plugin`, with a `REPO=` prefix to say which service:

```
./bin/claude-compose-gen --org ORG --out FILE --active site \
  --marketplace site=claude-skills=git@github.com:org/crew.git \
  --plugin 'site=software-engineering@claude-skills,data@claude-skills'
```

It enumerates via an authenticated `gh` (scopes `repo` + `read:org`) or takes
explicit `repo[:branch]` args, assigns stable SSH ports from the configured
range, shares `claude-auth`/`claude-sshkeys` with per-repo config/workspace
volumes, and labels services so they still show up in `claude-list`.

**Resource-conscious by default.** `--active` marks the repos that should
start with a plain `docker compose up -d`; every other repo is still defined
but placed behind a Compose profile (`dormant`), so it consumes zero
resources until you ask for it:

```
claude-compose-gen --org ORG --out FILE --active repo-a --active repo-b,repo-c
docker compose -f FILE up -d                       # just the active ones
docker compose -f FILE up -d repo-x                # one dormant repo, on demand
docker compose -f FILE --profile dormant up -d     # everything
docker compose -f FILE stop repo-a                 # free its resources
```

With no `--active`, all repos start (backward compatible). Regenerate any time
the repo or active set changes — ports stay stable (services sorted by name),
so a repo keeps its port whether active or dormant.

## Frontend debugging (optional)

Off by default. When you want Claude to *see and drive* a frontend the agent
is building, build the browser variant — **launching on it is enough**, the
`chrome-devtools` MCP auto-enables itself with no second flag:

```bash
make build-browser                            # tags claude-code-box:browser
CLAUDE_IMAGE=claude-code-box:browser \
  ./bin/claude-launch site --workspace ./site
```

The entrypoint detects the baked Chromium + `chrome-devtools-mcp` on startup and
registers the MCP automatically. `--browser` (or `CLAUDE_BROWSER=1`) still works
and now *forces* it — on a non-browser image it **fails loud** with a rebuild
hint instead of silently doing nothing. To run the browser image but keep the
MCP off, pass `--no-browser` (or `CLAUDE_BROWSER=0`).

Either way you get the official
[chrome-devtools-mcp](https://github.com/ChromeDevTools/chrome-devtools-mcp)
inside the container — headless Chromium driven via the Chrome DevTools
Protocol. The agent now has tools to:

- **navigate / click / type / select / wait_for** — drive the page
- **evaluate_script** — run JS, read state, query the DOM
- **take_screenshot / take_snapshot** — see what's rendered
- **list_console_messages / list_network_requests / get_network_request** — read logs and requests
- **lighthouse_audit / performance_start_trace** — full perf + a11y audits
- **take_heapsnapshot** + retainer queries — chase memory leaks

Pair the browser variant with `--dev-cmd` and `--expose` from the compose
generator so Claude both starts the dev server and debugs against it (the
generator's `--browser` selects the browser image and enables the MCP):

```bash
./bin/claude-compose-gen --org ORG --out FILE \
  --active site \
  --expose site:4321:4321 \
  --dev-cmd 'site=…--host 0.0.0.0 --port 4321' \
  --browser site
```

Cost: ~200 MB image-size delta for the baked Chromium when WITH_BROWSER=1; the
lean default image is unchanged. Headless-only inside the container; the agent
reads pages back via screenshots and DOM queries. Full design rationale:
[docs/architecture.md](docs/architecture.md#decision-frontend-debugging-is-an-opt-in-image-variant);
runbook: [docs/troubleshooting.md](docs/troubleshooting.md#frontend-debugging---browser--claude_browser).

## Toolchains on demand (`mise`)

The image bakes [`mise`](https://mise.jdx.dev) so a session can provision language
toolchains and prebuilt CLIs **as the unprivileged `claude` user, with no `sudo`
and no image rebuild**:

```bash
mise use node@22            # languages: node / python / go / rust / …
mise use python@3.12
mise use aqua:BurntSushi/ripgrep   # arbitrary prebuilt CLIs (aqua registry)
mise use github:cli/cli            # …or straight from a GitHub release
```

Installed tools land in the shared **`/cache`** tree (see below) and are on
`PATH` for the agent immediately (via mise's shims dir, baked onto `PATH` for
non-interactive shells; interactive SSH/tmux shells get full `mise activate`).
mise is **pinned + SHA256-verified in the Dockerfile** at build — the release
binary is downloaded from GitHub and checked against a hardcoded digest, no
`curl | sh` (bump `MISE_VERSION` + the two digests together). `pipx:` installs
reuse the baked `uv` automatically.

**Shared, persistent tool cache (PKG-3).** mise's install store **and** the
`cargo`/`go`/`npm`/`uv`/`pip` caches live on **one shared docker volume**
(`claude-cache`) mounted at `/cache`, so a toolchain or CLI provisioned by one
container is a **cache hit** for the next launch of that project and for every
parallel worker — no re-download. It's **on by default**; `claude-launch --no-cache`
(or `claude-compose-gen --no-cache`) opts out, and a **missing cache never errors a
launch** — it degrades to per-container installs (fail-safe). The volume is bounded
by `claude-disk-gc`: over `CLAUDE_CACHE_MAX_MIB` it trims only the re-fetchable
download caches (installed toolchains kept), idle-only and fail-safe, and the
broker's free-space floor already covers it since it sits on the docker data root.
Full design + verification: [docs/shared-tool-cache.md](docs/shared-tool-cache.md).

- **Egress lockdown is opt-in** (`CLAUDE_EGRESS_LOCKDOWN=1`); **off by default,
  where every `mise use …` just works.** Under lockdown: `github:`/`aqua:` and
  `python@` work on the **base** allowlist; `pip`/`cargo`/`go` registry backends
  need `CLAUDE_EGRESS_PACKAGES=1`; and the `node@`/`go@`/`rust` toolchains pull
  their runtime from vendor hosts (nodejs.org, go.dev, static.rust-lang.org) not
  yet on the allowlist, so they need those hosts via `CLAUDE_EGRESS_EXTRA_HOSTS`.
- **System libraries (`apt`) are not available** in a leaf container by design —
  it's rootless. Those are the Sysbox-worker apt tier, not here.
- The image sets `trusted_config_paths` to **`/workspace` only** — a deliberately
  scoped supply-chain trade so a repo's own `mise.toml` auto-applies while a config
  anywhere else stays untrusted (never a blanket `/`). Full design + verification:
  [docs/toolchain-provisioning.md](docs/toolchain-provisioning.md).

## Troubleshooting (summary)

Full runbook: [docs/troubleshooting.md](docs/troubleshooting.md).

- **App session missing / no green dot** — needs Claude Code ≥ 2.1.52 and
  outbound HTTPS. `claude-logs <name>` should show the session started; check
  egress isn't firewalled. The name in the app is the project name.
- **`--dangerously-skip-permissions` vs Remote Control** — there were earlier
  reports that skip-permissions didn't fully apply under Remote Control. On the
  pinned 2.1.144, `remote-control --permission-mode` accepts `bypassPermissions`
  and the launch combines both, so it works. If a future version regresses, set
  `CLAUDE_PERMISSION_MODE=acceptEdits` (edits auto-approved, shell still
  prompts) — see troubleshooting for the verification steps.
- **SSH connection refused** — no `authorized_keys` was mounted, or wrong port.
  `claude-list` shows the port; the connect line is reprinted by
  `claude-launch <name>`.
- **Git push fails** — `GIT_SSH_KEY` not mounted or not authorized on the
  remote. Public/https clones still work without it.
- **Workspace trust prompt** — pre-accepted by the entrypoint; if you see it,
  the config volume didn't mount. See troubleshooting.

## Security notes

- **`--dangerously-skip-permissions` is the default.** The container is
  isolated from the host (separate fs, non-root `claude` user, resource caps),
  but the agent has free rein *inside* it: it can run any command and push to
  any repo its mounted key can reach. Treat each container as a blast radius of
  one repo. For a production fleet against real repos, set
  `CLAUDE_PERMISSION_MODE=acceptEdits` (in-project edits auto-approved, shell/
  network still gated) — now honored by **both** the interactive session and
  autopilot, not just the app prompt.
- **Secret guard (on by default).** A fleet-wide git pre-commit hook
  (`CLAUDE_SECRET_GUARD=1`) blocks the autonomous agent from committing obvious
  secrets — `.env`, `*.pem`, `*.key`, `id_rsa`, files containing a `PRIVATE KEY`
  block — before they can be pushed with the mounted key. Bypass a deliberate
  file once with `git commit --no-verify`; extend the deny-list via
  `CLAUDE_SECRET_GUARD_EXTRA`; disable with `CLAUDE_SECRET_GUARD=0`. The hook
  chains to a repo's own `pre-commit` so existing project hooks still run.
- **Escape hardening + the honest blast radius.** Each container runs with
  `--security-opt no-new-privileges` and, by default (`CLAUDE_HARDEN_CAPS=1`),
  `--cap-drop ALL` plus a minimal re-add — removing the Docker-default `NET_RAW`,
  `MKNOD`, and `SETFCAP` a compromised agent would reach for. The launcher also
  **warns if the host runC is older than 1.2.8 / 1.3.3** (the Nov-2025 escape
  CVEs CVE-2025-31133/52565/52881) — patching the host runtime is the single
  highest-leverage control, because **a container is not a security boundary
  against a fully weaponized agent** (AWS says as much of its own runtime). These
  controls shrink blast radius but do **not** by themselves contain the secrets
  the agent can reach — see secret brokering below. For an untrusted-input /
  multi-tenant threat model, also run a microVM runtime (gVisor/Kata) rather than
  relying on container isolation alone.
- **Nested workers run Sysbox, never privileged DinD or a socket mount.** Where a
  controller container must itself run worker containers (the umbrella's parallel
  `/work-on` tier), the only sanctioned mechanism is **Sysbox-nested** children —
  root-in-container maps to an unprivileged host uid, and a pre-0.7.0 Sysbox
  (missing the Nov-2025 escape-CVE patches) is **refused**, not warned about.
  `--privileged` Docker-in-Docker and bind-mounting `/var/run/docker.sock` into an
  agent are rejected outright (socket access == host root). Decision, runbook, and
  the on-host containment proof: [docs/substrate.md](docs/substrate.md) +
  `bin/claude-sysbox-verify`.
- **Worker launches are brokered by root — the agent never holds the inner Docker
  socket.** On a controller, `CLAUDE_WORKER_BROKER=1` starts a **root-owned
  broker** (`bin/claude-worker-broker`, mirroring the git-key broker pattern) that
  is the only principal talking to the inner `dockerd` — the socket is locked to
  `root:root 600`, because inside the controller socket access is still every peer
  worker, its leases, and the launch template. The unprivileged agent *requests* a
  worker via `claude-worker-request <repo> <item>`: a tiny KEY=VALUE file in a
  write-only spool. The broker **renames each request into a root-only staging dir
  before reading it** (closing the swap-TOCTOU on the agent-owned spool entry —
  no FIFO can hang the loop, no symlink can leak a root file) and validates it
  **deny-by-default** (exactly two sanitized values; an unknown key, forged
  cap/limit, flag smuggling, duplicate, or oversize rejects the whole request). The broker applies a **fixed hardened template** — cap-drop
  ALL + minimal re-add (`NET_RAW`/`MKNOD`/`SETFCAP` stay dropped),
  `no-new-privileges`, per-worker memory/reservation/cpus/pids/shm caps, secret-
  guard + egress inheritance — and enforces lease discipline (one live worker per
  item, `CLAUDE_BROKER_MAX_WORKERS` total). It **fails closed** unless userns
  containment is real (`/proc/self/uid_map`) *and* the host attested a CVE-patched
  Sysbox (`CLAUDE_SYSBOX_ATTESTED_VERSION`, exported by the launch path from
  `preflight_sysbox`). On-host proof: `bin/claude-broker-verify` (28 checks);
  docker-free logic tests: `test/broker-unit.sh` (CI).
- **Resources are K-aware and overcommit is a refusal.** The worker cap defaults to
  **K from the umbrella `operations/parallel.config.json`** (one source of truth,
  never forked here), the per-worker profile (`4g/3g/2cpu/2048pids/2g shm`) is
  single-sourced in `bin/_common.sh`, and the Sysbox controller must carry
  **Σ(K·profile) + overhead** — `claude-controller-size` derives it (K=2 → 5 CPUs /
  10240 MiB / 5120 pids) and refuses an envelope the host can't fit; the broker
  refuses to *serve* in a controller whose own cgroup budget can't carry its cap.
  Every flat session also gets `--memory-reservation` + `--pids-limit`. On-host
  proof (limits enforce *inside*, OOM + fork-bomb stay isolated per worker):
  `bin/claude-sizing-verify`; math/refusal tests: `test/sizing-unit.sh` (CI).
  See [docs/substrate.md](docs/substrate.md) § K-aware resource sizing.
- **Disk pressure is a per-launch refusal, and layers get reclaimed.** The broker
  checks free space on `CLAUDE_DISK_DATA_ROOT` (the inner dockerd data-root)
  before every launch and refuses (`error disk pressure: … — retry after gc`)
  below `CLAUDE_DISK_FLOOR_MIB` (default 10 GiB) — **fails closed** if free space
  can't be determined at all. `claude-disk-gc --loop` runs alongside the broker +
  reaper, pruning dangling images/containers/networks **and** the build cache
  (`docker system prune -f` + `docker builder prune -f`) without ever touching a
  running container or a volume. On-host proof: `bin/claude-disk-verify`;
  docker-free logic tests: `test/disk-unit.sh` (CI). See
  [docs/substrate.md](docs/substrate.md) § Storage/disk safety.
- **Secret brokering (git key + credentials).** By default the SSH deploy key is
  copied to a `claude`-readable `~/.ssh/id_ed25519`, so a prompt-injected agent
  could exfiltrate it. `CLAUDE_BROKER_GIT_KEY=1` instead loads the key into a
  **root-owned `ssh-agent`** and exposes only a signing socket (via a root
  `socat` relay): git still pushes, but the unprivileged agent can never read the
  key bytes — not from a file, the agent protocol, the socket, or root's
  `/proc/<pid>/mem`. The shared **`claude-auth` credential master is always**
  locked to `root` (`/auth`, mode 700), so the agent can't reach the token that
  backs the rest of the fleet; it only ever holds its **own** per-container
  session token, which is unavoidable (Claude Code authenticates with it, and a
  Max subscription has no scopable API key). Rotate the master with
  `docker volume rm claude-auth` + `make login`.
- **Egress lockdown (opt-in).** `CLAUDE_EGRESS_LOCKDOWN=1` applies a default-deny
  iptables firewall at boot — as root, before the agent starts and while it's
  still unprivileged, so a prompt-injected agent can neither exfiltrate to
  arbitrary hosts nor disable its own egress rules. Enforcement is at the network
  layer on a pinned IP allowlist, because the research that motivated this found
  Claude Code's own app-layer allowlist was bypassable (a SOCKS5 null-byte parser
  differential) and SNI/CONNECT proxy allowlists are evadable by domain fronting.
  The baked allowlist covers the Claude API, OAuth, the Remote Control feature
  flags (`statsig.*`/`growthbook.*` — blocking those breaks RC), npm, and GitHub
  (via its published IP ranges); extend with `CLAUDE_EGRESS_EXTRA_HOSTS`. It adds
  ~10s to boot and the `NET_ADMIN` cap, and **fails open** (logs loudly, leaves
  egress unrestricted) rather than bricking connectivity. Caveat: an IP-pinned
  allowlist can go stale as CDNs rotate IPs, and `statsig.anthropic.com` isn't
  publicly resolvable so it can't be pinned — re-verify if RC eligibility fails.
- **Package-registry egress (opt-in, additive).** `CLAUDE_EGRESS_PACKAGES=1`
  adds the curated package registries — PyPI, crates.io, the Go module proxy,
  `mise.run`, and `ghcr.io` — to the same IP-pinned allowlist, so agent-driven
  `pip`/`cargo`/`go`/`mise` installs work while lockdown is on. It is **curated,
  not open**: a registry that isn't listed still DROPs, because *open* egress is
  the supply-chain exfil path the container refuses. Nothing broadens unless the
  flag is explicitly set, and the fail-open-as-a-whole semantics are unchanged.
  Debian/apt **system** libraries are deliberately not here — those need the
  rootful Sysbox-worker `apt` tier, not a leaf container. The threat model (the
  Nx-class weaponized-agent exfil) and the containment rules are in
  [docs/package-provisioning-security.md](docs/package-provisioning-security.md).
  The baked `mise` toolchain provisioner (rootless language/CLI installs) rides on
  this containment — see [Toolchains on demand](#toolchains-on-demand-mise) and
  [docs/toolchain-provisioning.md](docs/toolchain-provisioning.md).
- **`claude-auth` volume** holds your live OAuth credentials
  (`.credentials.json`) — effectively your Claude session. Anyone who can read
  this Docker volume can act as you. Rotate by `docker volume rm claude-auth`
  then `make login` again (or `claude auth logout` then re-login).
- **SSH keys.** The git key and authorized_keys are mounted read-only and never
  baked into the image. The git key is copied to a 0600 file owned by `claude`
  (read-only bind mounts can't satisfy SSH's permission check directly). Host
  keys persist in `claude-sshkeys` so the fingerprint is stable; all containers
  share it (acceptable for a single-owner homelab — note it and use distinct
  keys if that matters to you).
- **The SSH port is published on all host interfaces** (`0.0.0.0`) by default,
  so it is reachable from the whole LAN. Auth is pubkey-only, but to limit the
  exposure set `CLAUDE_SSH_BIND=127.0.0.1` (host-only) or another interface —
  honored by `claude-launch` and `claude-compose-gen`.
- Egress is open by default (Claude, npm, git, MCP all need it). Locking it
  down: [docs/troubleshooting.md](docs/troubleshooting.md#restricting-egress).

## Acceptance checklist

See [docs/architecture.md](docs/architecture.md#acceptance) for how each spec
acceptance criterion maps to this implementation and how to verify it.
