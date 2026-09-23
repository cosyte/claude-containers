# Claude Code container

Self-hosted Docker image for running multiple isolated, long-lived Claude Code
sessions on a homelab box. One container = one session = one git repo, reachable
two ways at once: SSH into a persistent tmux session, and the Claude mobile
app's Remote Control (Code tab).

Auth is your Claude **Max** subscription via OAuth. No API keys: the entrypoint
hard-fails if `ANTHROPIC_API_KEY` is set so you never accidentally bill per
token.

> **Unofficial project.** Not affiliated with, endorsed by, or supported by
> Anthropic. "Claude" and "Claude Code" are Anthropic's trademarks and are used
> here only to say what this runs. It installs the published
> `@anthropic-ai/claude-code` CLI at a pinned version; your use of Claude Code
> and of your Claude subscription remains subject to Anthropic's own terms.
> Report Claude Code bugs to Anthropic, not here.

> **A retired feature you may find references to.** An earlier version ran a
> nested-Sysbox **worker broker**: a controller container that spawned autonomous
> nested worker containers (`--broker`/`--sysbox`). It was retired on 2026-07-12 in
> favour of Claude Code subagents in git worktrees, and is frozen on branch
> `legacy/sysbox-broker-2026-07-12` (tag `legacy-sysbox-broker-2026-07-12`), which
> is **not maintained**. Removed flags now *refuse* with an error naming their
> replacement rather than silently doing nothing. Background:
> [docs/legacy-sysbox-broker.md](docs/legacy-sysbox-broker.md). Nothing described
> below depends on it, and note that the **`--docker` per-session Docker engine
> is a separate, current feature** ([below](#container-workflows-optional)) that
> reuses only the Sysbox runtime.

## Quick start

```bash
cp .env.example .env          # edit if you want; defaults are sane
make build                    # builds the image for this host's arch
make login                    # one-time OAuth: opens a URL, you paste a code
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

Run as many in parallel as you like: each gets its own SSH port and app
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

Both modes, the durable task queue, the SCM observer, fleet telemetry and the
shared-quota rules: [docs/unattended-autopilot.md](docs/unattended-autopilot.md).

## Environment variables

Set in `.env` (auto-loaded by the scripts and passed into containers). Real env
vars override `.env`. Full reference: `.env.example`.

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDE_IMAGE` | `claude-code-box:latest` | Image tag built/run |
| `CLAUDE_CODE_VERSION` | `2.1.280` | Pinned Claude Code npm version (min 2.1.52). `opus` resolves to the latest Opus: **Opus 5.5 from CLI 2.1.280**, Opus 5 from 2.1.219, Opus 4.8 from 2.1.154. Auto-update is on by default (`DISABLE_AUTOUPDATER` is unset), so a running container's binary can self-update past this pin unless the operator sets `DISABLE_AUTOUPDATER=1` |
| `NODE_VERSION` | `24` | Base Node LTS |
| `UV_VERSION` | `latest` | `uv` version (pin for reproducibility) |
| `PNPM_VERSION` | `latest` | `pnpm` version baked in (pin for reproducibility) |
| `CLAUDE_UID`/`CLAUDE_GID`/`CLAUDE_USER` | `1000`/`1000`/`claude` | Container user |
| `CLAUDE_MODEL` | `opus` | Model the session runs. Defaults to the best available model (the `opus` alias always resolves to the latest Opus, **Opus 5**, 1M context, on the pinned CLI; it became the default Opus in 2.1.219, so the 2.1.207→2.1.220 bump moved the fleet off Opus 4.8). Passed through to `--model` verbatim, so use an alias the pinned CLI actually ships (`opus`/`sonnet`/`haiku`/`opusplan`/`fable`/`best`) or a full id like `claude-opus-5` / `claude-opus-4-8` (set the latter to hold a container on 4.8). **`default` is not in the pinned CLI's alias table**, don't rely on it to defer to Claude Code's own pick. Both launchers now default to `opus` when this is unset, so a session can never silently fall back to Claude Code's default (which is Sonnet 5 from CLI 2.1.197). Per-container via `claude-launch --model`, per-repo via `claude-compose-gen --model REPO=MODEL` |
| `CLAUDE_PERMISSION_MODE` | `bypassPermissions` | `acceptEdits`/`auto`/`bypassPermissions`/`manual`/`dontAsk`/`plan`: the choice set the pinned CLI accepts. Honored by both the interactive session and autopilot; `acceptEdits` is the safer fleet posture (gates shell/network). **`default` was renamed `manual` upstream in CLI 2.1.200** and no longer appears in `claude --help`; it is still accepted for now (re-verified on 2.1.241, a bogus mode is rejected with the allowed-choices list, `default` is not), so existing `.env` files keep working, but prefer `manual`, since an undocumented alias can be dropped |
| `CLAUDE_SECRET_GUARD` | `1` | `1` installs a fleet-wide git pre-commit hook that blocks committing secrets (`.env`, `*.pem`, `*.key`, `id_rsa`, PRIVATE KEY blocks). Bypass once with `git commit --no-verify`; extend via `CLAUDE_SECRET_GUARD_EXTRA` |
| `CLAUDE_AUTOPILOT` | `0` | `1` = unattended mode: main pane runs a headless `claude -p` loop instead of Remote Control (see [Unattended autopilot](#unattended-autopilot)) |
| `CLAUDE_AUTOPILOT_CMD` | **none, required** | What the autopilot loop runs each cycle. **No default**, it must be a command the workspace you mount actually defines. Unset + no queue = the autopilot refuses to run |
| `CLAUDE_AUTOPILOT_INTERVAL` | `3600` | Seconds between successful autopilot runs |
| `CLAUDE_AUTOPILOT_MAX_RUNS` | `0` | Stop after N autopilot runs (`0` = unlimited) |
| `CLAUDE_AUTOPILOT_RESUME` | `0` | `1` = carry the conversation forward via `--resume <session_id>` each cycle instead of a fresh session |
| `CLAUDE_AUTOPILOT_QUEUE` | `0` | `1` = consume prompt files from a durable task queue (`claude-enqueue`), falling back to `CLAUDE_AUTOPILOT_CMD` when empty, or idling, if that is unset (see [Unattended autopilot](#unattended-autopilot)) |
| `CLAUDE_SCM_OBSERVER` | `0` | `1` = poll the repo's PRs via `gh` and route CI failures / change requests / merge conflicts into the queue (`CLAUDE_SCM_*` tune it; see `.env.example`) |
| `CLAUDE_OTEL_ENABLED` | `0` | `1` (or setting `OTEL_EXPORTER_OTLP_ENDPOINT`) exports Claude Code's per-call cost/token telemetry to an OTLP backend, tagged per container. `CLAUDE_OTEL_TRACES=1` adds traces; see `.env.example` for the `OTEL_*` vars |
| `CLAUDE_EXTRA_ARGS` |: | Extra args to `claude` (or `--extra-args`) |
| `CLAUDE_MCP_ENABLED` |: | CSV of baked MCP servers to load (empty = all) |
| `WITH_BROWSER` | `0` | Build arg: 1 bakes Chromium + chrome-devtools-mcp (+~200 MB). `make build-browser` flips it. |
| `CLAUDE_BROWSER` | auto | Tri-state for the chrome-devtools MCP: unset = auto (a browser image self-enables it), `1`/`--browser` = force on (fails loud on a lean image), `0`/`--no-browser` = opt out. |
| `WITH_DOCKER` | `0` | Build arg: 1 bakes a Docker engine for per-session container workflows. `make build-docker` flips it (`make build-docker-browser` for both variants). See [Container workflows](#container-workflows-optional) |
| `CLAUDE_DOCKER` | `0` | `1`/`--docker` gives the session its **own** Docker engine. Requires a `WITH_DOCKER=1` image **and** the Sysbox runtime on the host: the launcher refuses rather than falling back to something unsafe. Never `--privileged`, never a host docker-socket mount. Raise `CLAUDE_MEM_LIMIT` (8g+): inner containers share this container's cgroup |
| `CLAUDE_DOCKERD_WAIT` | `60` | Seconds to wait for the inner daemon before failing the boot |
| `GIT_REPO_URL`/`_BRANCH`/`_DEPTH` |: | Clone source (or use `--repo`/`--branch`/`--depth`) |
| `GIT_AUTHOR_NAME`/`_EMAIL` (+`COMMITTER`) | host git config | Commit identity |
| `GIT_SSH_KEY` | `~/.ssh/claude-git-key` | Host SSH key for git, mounted read-only |
| `SSH_AUTHORIZED_KEYS` | `~/.ssh/authorized_keys` | Host pubkeys allowed to SSH in (read-only) |
| `SSH_PORT_RANGE_START`/`_END` | `2200`/`2299` | Auto-assigned host SSH port range |
| `CLAUDE_SSH_HOST` | this host's name | Hostname shown in the connect line |
| `CLAUDE_SSH_BIND` |: | Bind the SSH port to one host interface (e.g. `127.0.0.1`); empty = all |
| `CLAUDE_CPU_LIMIT`/`CLAUDE_MEM_LIMIT` | `2`/`4g` | Per-container resource caps |
| `CLAUDE_MEM_RESERVATION` | 75% of `CLAUDE_MEM_LIMIT` | Soft memory floor (`--memory-reservation`) |
| `CLAUDE_PIDS_LIMIT` | `2048` | Fork-bomb guard (`--pids-limit`) |
| `CLAUDE_SHM_SIZE` | `2g` | `/dev/shm` size |
| `CLAUDE_HARDEN_CAPS` | `1` | `1` = `--cap-drop ALL` + minimal `--cap-add` (drops NET_RAW/MKNOD/SETFCAP); `0` = Docker defaults. `no-new-privileges` is always set. Override the set with `CLAUDE_MIN_CAPS` |
| `CLAUDE_EGRESS_LOCKDOWN` | `0` | `1`/`true`/`yes`/`on` = default-deny network firewall (iptables, IP-pinned allowlist) applied at boot before the unprivileged agent starts, **fail-open on error** (logs loudly, starts the agent anyway). `strict` = the same firewall **fail-closed**: if the ruleset cannot be applied the container refuses to start the agent and exits nonzero. `0`/`false`/`no`/`off`, unset or empty = off; any other value is off and is reported in the boot log. Extend the allowlist with `CLAUDE_EGRESS_EXTRA_HOSTS` |
| `CLAUDE_EGRESS_PACKAGES` | `0` | `1` = additively allowlist the curated **package registries** (PyPI, crates.io, Go proxy, `mise.run`, `ghcr.io`) so agent-driven `pip`/`cargo`/`go`/`mise` installs work under lockdown. Opt-in and curated (not open); nothing else broadens. Debian/apt system libs have no self-service path (see [docs/package-provisioning-security.md](docs/package-provisioning-security.md)) |
| `CLAUDE_EGRESS_REFRESH_INTERVAL` | unset (no refresh) | Seconds between **re-resolves of the allowlist** in a container that is already under lockdown, e.g. `900`. Unset, the allowlist is pinned once at boot and goes stale as CDNs rotate addresses. Set, a root-owned loop re-resolves the same host set and re-commits each family through the same atomic restore the boot pass used, so the agent can neither alter the refreshed rules nor stop the refresh. **It never narrows on a failed lookup**: a host that comes back empty leaves the ruleset in force alone and is logged by name. Absent, malformed or non-positive values all mean off, and the boot log states which posture it chose and why. Needs `CLAUDE_EGRESS_LOCKDOWN`; ignored without it, and not started when the boot pass applied no ruleset |
| `CLAUDE_BROKER_GIT_KEY` | `1` (brokered) | **Brokering is the default.** Unset, the SSH deploy key is held in a root ssh-agent: the agent signs/pushes with it but cannot read the key bytes. `0`/`false`/`no`/`off` is the explicit opt-out back to a readable `~/.ssh/id_ed25519`; any other value (including a typo) brokers. If brokering cannot be established there is **no** readable-file fallback: git is left unable to authenticate with that key and the boot log says so |
| `CLAUDE_DISK_DATA_ROOT` | `/var/lib/docker` | Path whose free space `claude-disk-gc` reports before/after each cycle |
| `CLAUDE_DISK_GC_INTERVAL` | `3600` | Seconds between `claude-disk-gc --loop` cycles (standalone tool; nothing auto-starts it) |
| `CLAUDE_CONTROLLER` | *removed* | **Removed: setting it to `1` now refuses to boot.** It had collapsed to a byte-identical pass-through to `CLAUDE_AUTOPILOT=1`. Use that instead |
| `CLAUDE_STOP_TIMEOUT` | `20` | Graceful stop timeout (s) |
| `AUTH_VOLUME`/`SSHKEYS_VOLUME` | `claude-auth`/`claude-sshkeys` | Shared volume names |
| `ANTHROPIC_API_KEY` | unset | **Must stay unset**: entrypoint hard-fails otherwise |

## Volume / mount reference

Every path in the container, its source, its scope and what it holds:
[docs/volume-reference.md](docs/volume-reference.md).

## Customizing the baked-in config

`claude-config/` is copied into the image and merged into `~/.claude` on start
(only filling what's absent, so per-container state is never clobbered). It
holds `CLAUDE.md`, `mcp/`, `plugins/`, `commands/`, `skills/`. MCP secrets are
**never baked**: use `${VAR}` placeholders, supply values at runtime via
`.env`. Full guide: [docs/customizing-bakeins.md](docs/customizing-bakeins.md).

## Launcher commands

Every `claude-*` command, the flags they take, and `claude-compose-gen` for many
repos at once: [docs/launcher-commands.md](docs/launcher-commands.md).

## Frontend debugging (optional)

The browser image variant and the chrome-devtools MCP it registers:
[docs/frontend-debugging.md](docs/frontend-debugging.md).

## Container workflows (optional)

The per-session Docker engine, why Sysbox is what makes it safe, what it costs
and how to size it: [docs/container-workflows.md](docs/container-workflows.md).

## Temp space: `/scratch`, not `/tmp`

Why `TMPDIR` points at a disk-backed volume rather than the `/tmp` tmpfs:
[docs/temp-space.md](docs/temp-space.md).

## Toolchains on demand (`mise`)

Rootless toolchain and CLI installs, the shared `/cache` volume, and what
lockdown costs them: [docs/toolchains-on-demand.md](docs/toolchains-on-demand.md).

## Troubleshooting (summary)

Full runbook: [docs/troubleshooting.md](docs/troubleshooting.md).

- **App session missing / no green dot**: needs Claude Code ≥ 2.1.52 and
  outbound HTTPS. `claude-logs <name>` should show the session started; check
  egress isn't firewalled. The name in the app is the project name.
- **`--dangerously-skip-permissions` vs Remote Control**: there were earlier
  reports that skip-permissions didn't fully apply under Remote Control. On the
  pinned **2.1.280** both flags are accepted together with no interlock, and the
  launch (`claude --dangerously-skip-permissions --remote-control <name>`) combines
  them, so it works. This is the reason the CLI version is pinned at all: re-verify
  it on any bump. If a future version regresses, set
  `CLAUDE_PERMISSION_MODE=acceptEdits` (edits auto-approved, shell still
  prompts): see troubleshooting for the verification steps.
- **SSH connection refused**: no `authorized_keys` was mounted, or wrong port.
  `claude-list` shows the port; the connect line is reprinted by
  `claude-launch <name>`.
- **Git push fails**: `GIT_SSH_KEY` not mounted or not authorized on the
  remote. Public/https clones still work without it.
- **Workspace trust prompt**: pre-accepted by the entrypoint; if you see it,
  the config volume didn't mount. See troubleshooting.

## Security notes

The threat model, managed policy, the secret guard, secret brokering, egress
lockdown and the honest blast radius:
[docs/security-notes.md](docs/security-notes.md).

## Acceptance checklist

See [docs/architecture.md](docs/architecture.md#acceptance) for how each spec
acceptance criterion maps to this implementation and how to verify it.

## Contributing, security, licence

- **Contributing:** [CONTRIBUTING.md](CONTRIBUTING.md), the gates are
  `make lint` + `npm test` (both Docker-free, both what CI runs); `make smoke`
  builds a real image and is a local gate only.
- **Security:** [SECURITY.md](SECURITY.md). Report privately, never in an issue.
  Read the model first: **a container is not a security boundary against a fully
  weaponized agent**, and several plausible reports are documented non-goals.
- **Licence:** [MIT](LICENSE).
- **Support:** none promised. This is self-hosted infrastructure published as-is
  in case it is useful; issues are read, but there is no SLA and no release
  cadence: `main` is the version.
