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

## Environment variables

Set in `.env` (auto-loaded by the scripts and passed into containers). Real env
vars override `.env`. Full reference: `.env.example`.

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDE_IMAGE` | `claude-code-box:latest` | Image tag built/run |
| `CLAUDE_CODE_VERSION` | `2.1.144` | Pinned Claude Code npm version (min 2.1.52) |
| `NODE_VERSION` | `24` | Base Node LTS |
| `UV_VERSION` | `latest` | `uv` version (pin for reproducibility) |
| `CLAUDE_UID`/`CLAUDE_GID`/`CLAUDE_USER` | `1000`/`1000`/`claude` | Container user |
| `CLAUDE_PERMISSION_MODE` | `bypassPermissions` | `default`/`acceptEdits`/`bypassPermissions` |
| `CLAUDE_EXTRA_ARGS` | — | Extra args to `claude` (or `--extra-args`) |
| `CLAUDE_MCP_ENABLED` | — | CSV of baked MCP servers to load (empty = all) |
| `GIT_REPO_URL`/`_BRANCH`/`_DEPTH` | — | Clone source (or use `--repo`/`--branch`/`--depth`) |
| `GIT_AUTHOR_NAME`/`_EMAIL` (+`COMMITTER`) | host git config | Commit identity |
| `GIT_SSH_KEY` | `~/.ssh/claude-git-key` | Host SSH key for git, mounted read-only |
| `SSH_AUTHORIZED_KEYS` | `~/.ssh/authorized_keys` | Host pubkeys allowed to SSH in (read-only) |
| `SSH_PORT_RANGE_START`/`_END` | `2200`/`2299` | Auto-assigned host SSH port range |
| `CLAUDE_SSH_HOST` | this host's name | Hostname shown in the connect line |
| `CLAUDE_CPU_LIMIT`/`CLAUDE_MEM_LIMIT` | `2`/`4g` | Per-container resource caps |
| `CLAUDE_SHM_SIZE` | `2g` | `/dev/shm` size |
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
                      [--port N] [--mcp NAME ...] [--extra-args "…"]
claude-list                       table of all sessions
claude-stop  <name>               graceful stop (state preserved)
claude-rm    <name> [--yes] [--purge]   remove (+volumes with --purge)
claude-logs  <name> [-n LINES]    tail the entrypoint/sshd log
```

`make launch ARGS="…"`, `make stop ARGS="…"` etc. wrap these if you prefer Make.

### Many repos at once

`claude-compose-gen` writes a multi-service `docker-compose.yml` with one
session container per repo in a GitHub org:

```
claude-compose-gen [--org cosyte] [--out /opt/homelab/docker-compose.yml]
                   [--include GLOB] [--exclude GLOB] [--forks] [--archived]
claude-compose-gen myrepo otherrepo:dev      # explicit list, no gh needed
```

It enumerates via an authenticated `gh` (scopes `repo` + `read:org`) or takes
explicit `repo[:branch]` args, assigns stable SSH ports from the configured
range, shares `claude-auth`/`claude-sshkeys` with per-repo config/workspace
volumes, and labels services so they still show up in `claude-list`. Then:
`docker compose -f <out> up -d`. Regenerate any time the repo set changes
(ports stay stable — services are sorted by name).

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
  one repo. Use `CLAUDE_PERMISSION_MODE=acceptEdits` if you want shell commands
  to still prompt in the app.
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
- Egress is open by default (Claude, npm, git, MCP all need it). Locking it
  down: [docs/troubleshooting.md](docs/troubleshooting.md#restricting-egress).

## Acceptance checklist

See [docs/architecture.md](docs/architecture.md#acceptance) for how each spec
acceptance criterion maps to this implementation and how to verify it.
