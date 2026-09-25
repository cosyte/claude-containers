---
name: claude-containers
description: >-
  Operate and understand the claude-containers repo: the self-hosted Docker
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
= one git repo (or several, as sibling checkouts under /workspace), reachable two ways at once: SSH into a persistent tmux session,
and the Claude mobile app's Remote Control (Code tab). Auth is a Claude **Max**
subscription via OAuth, **never API keys**.

When helping the user, first classify intent (build / auth / run / customize /
debug), then act with the exact command or file below. Prefer the `bin/`
scripts over raw `docker` so labels, ports, and volumes stay consistent. Make
small descriptive commits as you change things.

## Mental model (load this before reasoning about the repo)

- **Two access paths per container, simultaneously.** SSHing in attaches to a
  tmux session named `claude` that is already running Claude Code (so
  disconnects don't kill it). The same session is also driven from the phone
  via `--remote-control` (outbound HTTPS only, no inbound port).
- **Volume split (deliberate deviation from a naive single shared dir):**
  - `claude-auth`: **shared** across all containers, mounted `/auth`. Holds
    only the OAuth `.credentials.json`. Written once by `make login`.
  - `claude-sshkeys`: **shared**, persistent SSH host keys (stable
    fingerprint across rebuilds).
  - `claude-config-<project>`: **per container**, mounted
    `/home/claude/.claude` (= `CLAUDE_CONFIG_DIR`). All session/history/state.
  - `claude-ws-<project>`: **per container**, `/workspace` (the git repo).
    `--workspace <path>` bind-mounts a host checkout instead.
  - `claude-scratch-<project>`: **per container**, `/scratch`, and **`TMPDIR`
    points at it**. `/tmp` is a tmpfs (RAM, 1g, charged to the memory cgroup), so
    without this a pip/uv wheel build or a big archive dies at 1 GiB with
    ENOSPC while the pool has TBs free, and a bigger tmpfs would just turn that
    into an OOM kill instead. Cleared on every boot (it is scratch, not state);
    `claude-rm --purge` deletes it. `bash_profile` re-exports TMPDIR for SSH
    logins, which get a fresh env from sshd.
  - Rationale: a single shared `~/.claude` would corrupt concurrent sessions
    and collide on the `/workspace` project key. A background loop in the
    entrypoint keeps `.credentials.json` converged between `/auth` and each
    container so one login serves all and refreshed tokens propagate.
- **Bake-ins are merged on start, filling only what's absent**, so
  per-container state is never clobbered. Override anything by mounting onto
  its target path.

## Hard invariants, never violate or suggest otherwise

- **Never set `ANTHROPIC_API_KEY`.** The entrypoint hard-fails if it's
  non-empty (prevents silent per-token billing). `.env.example` keeps it
  commented; the launcher refuses early if it's set.
- **Never use `claude --bare`.** It forces API-key-only auth and disables
  plugins/CLAUDE.md: incompatible with this stack's OAuth + bake-ins.
- **Never set `DISABLE_TELEMETRY`, `DO_NOT_TRACK`, or
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`** (env or settings.json `env`).
  Each short-circuits the GrowthBook fetch, so the `tengu_ccr_bridge` gate
  defaults false and Remote Control fails with "not yet enabled for your
  account": even on an eligible account. RC is the point of this image.
  `DISABLE_AUTOUPDATER=1` is safe (unrelated to flags) but is NOT set by
  default: auto-update is on by default now, so a running container's Claude
  Code binary can self-update past the pinned CLAUDE_CODE_VERSION unless an
  operator sets `DISABLE_AUTOUPDATER=1` themselves. The entrypoint
  self-heals older config volumes (strips these keys + clears the stale flag
  cache). This was a real, shipped-then-fixed defect: see
  docs/troubleshooting.md "Remote Control".
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
- Pinned/verified Claude Code: **2.1.280** (min 2.1.52 for Remote Control). `--model opus` tracks the LATEST Opus: **Opus 5.5** (1M context) from CLI 2.1.280, Opus 5 from 2.1.219, Opus 4.8 from 2.1.154, the 2.1.145 pin silently gave Opus 4.7. A bump can therefore change the fleet's MODEL, not just the CLI; pin `CLAUDE_MODEL=claude-opus-5` (or `claude-opus-4-8`) to hold a container back.
  Everything was verified against that binary, not just docs.

## Codebase map

| Path | What it is |
|---|---|
| `Dockerfile` | `node:24-trixie-slim`; uv via a named throwaway stage (BuildKit forbids var-expansion in `COPY --from`); apt toolchain + `gh`; npm-pinned Claude Code; reuses base 1000:1000 user as `claude`; hardened sshd. |
| `entrypoint.sh` | Root → refuse API key → (login mode) → fix volume perms → host keys → authorized_keys → git key/identity → credential reconcile loop → seed `.claude.json` trust → merge bake-ins (CLAUDE.md, settings, plugins, commands, skills) → workspace (use/clone/fail) → register MCP via CLI → `sshd` → `gosu claude tmux` running `claude-session` → stay PID 1 with signal traps. |
| `bin/claude-session` | tmux pane cmd: `cd /workspace`, `exec claude --dangerously-skip-permissions --remote-control "<project>" $EXTRA`; falls back to a shell so SSH stays usable. |
| `bin/claude-dev` | tmux `dev`-window cmd: runs `$CLAUDE_DEV_CMD` (a dev server) in `/workspace` on boot, shell fallback. Started by the entrypoint only when `CLAUDE_DEV_CMD` is set. |
| `bin/_common.sh` | Shared lib: `.env` load, defaults, `sanitize`, volume names, `alloc_port` (2200-2299, skips used), state checks, `print_connect`. |
| `bin/claude-launch` | Create/start a container; auto port; labels carry metadata; surfaces a fast-failing entrypoint. `--expose H:C` / `--dev-cmd` publish + auto-start a dev server; `--browser` enables the chrome-devtools MCP for frontend debugging (needs a WITH_BROWSER=1 image). |
| `bin/claude-list/attach/stop/rm/logs` | Manage containers. `claude-attach` opens the live tmux session via `docker exec` (local, no SSH key). `claude-rm --purge` also deletes the per-project volumes. |
| `bin/claude-tui` | `whiptail` menu over the whole fleet, grouped by compose stack (discovered live from `com.docker.compose.project*` labels, no hardcoded paths; pre-seed a stack with zero containers via `CLAUDE_TUI_STACKS`). Per-session: attach/start/stop/restart/logs/remove/connect-info. Per-stack: bring up a dormant (never-created) repo, switch which auth account it uses (edits its `.env`'s `AUTH_VOLUME`, regenerates via its sibling `*.conf`, recreates only the containers actually running, by service name, so an already-running dormant-profile container is never silently skipped by a bare `up -d`), regenerate its compose. Accounts screen wraps `claude-account-list`/`claude-account-login`. Disk screen wraps `claude-disk-gc`/`-verify`. Pure navigation: shells out to the scripts here, no duplicated logic. Needs `whiptail` (the `newt` package). |
| `bin/claude-compose-gen` | Generate a multi-service `docker-compose.yml` (one session per repo in a GitHub org via `gh`, or explicit `repo[:branch]` args). Stable ports (reserves ports used by any `claude.managed` container host-wide), shared+per-repo volumes, `claude.managed` labels so `claude-list` sees them. `--scenario <file>` reads a persisted `.conf` of flags; `--env-file <file>` layers a per-stack env for multi-stack hosts. |
| `scenarios/example.conf.example` | Documented template for a `--scenario` `.conf` (persisted generator flags). Real scenario files live with the compose, outside this repo. |
| `bash_profile` | Interactive SSH → `exec tmux attach -t claude`; non-interactive SSH untouched. |
| `sshd_config` | Pubkey-only, no root, `AllowUsers claude`, persistent host keys. |
| `claude-config/` | Bake-in template: `CLAUDE.md`, `mcp/` (`.json.example` = inactive), `plugins/plugins.json`, `commands/*.md`, `skills/<name>/SKILL.md`. |
| `docker-compose.yml` | One-container equivalent of the launcher (needs explicit `SSH_PORT`); assumes default shared-volume names. |
| `Makefile` | `build` (host arch, loaded), `build-all`/`push` (amd64+arm64 via buildx), `login`, `launch/list/attach/stop/rm/logs`, `lint`, `smoke` (build + smoke test), `clean`. |
| `.env.example` | Every tunable, documented. Copy to `.env`. |
| `test/smoke.sh` | Automated acceptance for everything that doesn't need real OAuth/phone. |
| `test/unit.sh` | Docker-free unit tests (version-floor helper, warn-only runc posture, the §0 retired-env guard, and the prune gates: the removed bins stay removed, `CLAUDE_CONTROLLER=1` is refused, and the autopilot never invokes `claude` without a command). Also pins that the removed per-session Docker engine stays removed at every live site. |
| `bin/claude-gpu` | In-container NVIDIA GPU guard (baked): `status` (ok / degraded (reason) / off), `run -- cmd` (waits for free VRAM, low utilization and few NVENC sessions on the SHARED card, else CPU; retries a GPU OOM once on CPU; says which device ran), `blender` (Cycles OptiX, else CUDA, else CPU via `--cycles-device`), `env gpu|cpu` (the device contract). |
| `bin/claude-blender-install` | Baked: installs the pinned, SHA-256-verified Blender LTS rootless into the shared `/cache/blender/<ver>` under a lock (fail closed on a checksum mismatch; blender.org then two official mirrors). `blender` on PATH runs it. |
| `test/gpu-unit.sh` | Docker-free `--gpu` tests: generator emission (CDI device, RAM `/scratch`, `CLAUDE_GPU=1`, runc, cap_drop kept, non-GPU services byte-identical, unknown repo refused), `claude-launch --gpu` args against a stubbed docker, the guard against a fake `nvidia-smi` (idle / busy co-tenant / short VRAM / OOM then CPU / NVML failure / hang), the installer failing closed, §2b degrading without failing the boot, the healthcheck GPU line: CI. |
| `test/launch-unit.sh` | Docker-free tests for the container boundary: `harden_run_args` (cap-drop ALL + no-new-privileges), no `--privileged` / host socket anywhere, the removed `--docker`/`--no-docker`/`--sysbox` flags refusing, every compose service on plain runc, and the disk-backed `/scratch`: CI. |
| `test/sizing-unit.sh` | Docker-free sizing tests (size/reservation math, K resolution from config, compose reservation/pids emission): CI. |
| `test/disk-unit.sh` | Docker-free disk tests (`disk_free_mib` parse/fail-closed, `claude-disk-gc`'s plan safety): CI. |
| `bin/claude-disk-gc` | Standalone maintenance tool: `docker system prune -f` + `docker builder prune -f` (a fixed plan, never `-a`/`--volumes`), plus the shared-cache trim; one-shot or `--loop`; fail-safe. No entrypoint path auto-starts it. |
| `bin/claude-disk-verify` | Docker-free sanity pass re-running the disk-hygiene logic (free-space parsing, gc-plan safety, cache-trim safety): safe anywhere, no docker needed. |
| `docs/` | `architecture.md` (decisions + acceptance map), `legacy-sysbox-broker.md` (the retired nested-Sysbox worker-broker substrate, frozen implementation + rationale), `customizing-bakeins.md`, `troubleshooting.md`. |

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
./bin/claude-launch <name> [--port N] [--mcp foo] [--browser] [--extra-args "…"]
./bin/claude-launch <name> [--expose 4321:4321] [--dev-cmd "npm run dev …"]
./bin/claude-launch <name> --gpu               # the host's NVIDIA GPU via CDI (needs the toolkit's CDI spec)
./bin/claude-launch <name> --repo URL --repo URL#BRANCH   # several repos: /workspace/<repo> each
./bin/claude-list                       # name, state, ssh port, repo, uptime
./bin/claude-attach <name>              # attach to its live tmux session (local)
./bin/claude-stop <name>                # graceful; state preserved
./bin/claude-launch <name>              # resumes (docker start): no --repo;
                                        #   launch options are ignored on resume
./bin/claude-rm <name> [--yes] [--purge]
./bin/claude-logs <name> [-n LINES]     # entrypoint/sshd log, not the session
./bin/claude-tui                        # interactive whiptail menu: stacks, accounts, sessions, disk (wraps all of the above)
```
Connect: the launcher prints `ssh -p <port> claude@<host>` and the app session
name (= project name; green dot when online). `bin/` on `PATH` drops `./bin/`.
`make <verb> ARGS="…"` wraps the scripts.

**Many repos at once**
```
./bin/claude-compose-gen --org ORG --out FILE --active repo-a --active repo-b,repo-c
./bin/claude-compose-gen --out FILE repo-a repo-b:branch    # explicit, no gh
./bin/claude-compose-gen --org ORG --out FILE --active site --expose site:4321:4321
./bin/claude-compose-gen --scenario /path/stack.conf        # persisted flags (see below)
docker compose -f FILE up -d                       # active only
docker compose -f FILE --profile dormant up -d     # all
docker compose -f FILE up -d <repo>                # one on demand / add a new repo
```
`--org` and `--out` are required (no host/org defaults, shared tool); `--out`
must be outside the repo (the generator refuses in-repo paths). `--active`
repos start by default; the rest are behind the `dormant` Compose profile
(zero resources until requested). **SSH ports are preserved**: if `--out`
already exists each repo keeps its prior port and only new repos get the next
free one: adding a repo never reshuffles running containers (regenerate, then
`up -d <newrepo>`). `--expose REPO:HOST:CONTAINER` publishes an extra port
(dev server); the dev server must bind `0.0.0.0` inside the container to be
reachable. Default Astro/Vite/Next dev ports: 4321 / 5173 / 3000.
`--dev-cmd REPO=COMMAND` sets `CLAUDE_DEV_CMD` for that service so the
entrypoint auto-starts it on boot in a separate tmux `dev` window
(`tmux select-window -t claude:dev` to watch it; `claude-dev` to rerun).
Pair `--expose` + `--dev-cmd` for a browsable dev site.
`--marketplace REPO=NAME=URL` and `--plugin REPO=PLUGIN[,…]` write
`CLAUDE_EXTRA_MARKETPLACES` / `CLAUDE_EXTRA_PLUGINS` onto a service; the
entrypoint merges them into `settings.json` on every boot (existing user
entries win on conflict, so per-container edits stick). No rebuild needed. Two real gotchas:
the dev server **must bind 0.0.0.0** (localhost = published port reaches
nothing); and `npm run` needs `-- ` before forwarded flags while
`pnpm`/`yarn` must NOT get a literal `--` (it makes Astro/Vite ignore
`--host`). pnpm/yarn/npm are baked into the image (no runtime PM download:
a corepack fetch timed out in practice). Verified dev-cmd pattern:
`if [ -f pnpm-lock.yaml ]; then PM=pnpm;SEP=; elif [ -f yarn.lock ]; then PM=yarn;SEP=; else PM=npm;SEP=--; fi; [ -d node_modules ] || $PM install; exec $PM run dev $SEP --host 0.0.0.0 --port 4321`
Needs `gh` authed with `repo`+`read:org` (a personal fine-grained PAT scoped
to the user usually CANNOT see an org's private repos: use a classic token
or an org-scoped one). Containers still clone over the mounted SSH git key at
runtime, so API access is only needed for *enumeration*. Prerequisites the
generator warns about: `make build`, `make login`, `~/.ssh/authorized_keys`,
`~/.ssh/claude-git-key` (deploy key with org access).

**Scenarios + multiple stacks (per-stack env files)**
```
./bin/claude-compose-gen --scenario /srv/claude/work/work.conf
./bin/claude-compose-gen --scenario /srv/claude/personal/personal.conf
```
A **scenario `.conf`** is the generator's own flags PERSISTED: one
`--flag [value]` per line, `#` comments, blank lines skipped; the value is the
literal rest-of-line so spaces/`;`/`$`/`=` need no quoting (see
`scenarios/example.conf.example`). This fixes the old foot-gun that per-repo
flags lived only on the CLI and got silently dropped on regen. Flags in the file
apply first; CLI flags after `--scenario` override a scalar or append to a
repeatable (`--scenario work.conf --active newrepo`). `--scenario` takes a
path; a bare name resolves under `CLAUDE_SCENARIOS_DIR`. Scenario files are
deployment config: keep them **with the compose, outside this repo**.

To run **two independent stacks on one host** (e.g. an `your-org/*` work stack and a
`you/*` personal stack), give each its own dir + `.conf` + `.env`:
```
/srv/claude/work/{work.conf,.env,docker-compose.yml}          # ports 2200-2249
/srv/claude/personal/{personal.conf,.env,docker-compose.yml}  # ports 2250-2299
docker compose -f /srv/claude/work/docker-compose.yml up -d
docker compose -f /srv/claude/personal/docker-compose.yml up -d
```
`--env-file <path>` (usually set inside the `.conf`) is sourced ON TOP of the
repo `.env` at generation time (SSH port range, image, resources), and, because
it sits **beside `--out`**: `docker compose` auto-loads the SAME file at `up`,
which is how each stack gets its own `GH_TOKEN`. Keep the base `.env` for shared
settings; the per-stack `.env` holds only what differs (`GH_TOKEN`, a disjoint
`SSH_PORT_RANGE_*`, optional image/model/resource overrides). Precedence:
ambient env < base `.env` < `CLAUDE_ENV_FILE` < CLI. The generator also reserves
ports held by **any** `claude.managed` container host-wide (other stacks + a
standalone `super`), so a new repo never collides across stacks; disjoint ranges
are still the primary guard.

**Multi-arch / publish:** `make build-all` (no local load) or
`make push` (set `CLAUDE_IMAGE` to a registry ref first).

**Frontend debugging:** `make build-browser` builds a `claude-code-box:browser`
variant baking headless Chromium + chrome-devtools-mcp (+~200 MB). Launch with
`--browser` (or `CLAUDE_BROWSER=1`, or `compose-gen --browser REPO`); the
entrypoint registers the chrome-devtools MCP so Claude can navigate / evaluate
/ screenshot / inspect console+network / run Lighthouse against a frontend.
Chromium is started with `--no-sandbox --disable-dev-shm-usage --disable-gpu`
(required in unprivileged Docker). The launcher checks the image's
`claude.browser` LABEL and warns early if `--browser` is used against the
lean image. Pair `--browser` with `--dev-cmd`/`--expose` so the agent both
runs and debugs the dev server.

**Several repos in one container:** `compose-gen --group NAME=REPO[:BRANCH],REPO,...`
(NAME is the service and takes every per-repo flag; it must not also be a single-repo
service) or `claude-launch` with several `--repo` (branch as `URL#BRANCH`). The entrypoint
clones each into `/workspace/<repo>` from `GIT_REPOS` and the session starts in
`/workspace`. Each boot clones only what is missing; existing checkouts are never touched.
Never combine with a single-repo workspace (refused: no nested repos), so a new group needs
a fresh `claude-ws-NAME` volume. `test/workspace-unit.sh` covers it.

**GPU sessions (`--gpu`, NVIDIA only):** `compose-gen --gpu REPO` (repeatable; the repo
must be in the stack) or `claude-launch --gpu` / `CLAUDE_GPU=1` gives the service the CDI
device `nvidia.com/gpu=all` on plain runc: `cap_drop: ALL` + the minimal set +
`no-new-privileges` unchanged, NO `runtime: nvidia`, no extra cap, no privilege.
`/scratch` becomes a RAM tmpfs (`CLAUDE_GPU_SCRATCH_TMPFS`, 4g), `CLAUDE_GPU=1` is set, and
the session gets a GPU note in `/etc/claude-code/CLAUDE.md` (managed memory, root-owned).
Toggling is regenerate + `docker compose up -d <svc>` (creation-time). Every image ships
glvnd + Mesa + Blender's X client libs; NEVER bake NVIDIA driver libs (CDI injects them,
matched to the host). Host needs the NVIDIA Container Toolkit's CDI spec: without it Docker
refuses to create the container (`unresolvable CDI devices`); the fix is on the host
(`nvidia-ctk cdi generate`), or drop `--gpu`. A broken driver (NVML mismatch after an
update without reboot) DEGRADES: banner in the log, red tmux status, healthcheck
`healthy; gpu: degraded (<reason>)`, never unhealthy. Inside, the agent uses
`claude-gpu status|run|blender` and `claude-blender-install`. The card is shared (media
server NVENC): always go through the guard.

**No Docker inside a session.** The per-session Docker engine (`--docker`) and the
Sysbox runtime it needed were removed; `--docker`, `--no-docker` and `--sysbox` now
refuse, naming the removal. Build and run containers on the host or in CI. Never
"restore" it with `--privileged` or a host socket mount: either hands a
prompt-injectable agent the host.

**Validate changes:** `make lint` (shell syntax, incl. `test/*.sh`), `npm test`
(all the docker-free suites listed in `package.json`'s `test` script, the same
set `.github/workflows/ci.yml` runs), and `make smoke` (builds the image, then runs
`test/smoke.sh` against it). The smoke test covers API-key hard-fail, both
fail-fast paths, bake-in merge, trust pre-accept, tmux, sshd, and
SSH-into-session. Real OAuth + the phone-app green-dot remain manual.

## Customizing bake-ins (rebuild after editing `claude-config/`)

- **CLAUDE.md** → global memory for every session; keep short.
- **MCP**: one `*.json` per server (filename = server name), registered at
  user scope. `.json.example` is inactive: rename to `.json`. Use `${VAR}`
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
- **skip-permissions vs Remote Control** → works on pinned 2.1.280: the top-level launch
  `claude --dangerously-skip-permissions --remote-control <name>` was verified to parse and
  start (as the unprivileged `claude` user), with no interlock between the two flags. This is
  why the CLI is pinned at all: re-verify on any bump. (The `claude remote-control`
  *subcommand*'s option surface is NOT asserted: it short-circuits on auth before parsing
  options, so it is unverifiable in-container.) `settings.json` also sets `defaultMode`.
  If a future version regresses, set
  `CLAUDE_PERMISSION_MODE=acceptEdits` and relaunch. Verify by sending a
  shell task from the app: it should run with no prompt.
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
and `docs/troubleshooting.md`: read them before proposing structural changes.

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
