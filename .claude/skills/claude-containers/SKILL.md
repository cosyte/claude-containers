---
name: claude-containers
description: >-
  Operate and understand the claude-containers repo — the self-hosted Docker
  stack for running isolated Claude Code sessions reachable via SSH/tmux and the
  Claude mobile app Remote Control. Use when the user asks to build the image,
  do the one-time OAuth login, launch / list / stop / remove / inspect session
  containers, customize the baked-in CLAUDE.md / MCP / plugins / commands /
  skills, run the smoke test, or troubleshoot auth, SSH, git, Remote Control,
  or workspace-trust problems in this project.
---

# claude-containers

A self-hostable Docker image plus bash launchers for running many isolated,
long-lived Claude Code coding sessions on one host. One container = one session
= one git repo, reachable two ways at once: SSH into a persistent tmux session,
and the Claude mobile app's Remote Control (Code tab). Auth is a Claude **Max**
subscription via OAuth — **never API keys**.

When helping the user, first classify intent (build / auth / run / customize /
debug), then act with the exact command or file below. Prefer the `bin/`
scripts over raw `docker` so labels, ports, and volumes stay consistent. Make
small descriptive commits as you change things.

## Mental model (load this before reasoning about the repo)

- **Two access paths per container, simultaneously.** SSHing in attaches to a
  tmux session named `claude` that is already running Claude Code (so
  disconnects don't kill it). The same session is also driven from the phone
  via `--remote-control` (outbound HTTPS only — no inbound port).
- **Volume split (deliberate deviation from a naive single shared dir):**
  - `claude-auth` — **shared** across all containers, mounted `/auth`. Holds
    only the OAuth `.credentials.json`. Written once by `make login`.
  - `claude-sshkeys` — **shared**, persistent SSH host keys (stable
    fingerprint across rebuilds).
  - `claude-config-<project>` — **per container**, mounted
    `/home/claude/.claude` (= `CLAUDE_CONFIG_DIR`). All session/history/state.
  - `claude-ws-<project>` — **per container**, `/workspace` (the git repo).
    `--workspace <path>` bind-mounts a host checkout instead.
  - Rationale: a single shared `~/.claude` would corrupt concurrent sessions
    and collide on the `/workspace` project key. A background loop in the
    entrypoint keeps `.credentials.json` converged between `/auth` and each
    container so one login serves all and refreshed tokens propagate.
- **Bake-ins are merged on start, filling only what's absent**, so
  per-container state is never clobbered. Override anything by mounting onto
  its target path.

## Hard invariants — never violate or suggest otherwise

- **Never set `ANTHROPIC_API_KEY`.** The entrypoint hard-fails if it's
  non-empty (prevents silent per-token billing). `.env.example` keeps it
  commented; the launcher refuses early if it's set.
- **Never use `claude --bare`.** It forces API-key-only auth and disables
  plugins/CLAUDE.md — incompatible with this stack's OAuth + bake-ins.
- **Install Claude Code via npm, pinned** (`@anthropic-ai/claude-code@<ver>`),
  never the native installer (auto-update + historical FS-scan OOM).
- **MCP secrets are runtime-only.** Baked `mcp/*.json` use `${VAR}`
  placeholders expanded by `envsubst` from container env at registration; real
  values come from `.env`. Never bake a secret into the image.
- **Plugins are declarative** via `settings.json` `extraKnownMarketplaces` +
  `enabledPlugins`; Claude Code syncs them on startup. Don't script
  `claude plugin install` in the entrypoint.
- **Workspace trust is pre-accepted** by seeding `.claude.json`
  (`hasCompletedOnboarding`, `projects["/workspace"].hasTrustDialogAccepted`).
- Pinned/verified Claude Code: **2.1.144** (min 2.1.52 for Remote Control).
  Everything was verified against that binary, not just docs.

## Codebase map

| Path | What it is |
|---|---|
| `Dockerfile` | `node:24-bookworm-slim`; uv via a named throwaway stage (BuildKit forbids var-expansion in `COPY --from`); apt toolchain + `gh`; npm-pinned Claude Code; reuses base 1000:1000 user as `claude`; hardened sshd. |
| `entrypoint.sh` | Root → refuse API key → (login mode) → fix volume perms → host keys → authorized_keys → git key/identity → credential reconcile loop → seed `.claude.json` trust → merge bake-ins (CLAUDE.md, settings, plugins, commands, skills) → workspace (use/clone/fail) → register MCP via CLI → `sshd` → `gosu claude tmux` running `claude-session` → stay PID 1 with signal traps. |
| `bin/claude-session` | tmux pane cmd: `cd /workspace`, `exec claude --dangerously-skip-permissions --remote-control "<project>" $EXTRA`; falls back to a shell so SSH stays usable. |
| `bin/_common.sh` | Shared lib: `.env` load, defaults, `sanitize`, volume names, `alloc_port` (2200–2299, skips used), state checks, `print_connect`. |
| `bin/claude-launch` | Create/start a container; auto port; labels carry metadata; surfaces a fast-failing entrypoint. |
| `bin/claude-list/stop/rm/logs` | Manage containers; `claude-rm --purge` also deletes the per-project volumes. |
| `bin/claude-compose-gen` | Generate a multi-service `docker-compose.yml` (one session per repo in a GitHub org via `gh`, or explicit `repo[:branch]` args). Stable ports, shared+per-repo volumes, `claude.managed` labels so `claude-list` sees them. |
| `bash_profile` | Interactive SSH → `exec tmux attach -t claude`; non-interactive SSH untouched. |
| `sshd_config` | Pubkey-only, no root, `AllowUsers claude`, persistent host keys. |
| `claude-config/` | Bake-in template: `CLAUDE.md`, `mcp/` (`.json.example` = inactive), `plugins/plugins.json`, `commands/*.md`, `skills/<name>/SKILL.md`. |
| `docker-compose.yml` | One-container equivalent of the launcher (needs explicit `SSH_PORT`); assumes default shared-volume names. |
| `Makefile` | `build` (host arch, loaded), `build-all`/`push` (amd64+arm64 via buildx), `login`, `launch/list/stop/rm/logs`, `lint`, `clean`. |
| `.env.example` | Every tunable, documented. Copy to `.env`. |
| `test/smoke.sh` | Automated acceptance for everything that doesn't need real OAuth/phone. |
| `docs/` | `architecture.md` (decisions + acceptance map), `customizing-bakeins.md`, `troubleshooting.md`. |

## Operational playbook

**First-time setup**
```
cp .env.example .env          # edit if needed; defaults are sane
make build                    # host-arch image, loaded locally
make login                    # one-time OAuth; opens a URL, paste the code
```
`make login` runs a throwaway container with `CLAUDE_LOGIN_MODE=1` and
`CLAUDE_CONFIG_DIR=/auth`, persisting creds to the `claude-auth` volume.

**Launch / manage**
```
./bin/claude-launch <name> --repo git@github.com:you/x.git [--branch B] [--depth N]
./bin/claude-launch <name> --workspace /abs/path/to/checkout
./bin/claude-launch <name> [--port N] [--mcp foo --mcp bar] [--extra-args "…"]
./bin/claude-list                       # name, state, ssh port, repo, uptime
./bin/claude-stop <name>                # graceful; state preserved
./bin/claude-launch <name>              # resumes (docker start) — no --repo
./bin/claude-rm <name> [--yes] [--purge]
./bin/claude-logs <name> [-n LINES]     # entrypoint/sshd log, not the session
```
Connect: the launcher prints `ssh -p <port> claude@<host>` and the app session
name (= project name; green dot when online). `bin/` on `PATH` drops `./bin/`.
`make <verb> ARGS="…"` wraps the scripts.

**Many repos at once**
```
./bin/claude-compose-gen --org cosyte --out /opt/homelab/docker-compose.yml
./bin/claude-compose-gen repoA repoB:branch        # explicit, no gh
docker compose -f /opt/homelab/docker-compose.yml up -d
```
Needs `gh` authed with `repo`+`read:org` (a personal fine-grained PAT scoped
to the user usually CANNOT see an org's private repos — use a classic token
or an org-scoped one). Containers still clone over the mounted SSH git key at
runtime, so API access is only needed for *enumeration*. Prerequisites the
generator warns about: `make build`, `make login`, `~/.ssh/authorized_keys`,
`~/.ssh/claude-git-key` (deploy key with org access).

**Multi-arch / publish:** `make build-all` (no local load) or
`make push` (set `CLAUDE_IMAGE` to a registry ref first).

**Validate changes:** `make lint` (shell syntax) and
`IMAGE=claude-code-box:test test/smoke.sh` after a build. The smoke test
covers API-key hard-fail, both fail-fast paths, bake-in merge, trust
pre-accept, tmux, sshd, and SSH-into-session. Real OAuth + the phone-app
green-dot remain manual.

## Customizing bake-ins (rebuild after editing `claude-config/`)

- **CLAUDE.md** → global memory for every session; keep short.
- **MCP**: one `*.json` per server (filename = server name), registered at
  user scope. `.json.example` is inactive — rename to `.json`. Use `${VAR}`
  and supply values via `.env`. Subset with `--mcp` / `CLAUDE_MCP_ENABLED`.
- **Plugins**: edit `claude-config/plugins/plugins.json`
  (`extraKnownMarketplaces` + `enabledPlugins`, keys `"<plugin>@<mkt>"`).
- **Commands**: `claude-config/commands/*.md` (optional `description:`
  frontmatter) → `/name`.
- **Skills**: one dir per skill with `SKILL.md` (frontmatter `name:` +
  `description:`).
- Runtime override without rebuild: `docker`/compose mount onto the target
  path (e.g. your own `CLAUDE.md` onto `/home/claude/.claude/CLAUDE.md`).

## Troubleshooting decision guide

- **Container exits instantly** → `claude-launch` prints the last 30 log
  lines. Common: `ANTHROPIC_API_KEY` set (remove it), no creds (`make login`),
  empty workspace + no `--repo`, unreadable mounted key.
- **App session missing / no green dot** → needs ≥2.1.52 + open outbound 443;
  check `claude-logs` shows "started in tmux"; same Max account as login.
- **skip-permissions vs Remote Control** → works on pinned 2.1.144
  (`remote-control --permission-mode` accepts `bypassPermissions`, and
  `settings.json` sets `defaultMode`). If a future version regresses, set
  `CLAUDE_PERMISSION_MODE=acceptEdits` and relaunch. Verify by sending a
  shell task from the app — it should run with no prompt.
- **SSH refused/closed** → no `authorized_keys` mounted, wrong port
  (`claude-list`), or stale host key after removing `claude-sshkeys`
  (`ssh-keygen -R`). A closed-then-shell means the Claude pane exited;
  relaunch with `claude-session`.
- **Git push fails** → `GIT_SSH_KEY` missing/not authorized on the remote;
  public/https still clone. Wrong author → set `GIT_AUTHOR_*` in `.env`.
- **Auth went stale across containers** → reconcile loop converges every ~30s;
  restart the container to re-seed immediately; full reset
  `docker volume rm claude-auth && make login`.

Deeper detail and the spec-acceptance mapping live in `docs/architecture.md`
and `docs/troubleshooting.md` — read them before proposing structural changes.

## How to help

1. Identify intent (build / login / launch / manage / customize / debug).
2. Run the matching `bin/` script or `make` target; show the user the printed
   connect info verbatim.
3. For edits, respect the hard invariants above, change the smallest surface,
   `make lint` (and smoke-test if the image is built), then commit a tight,
   descriptive message and push.
4. If the user proposes something that breaks an invariant (API key, `--bare`,
   single shared config dir, baked secrets), say so and offer the correct
   approach instead of complying.
