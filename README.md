# Claude Code container

Self-hosted Docker image for running multiple isolated, long-lived Claude Code
sessions on a homelab box. One container = one session = one git repo, reachable
two ways at once: SSH into a persistent tmux session, and the Claude mobile
app's Remote Control (Code tab).

Auth is your Claude **Max** subscription via OAuth. No API keys — the entrypoint
hard-fails if `ANTHROPIC_API_KEY` is set so you never accidentally bill per
token.

> **Substrate change (2026-07-12).** This repo used to run a nested-Sysbox
> worker-broker path (`--broker`/`--sysbox`, controller dispatch, curated worker
> `apt`, a pull-through cache proxy — the `CC-*` and `PKG-4`/`PKG-6` work) so a
> controller container could spawn autonomous nested `/work-on` workers. It was
> retired in favor of Claude Code subagents in per-worktree git worktrees and
> stripped from `main`. The frozen implementation is preserved at branch
> `legacy/sysbox-broker-2026-07-12` + tag `legacy-sysbox-broker-2026-07-12` — see
> [docs/legacy-sysbox-broker.md](docs/legacy-sysbox-broker.md). The Remote-Control
> core, the autopilot loop, launch/compose-gen (sans broker flags), housekeeping,
> baked config, and the security floor all stay on `main`. A follow-up, **CC-BINS**,
> then pruned the residue the strip left behind: `claude-controller`, `claude-reaper`,
> the `WITH_DOCKER` image variant, and the autopilot's `/next` default.

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
   claude-docker-<proj> (per ctr) inner image store    → /var/lib/docker  (--docker only)
   claude-scratch-<proj>(per ctr) disk-backed TMPDIR   → /scratch
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
  it fires `claude -p "$CLAUDE_AUTOPILOT_CMD"` and prints the result. No Remote
  Control link (the watchdog is skipped); SSH still attaches to the live pane so
  you can watch it. Each run is a fresh session — which suits a session-independent
  command that recovers its state from disk.

> **`CLAUDE_AUTOPILOT_CMD` is required and has no default.** It used to default to
> `/next`. That was wrong: this is a *generic* image — it bakes no `/next`, and the
> workspace you mount is arbitrary, so on almost every container the default resolved
> to nothing at all. With no command set, the autopilot now refuses to run (or idles,
> if it is a queue consumer). **No command, no run.**
>
> **Set it to a command your workspace actually defines.** On the pinned CLI, `claude -p`
> does *not* error on an unknown slash command — it returns a **zero-turn "success"**
> (`num_turns: 0`, `is_error: false`, exit 0, `$0`, the model never invoked, `result:
> "Unknown command: /typo"`). The autopilot therefore treats a zero-turn
> `Unknown command:` result as a **failure**: it says so loudly, files a queued task
> under `failed/` rather than `done/`, and stops (or, if it is also a queue consumer,
> drops the broken fallback and keeps draining the queue). Without that check a typo'd
> command would have produced a container that logs a healthy `$0` run every interval,
> forever, having done nothing.

Point one autopilot container at a repo, with a command *that repo defines*:

```bash
CLAUDE_AUTOPILOT=1 CLAUDE_AUTOPILOT_CMD='/my-build-command' CLAUDE_AUTOPILOT_INTERVAL=3600 \
  ./bin/claude-launch builder --repo git@github.com:<org>/<repo>.git
```

On a rate/usage-limit failure the loop parses the actual reset time (from the
run output or a reset epoch in the JSON) and sleeps until then — better shared-
quota throughput than blind waiting — and falls back to exponential backoff (up
to `CLAUDE_AUTOPILOT_BACKOFF_MAX`, default 6h) when no reset time is found, so a
hot error loop still can't burn your quota. Each run logs its `total_cost_usd`
(plus turns and duration) so the shared subscription's spend is attributable per
container. Per-run JSON logs land in `CLAUDE_AUTOPILOT_LOG_DIR` (default
`~/.claude/autopilot-logs`); `claude-logs` still shows the entrypoint/sshd log.

By default each cycle is a fresh session (suits session-independent commands that
recover state from disk). Set `CLAUDE_AUTOPILOT_RESUME=1` to
instead carry the exact conversation forward via `--resume <session_id>` (the ID
is captured from each run's JSON and persisted on the container's config volume)
— use it for a single stateful long-running task rather than a queue-driven one.

**Durable task queue.** A blind timer is the wrong primitive for fleet work, so
`CLAUDE_AUTOPILOT_QUEUE=1` turns the loop into a queue consumer: it claims the
oldest pending prompt file (atomic `mv`, so it's restart- and race-safe), runs it
as a one-shot task, and files it under `done/` or `failed/`. When the queue
drains it falls back to `CLAUDE_AUTOPILOT_CMD` on the interval — so a queued
container is *also* a continuous-build container. Leave `CLAUDE_AUTOPILOT_CMD`
unset and it is a **pure queue consumer**: on an empty queue it simply idles,
rather than inventing a prompt to fill the gap. Enqueue from inside the
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

**Controller mode is gone.** `CLAUDE_CONTROLLER=1` used to be a third main-pane mode,
wiring a Sysbox-nested controller to a lease/scheduler/bump-worker control plane and
dispatching nested workers. SC-5 retired that dispatch tier (see
[docs/legacy-sysbox-broker.md](docs/legacy-sysbox-broker.md)), which left the mode a
byte-identical pass-through to `CLAUDE_AUTOPILOT=1` — a mode whose only job was
selecting another mode. CC-BINS removed it, along with `bin/claude-controller`, the
`WITH_DOCKER` image variant it ran in, and `claude-reaper` (which pruned a spool only
the retired broker ever wrote to). **Setting `CLAUDE_CONTROLLER=1` now refuses to boot**,
with a message pointing at `CLAUDE_AUTOPILOT=1` — rather than silently starting an
interactive session in an unattended container nobody is watching. Use
`CLAUDE_AUTOPILOT=1`; it is the same loop, and always was.

## Environment variables

Set in `.env` (auto-loaded by the scripts and passed into containers). Real env
vars override `.env`. Full reference: `.env.example`.

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDE_IMAGE` | `claude-code-box:latest` | Image tag built/run |
| `CLAUDE_CODE_VERSION` | `2.1.207` | Pinned Claude Code npm version (min 2.1.52). `opus` resolves to Opus 4.8 from 2.1.154 |
| `NODE_VERSION` | `24` | Base Node LTS |
| `UV_VERSION` | `latest` | `uv` version (pin for reproducibility) |
| `PNPM_VERSION` | `latest` | `pnpm` version baked in (pin for reproducibility) |
| `CLAUDE_UID`/`CLAUDE_GID`/`CLAUDE_USER` | `1000`/`1000`/`claude` | Container user |
| `CLAUDE_MODEL` | `opus` | Model the session runs. Defaults to the best available model (the `opus` alias always resolves to the latest Opus — **Opus 4.8** on the pinned CLI). Passed through to `--model` verbatim, so use an alias the pinned CLI actually ships (`opus`/`sonnet`/`haiku`/`opusplan`/`fable`/`best`) or a full id like `claude-opus-4-8`. **`default` is not in 2.1.207's alias table** — don't rely on it to defer to Claude Code's own pick. Both launchers now default to `opus` when this is unset, so a session can never silently fall back to Claude Code's default (which is Sonnet 5 from CLI 2.1.197). Per-container via `claude-launch --model`, per-repo via `claude-compose-gen --model REPO=MODEL` |
| `CLAUDE_PERMISSION_MODE` | `bypassPermissions` | `acceptEdits`/`auto`/`bypassPermissions`/`manual`/`dontAsk`/`plan` — the choice set the pinned CLI accepts. Honored by both the interactive session and autopilot; `acceptEdits` is the safer fleet posture (gates shell/network). **`default` was renamed `manual` upstream in CLI 2.1.200** and no longer appears in `claude --help`; it is still accepted for now (verified on 2.1.207), so existing `.env` files keep working — but prefer `manual`, since an undocumented alias can be dropped |
| `CLAUDE_SECRET_GUARD` | `1` | `1` installs a fleet-wide git pre-commit hook that blocks committing secrets (`.env`, `*.pem`, `*.key`, `id_rsa`, PRIVATE KEY blocks). Bypass once with `git commit --no-verify`; extend via `CLAUDE_SECRET_GUARD_EXTRA` |
| `CLAUDE_AUTOPILOT` | `0` | `1` = unattended mode: main pane runs a headless `claude -p` loop instead of Remote Control (see [Unattended autopilot](#unattended-autopilot)) |
| `CLAUDE_AUTOPILOT_CMD` | **none — required** | What the autopilot loop runs each cycle. **No default** (it used to be `/next`, which this generic image does not ship). Unset + no queue = the autopilot refuses to run |
| `CLAUDE_AUTOPILOT_INTERVAL` | `3600` | Seconds between successful autopilot runs |
| `CLAUDE_AUTOPILOT_MAX_RUNS` | `0` | Stop after N autopilot runs (`0` = unlimited) |
| `CLAUDE_AUTOPILOT_RESUME` | `0` | `1` = carry the conversation forward via `--resume <session_id>` each cycle instead of a fresh session |
| `CLAUDE_AUTOPILOT_QUEUE` | `0` | `1` = consume prompt files from a durable task queue (`claude-enqueue`), falling back to `CLAUDE_AUTOPILOT_CMD` when empty — or idling, if that is unset (see [Unattended autopilot](#unattended-autopilot)) |
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
| `CLAUDE_EGRESS_PACKAGES` | `0` | `1` = additively allowlist the curated **package registries** (PyPI, crates.io, Go proxy, `mise.run`, `ghcr.io`) so agent-driven `pip`/`cargo`/`go`/`mise` installs work under lockdown. Opt-in and curated (not open); nothing else broadens. Debian/apt system libs have no self-service path (see [docs/package-provisioning-security.md](docs/package-provisioning-security.md)) |
| `CLAUDE_BROKER_GIT_KEY` | `0` | `1` = hold the SSH deploy key in a root ssh-agent (agent signs/pushes but can't read the key bytes) instead of a readable `~/.ssh/id_ed25519` |
| `CLAUDE_DISK_DATA_ROOT` | `/var/lib/docker` | Path whose free space `claude-disk-gc` reports before/after each cycle |
| `CLAUDE_DISK_GC_INTERVAL` | `3600` | Seconds between `claude-disk-gc --loop` cycles (standalone tool; nothing auto-starts it) |
| `CLAUDE_CONTROLLER` | *removed* | **Removed in CC-BINS — setting it to `1` now refuses to boot.** It had collapsed to a byte-identical pass-through to `CLAUDE_AUTOPILOT=1`. Use that instead |
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
| `/var/lib/docker` | `claude-docker-<proj>` volume | per container, `--docker` only | Inner Docker image store — pulled base images + built layers. Can reach tens of GB; `claude-rm --purge` deletes it |
| `/scratch` | `claude-scratch-<proj>` volume | per container | **`TMPDIR`** — disk-backed temp. Cleared on every boot; `claude-rm --purge` deletes it |
| `/tmp` | tmpfs (**RAM**, 1 GB) | per container | Small temp only. Charged to the memory cgroup — big writes belong in `/scratch` |
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
claude-disk-gc [--loop]           GC docker image/build-cache layers + trim the shared cache
claude-disk-verify                prove disk-hygiene logic (docker-free, safe anywhere)
```

A nested-Sysbox worker-broker substrate used to run alongside `claude-launch --broker`,
spawning autonomous nested workers via a root-owned broker. It was retired in SC-5 — see
[docs/legacy-sysbox-broker.md](docs/legacy-sysbox-broker.md).

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

## Container workflows (optional)

Off by default. When a session's job involves containers — writing a Dockerfile,
bringing up a `compose` stack, running testcontainers — give it **its own Docker
engine**:

```bash
make build-docker                             # tags claude-code-box:docker
./bin/claude-launch api --docker --workspace ./api
```

Inside, the agent is a normal Docker user: `docker build`, `docker run`,
`docker compose up`, `docker buildx` all work, as itself (the unprivileged
`claude` user), with no `sudo`.

**How this stays safe.** The daemon runs *inside* the session container, and the
container runs under **Sysbox** (`--runtime=sysbox-runc`), which puts it in a user
namespace: container-root maps to an unprivileged host uid. On this host, measured:

| | capabilities | uid map |
|---|---|---|
| ordinary session (`runc`) | Docker's default 14 | `0 → 0` (container-root **is** host root) |
| `--docker` session (`sysbox-runc`) | full set | `0 → 165536` (container-root is a host nobody) |

The full capability set looks alarming and isn't: those are powers over the
container's *own* namespace. This is why `--docker` needs **no `--privileged` and
no host docker-socket mount** — both are forbidden here, and either would hand a
prompt-injectable agent root on the host. `claude-launch --docker` refuses to run
if the Sysbox runtime is missing rather than falling back to something unsafe.

**What it does cost you, stated plainly.** A docker socket is a path to root
*inside* the container (`docker run -v /:/rootfs …`). Sysbox keeps that root off
the host, so the boundary that matters holds — but two in-container controls
assume root is separate from the agent, and on a `--docker` session they no longer
bind:

- **`CLAUDE_BROKER_GIT_KEY=1`** hides the deploy key in a root-owned `ssh-agent`;
  an agent with Docker can read the key file straight off the filesystem.
- **`CLAUDE_EGRESS_LOCKDOWN=1`** filters the `OUTPUT` chain; inner containers'
  traffic is `FORWARD`ed, and container-root can flush the rules anyway.

Both are off by default. The launcher warns if you combine either with `--docker`.
Also: `--cap-drop ALL` is skipped for these containers (an inner daemon cannot
start under the minimal set), while `no-new-privileges` is kept — its one real
cost is that setuid binaries *inside an inner container* (`sudo`, `ping`) can't
elevate.

**Sizing.** Inner containers live in the session's cgroup, so `CLAUDE_MEM_LIMIT` /
`CLAUDE_CPU_LIMIT` / `CLAUDE_PIDS_LIMIT` have to cover the whole stack. The 4g
default is tight for building images or running a compose stack; 8g+ is a saner
floor, and the launcher warns below it.

**Disk.** The inner image store persists in a per-project `claude-docker-<name>`
volume, so a recreate doesn't re-pull every base image. It holds every layer the
session builds or pulls and can reach tens of GB; `claude-rm --purge` deletes it
(and prints its size first).

Both variants compose: `make build-docker-browser` bakes the engine *and*
Chromium, for a session that runs a containerized stack and debugs its frontend
(`--docker --browser`). For a whole fleet, `claude-compose-gen --docker REPO`
emits `runtime: sysbox-runc` on just those services — a lean sibling in the same
stack keeps its full `cap_drop`.

Not to be confused with the retired nested-Sysbox **worker broker**
([docs/legacy-sysbox-broker.md](docs/legacy-sysbox-broker.md)): this reuses that
era's runtime and nothing else — no broker, no worker plane, no spool.

## Temp space: `/scratch`, not `/tmp`

`/tmp` is a **tmpfs** — it lives in RAM, is capped at 1 GB, and every page is charged to the
container's memory cgroup. With `TMPDIR` unset, everything large defaults there: `pip`/`uv`
building wheels, `docker save`/`load` tarballs, and (in a `--docker` session) the inner
containerd's mount dirs. The result is an install that dies at 1 GiB with a confusing
`ENOSPC` while the host has terabytes free — or, worse, a session that OOM-kills itself
because a build filled RAM it was accounted for.

So every container gets a **disk-backed `claude-scratch-<name>` volume mounted at
`/scratch`, and `TMPDIR` points at it**. Temp writes land on disk, where the space actually
is; `/tmp` stays a small, fast tmpfs for what a tmpfs is good at. `dockerd` and `containerd`
inherit `TMPDIR` from the entrypoint, and `bash_profile` re-exports it, so an SSH login gets
the same behaviour as the agent (sshd builds a fresh environment and would otherwise fall
back to `/tmp`).

It is scratch, not state: the entrypoint **clears it on every boot**. A volume — unlike a
tmpfs — survives restarts, so without that it would accumulate abandoned wheel builds and
half-written tarballs until the pool filled. `claude-rm --purge` deletes it.

Raising the `/tmp` tmpfs instead would have been the wrong fix: it is RAM, so a 10 GB `/tmp`
would simply move the failure from `ENOSPC` to an OOM kill inside the session's own cgroup.

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
other container sharing the volume — no re-download. It's **on by default**;
`claude-launch --no-cache` (or `claude-compose-gen --no-cache`) opts out, and a
**missing cache never errors a launch** — it degrades to per-container installs
(fail-safe). The volume is bounded by `claude-disk-gc`: over `CLAUDE_CACHE_MAX_MIB`
it trims only the re-fetchable download caches (installed toolchains kept),
idle-only and fail-safe. Full design + verification:
[docs/shared-tool-cache.md](docs/shared-tool-cache.md).

- **Egress lockdown is opt-in** (`CLAUDE_EGRESS_LOCKDOWN=1`); **off by default,
  where every `mise use …` just works.** Under lockdown: `github:`/`aqua:` and
  `python@` work on the **base** allowlist; `pip`/`cargo`/`go` registry backends
  need `CLAUDE_EGRESS_PACKAGES=1`; and the `node@`/`go@`/`rust` toolchains pull
  their runtime from vendor hosts (nodejs.org, go.dev, static.rust-lang.org) not
  yet on the allowlist, so they need those hosts via `CLAUDE_EGRESS_EXTRA_HOSTS`.
- **System libraries (`apt`) are not available** — the agent is rootless, and the
  worker-tier `apt` path that used to close that gap (PKG-4) was retired in SC-5
  along with the Sysbox substrate it depended on (see
  [docs/legacy-sysbox-broker.md](docs/legacy-sysbox-broker.md)). A system library
  needs a base-image rebuild today.
- The image sets `trusted_config_paths` to **`/workspace` only** — a deliberately
  scoped supply-chain trade so a repo's own `mise.toml` auto-applies while a config
  anywhere else stays untrusted (never a blanket `/`). Full design + verification:
  [docs/toolchain-provisioning.md](docs/toolchain-provisioning.md).
- **Reproducible + script-hardened installs (PKG-5).** Agent-initiated `npm`/`pnpm`
  installs run with **`ignore-scripts=true`** (baked into the `claude` user's
  `~/.npmrc`, so build-time root installs are untouched; a repo opts back in with its
  own `/workspace/.npmrc`). mise **`lockfile=true`** makes a committed
  `mise.lock` reinstall identical versions offline from the shared cache. `claude-deps-check`
  flags `latest`/unpinned specs in `mise.toml`/`package.json` (advisory; `--strict`
  refuses). Threat model + bypasses: [docs/package-provisioning-security.md](docs/package-provisioning-security.md).

## Troubleshooting (summary)

Full runbook: [docs/troubleshooting.md](docs/troubleshooting.md).

- **App session missing / no green dot** — needs Claude Code ≥ 2.1.52 and
  outbound HTTPS. `claude-logs <name>` should show the session started; check
  egress isn't firewalled. The name in the app is the project name.
- **`--dangerously-skip-permissions` vs Remote Control** — there were earlier
  reports that skip-permissions didn't fully apply under Remote Control. On the
  pinned **2.1.207** both flags are accepted together with no interlock, and the
  launch (`claude --dangerously-skip-permissions --remote-control <name>`) combines
  them, so it works. This is the reason the CLI version is pinned at all — re-verify
  it on any bump. If a future version regresses, set
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
- **Every flat session gets resource + disk hygiene.** `--memory-reservation` +
  `--pids-limit` cap every session; `claude-disk-gc --loop` (a standalone tool —
  run it by hand or on your own cron/timer) prunes dangling images/containers/
  networks **and** the build cache (`docker system prune -f` + `docker builder
  prune -f`) without ever touching a running container or a volume, and trims the
  shared `/cache` volume's re-fetchable download caches when it exceeds
  `CLAUDE_CACHE_MAX_MIB`. Docker-free logic tests: `test/disk-unit.sh`,
  `test/sizing-unit.sh` (CI); one-command sanity pass: `bin/claude-disk-verify`.
  (A nested-Sysbox worker-broker substrate used to run alongside this — a
  root-owned broker spawning autonomous nested workers with a K-aware resource
  envelope and a per-launch disk-pressure refusal. It was retired in SC-5; see
  [docs/legacy-sysbox-broker.md](docs/legacy-sysbox-broker.md).)
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
  Debian/apt **system** libraries are deliberately not here — no self-service path
  currently provisions those (see docs/legacy-sysbox-broker.md). The threat model (the
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
