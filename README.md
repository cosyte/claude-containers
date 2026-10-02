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

> **Retired features you may find references to.** An earlier version ran a
> nested-Sysbox **worker broker**: a controller container that spawned autonomous
> nested worker containers (`--broker`/`--sysbox`). It was retired on 2026-07-12 in
> favour of Claude Code subagents in git worktrees, and is frozen on branch
> `legacy/sysbox-broker-2026-07-12` (tag `legacy-sysbox-broker-2026-07-12`), which
> is **not maintained**. The later per-session Docker engine (`--docker`), the last
> thing that needed that runtime, was removed too: every session now runs on plain
> `runc`. Removed flags *refuse* with an error naming the removal rather than
> silently doing nothing. Background:
> [docs/legacy-sysbox-broker.md](docs/legacy-sysbox-broker.md).

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
 │                        │             │            ├─ main: claude \     │
 │                        │             │            │   --dangerously-    │
 │                        │             │            │   skip-permissions  │
 │                        │             │            │   --remote-control  │
 │                        │             │            │   "<project>"       │
 │                        │             │            └─ <name>: claude …   │
 │                        │             │                --remote-control  │
 │                        │             │                "<project>-<name>"│
 └────────────────────────┘             └───────┬──────────────────────────┘
                                                 │ outbound HTTPS only
 Claude mobile app  ◀───── Remote Control ───────┘  (no inbound port)

 volumes:
   claude-auth          (shared)  OAuth credentials   → /auth
   claude-sshkeys       (shared)  SSH host keys        → /etc/ssh/host-keys
   claude-config-<proj> (per ctr) sessions + state     → /home/claude/.claude
   claude-ws-<proj>     (per ctr) the git repo         → /workspace
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
| `CLAUDE_GPU` | `0` | `1`/`--gpu` gives the session the host's NVIDIA GPU through CDI (see [GPU sessions](#gpu-sessions-optional)); `--no-gpu` opts out of an ambient `1`. Fixed at container creation. |
| `CLAUDE_GPU_SCRATCH_TMPFS` | `4g` | Size of the RAM `/scratch` a GPU session gets instead of the disk volume. Charged to `CLAUDE_MEM_LIMIT`. |
| `GIT_REPO_URL`/`_BRANCH`/`_DEPTH` |: | Clone source (or use `--repo`/`--branch`/`--depth`) |
| `GIT_REPOS` |: | Several repos in one container: whitespace-separated `URL[#BRANCH]`, each cloned into `/workspace/<repo>` (set by `claude-compose-gen --group` or several `--repo`). Not together with `GIT_REPO_URL` |
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

## Several repos in one container

A session normally owns one repo, cloned into `/workspace`. When the work spans repos (a
part, the board it mounts to, the notes about both), one container can hold several: each
is cloned into `/workspace/<repo>` and the session starts in `/workspace`, so it reads,
edits and commits across all of them. Every repo keeps its own git history and remote;
each repo's own `CLAUDE.md` still applies inside it.

```
# a stack service (scenario .conf, or the generator's command line)
--group maker=you/home,you/3d,you/keys:dev
--active maker
# a standalone container
claude-launch maker --repo git@github.com:you/home.git --repo git@github.com:you/3d.git
```

The group's name is the service (`claude-maker`, its Remote Control session name) and
takes every per-repo flag (`--active`, `--gpu`, `--cpu`, `--mem`, ...); it must not also be
one of the stack's single-repo services. A branch is `repo:branch` in `--group` and
`URL#BRANCH` with `--repo`. Each boot clones only the repos that are missing, so adding one
to the list and restarting brings it in, and an existing checkout is never touched. The
container passes the list as `GIT_REPOS`; it cannot be combined with a single-repo
workspace (a repo at `/workspace` itself), so a multi-repo service starts from a fresh
workspace volume.

## Several sessions in one container

Every container runs its own session in tmux window `main` (Remote Control name = the
project). It can run more, started at boot: each in its own tmux window, with its own
Remote Control link (`<project>-<name>`, so each shows up separately in the Claude app;
`main` becomes `<project>-main` alongside them, or `CLAUDE_MAIN_NAME`),
working directory, model, permission mode, and an optional first prompt or `/goal`. They
share the container's workspace, tools, credentials and resources, which makes this the
natural shape for several lanes of work over one checkout, or one session per repo of a
multi-repo container.

```
# a standalone container: main + one session per repo, plus a read-only reviewer
claude-launch maker --repo git@github.com:you/api.git --repo git@github.com:you/web.git \
    --session '*' --session 'review dir=api model=sonnet mode=plan'

# a stack service (scenario .conf lines, or the generator's command line)
--group maker=you/api,you/web,you/docs
--session maker=api goal=docs/first.goal.txt
--session maker=web
--session maker=review dir=api model=sonnet mode=plan
--env maker=CLAUDE_MAIN_RESUME=1
```

A session spec is `NAME [key=value ...]`, several separated by `;` (the flag repeats too):

| Key | Meaning |
|---|---|
| `NAME` | lowercase letters, digits, `-`, `_`: the tmux window and the Remote Control suffix. `main`, `dev`, `scm` are taken. `*` is one session per git repo directly under `/workspace`, named after the repo (a named entry wins its name). |
| `dir=` | working directory, absolute or relative to `/workspace`. Default: `/workspace/NAME` when it is a directory, else `/workspace`. |
| `model=` / `mode=` | model alias or id / permission mode for this session (default: the container's). |
| `goal=FILE` | on its **first** start, begin with `/goal <contents of FILE>` (FILE relative to `dir`). |
| `prompt-file=FILE` | on its first start, begin with the contents of FILE. |
| `rc=off` | no Remote Control link (SSH / tmux only). |
| (names) | every session is named `<project>-<window>`, as its Remote Control name and its display name (`--name`), on every start: a resumed conversation reuses its old Remote Control session and would otherwise keep that session's old name in the app. |
| `resume=off` | a fresh conversation on every boot. By default a named session **resumes its last conversation** when the container restarts; main does not unless `CLAUDE_MAIN_RESUME=1`. |

`claude-launch` and `claude-compose-gen` validate the spec with the container's own
parser, so a typo fails the launch or the generation, not the boot. One removed
setting is the exception: `chain` (and `claude-sessions new --chain`, and the
`CLAUDE_GOAL_CHAIN_REVIEW` variable) belonged to a goal runner that no longer ships in this
image. A container still declared with them boots as before, each such session as a plain
session, with a warning in the boot log and from the generator; drop the word at the next
regeneration. A tool of that kind now comes in from outside the image. Inside, and from the
host with `claude-sessions -C <project> …`:

```
claude-sessions                        # ls: every session, its state (busy/idle/exited/stopped), dir, Remote Control, conversation
claude-sessions new review --dir home --model sonnet --prompt "Review the last 5 commits"
claude-sessions attach home            # or Ctrl-b w in tmux, or from the host: claude-attach maker home
claude-sessions send home "Run the tests and fix what fails"
claude-sessions restart home [--fresh] # resume its conversation in a new process (or start over)
claude-sessions restart home --resume ID   # take over conversation ID (e.g. one copied in from another container)
claude-sessions stop home              # stays stopped across restarts, until: claude-sessions start home
claude-sessions reset home             # forget its conversation; the next start re-sends its first prompt
claude-sessions rm review              # a `new` session only; a declared one is stopped instead
```

Sessions from `--session` (`CLAUDE_SESSIONS`) are the container's declaration: reconciled
on every boot, so an entry dropped from it is unregistered on the next recreate. Sessions
from `claude-sessions new` persist on the config volume and come back after a restart. A
first prompt or goal is sent exactly once (the start is recorded before Claude runs), so
a restart never replays goal 1 over a session that is on goal 4. What keeps several
sessions honest:

- **Resume is exact.** A supervisor records which conversation each window runs (from
  Claude Code's own `sessions/<pid>.json`, so it follows a `/clear`), and a restart resumes
  that one with `--resume <id>`. `--continue` is only a fallback, and only when no other
  session works in the same directory, where it could pick up a sibling's conversation.
- **Recovery is per session.** Every session with a Remote Control link gets its own RC
  watchdog, debug log (`/tmp/claude-rc-debug-<name>.log`) and respawn lock, and a restart
  kills only its own pane's processes. The usage-limit watchdog resumes every session that
  hit the limit, each with its own conversation.
- **Health stays about the container.** `docker ps` / `claude-list` read
  `healthy; sessions: 2/3 up (3d: claude exited)`: a named session never makes the
  container unhealthy (that would restart every session in it); main still does.
- **Capacity is shared.** The boot log says what each session gets (`Capacity: 4 Claude
  sessions share 16384 MiB (~4096 MiB each)`) and warns under 1 GiB each: a Claude process
  alone uses 300-600 MiB, and an OOM kill lands on whichever session the kernel picks.
  Raise `--mem` / `CLAUDE_MEM_LIMIT` with the session count. Pids too: threads count as pids,
  so give a multi-session container thousands per session (`CLAUDE_PIDS_LIMIT`). Library thread
  pools are capped per process (`CLAUDE_THREADS_PER_PROCESS`, default 4) because they size
  themselves to the host, and the supervisor warns in `claude-logs` near either limit.
- **A crashed session comes back.** If Claude exits abnormally (an abort, a segfault, an OOM
  kill, a failed thread create), its window relaunches it after a backoff, resuming the same
  conversation, up to 5 times in 15 minutes. `/exit`, Ctrl-C and `claude-sessions stop` still
  mean stop.

Sessions share one checkout per directory. Two sessions writing the same git tree race on
its index, so give concurrent writers their own directories (one per repo, or a `git
worktree` each) and keep extra sessions in a shared directory to reading and reviewing
(`mode=plan`).

## Changing the Claude account

Log the new account into the credential volume the containers mount, and they follow by
themselves. No restart, no recreate:

```
claude-account-login personal      # logs into claude-auth-personal (the stack's AUTH_VOLUME)
make login                         # the same for the default claude-auth volume
claude-account-list                # each volume's account, and the containers on it: in sync / moving
claude-sessions -C maker account   # that container: the account in use and who is still moving
```

Every running container on that volume then:

1. **takes the new credential** within one sync tick (~30 s) and updates its cached identity
   (the boot log and `claude-logs` say `Auth account : the shared credential is now <email>`);
2. **moves each session at its next idle moment**: the session restarts and resumes its
   conversation, so no turn is cut off (`claude-sessions account --now` moves the busy ones
   too; `CLAUDE_SESSIONS_SWITCH_FORCE_AFTER=<seconds>` does that automatically after a wait);
3. **tells a session that a usage limit had stopped to continue**, since getting past a limit is
   the usual reason to switch (`CLAUDE_SESSIONS_SWITCH_NUDGE=0` turns that off);
4. gets **fresh Remote Control links** under the new account, named as before: Claude will not
   reattach a link another account owns, so the sessions appear in the Claude app of the new
   account, and the old ones go offline in the old account's.

The old account cannot come back by accident. A session still running on it refreshes the OLD
account's token into the container's own credential file; until every session has moved, the
sync never copies that file up to the shared volume. And a container that was stopped across the
change (a dormant service) replaces its own stale credential at boot, before any session starts.
`CLAUDE_AUTH_FOLLOW=0` turns the whole behaviour off (a new login then needs a container
restart, as before). The health line shows `moving to a new account (N sessions to go)` while a
switch is in progress.

This is for changing the account a volume holds. `--accounts a,b` (rotation between several
logged-in accounts on a usage-limit hit) is separate and unchanged.

## Install a kit at session start

A **kit** is a git repository of your own that is a Claude Code plugin marketplace: skills,
commands, hooks and agents packaged as plugins, and optionally a tool it ships. The image
installs one when the container starts, from a git URL, with no rebuild. The repository can
be private: it is cloned with the container's own git credentials (the `gh` credential
helper over https when `GH_TOKEN` is set, or the SSH deploy key). Three values declare it,
all optional:

| Value | Flag (`claude-launch` / `claude-compose-gen`) | What it does |
|---|---|---|
| `CLAUDE_EXTRA_MARKETPLACES` | `--marketplace NAME=URL[#REF]` / `--marketplace SVC=NAME=URL[#REF]` | registers the marketplace in `settings.json` (`extraKnownMarketplaces`, git source). `NAME` is the name the marketplace gives itself in `.claude-plugin/marketplace.json`. |
| `CLAUDE_EXTRA_PLUGINS` | `--plugin PLUGIN@NAME` / `--plugin SVC=PLUGIN@NAME[,…]` | enables each plugin (`enabledPlugins`) and installs it at user scope if it is not installed yet. |
| `CLAUDE_EXTRA_START_CMD` | `--start-cmd COMMAND` / `--start-cmd SVC=COMMAND` | one command, run once per container start as the agent user, in the background, after the sessions are up. Output: `~/.claude/kit-start.log`. |

```
# one container
claude-launch site --repo git@github.com:you/site.git \
    --marketplace 'team-kit=https://git.example.com/you/team-kit.git#v1.2.0' \
    --plugin helper@team-kit \
    --start-cmd 'uv tool install git+https://git.example.com/you/team-kit.git@v1.2.0 && team-kit serve --ensure'

# a stack service (scenario .conf lines, or the generator's command line)
--marketplace site=team-kit=https://git.example.com/you/team-kit.git#v1.2.0
--plugin site=helper@team-kit
--start-cmd site=uv tool install git+https://git.example.com/you/team-kit.git@v1.2.0 && team-kit serve --ensure
```

What happens at boot, in order (`bin/claude-kit`, each step a warning in the boot log if it
fails, never a failed boot):

1. **settings**: the marketplaces and plugins are merged into `~/.claude/settings.json`.
2. **install**: before any Claude session exists, each declared marketplace the CLI does not
   know is added (`claude plugin marketplace add URL#REF`) and each declared plugin it does
   not have is installed (`claude plugin install PLUGIN@NAME --scope user`), each call bounded
   by `CLAUDE_KIT_TIMEOUT` (default 120 s). Enabling a plugin from a git source in
   `settings.json` does not install it by itself, which is why this step exists. A plugin's
   own `SessionStart` hook therefore runs from every session's first start. Sessions start
   after this step, so a kit host that cannot be reached delays them by up to one timeout
   (its plugins are then skipped); under `CLAUDE_EGRESS_LOCKDOWN` a kit on a host other than
   GitHub needs that host in `CLAUDE_EGRESS_EXTRA_HOSTS`.
3. **start**: after the sessions are up, the start command runs once, detached.

`claude-kit status` (inside the container) prints what is declared, registered and installed.

**Pin or auto-update, not both.** Without `#REF` a marketplace follows its repository's
default branch and is registered with `"autoUpdate": true`: Claude Code refreshes it and
updates its installed plugins in the background after startup. With `#REF` (a branch or a
tag) the marketplace is pinned and registered with `"autoUpdate": false`. The two contradict
each other: an auto-updating marketplace moves its plugins whenever the catalog moves, which
is exactly what a pin is there to prevent, and a plugin entry that pins its own source (`ref`
or `sha` in `marketplace.json`) would be moved by the next catalog refresh. Pin when the kit
and something outside it (a tool the start command installs, a running service) must stay at
the same version.

**Moving a pin.** The declaration is the operator's last word: change `#REF` (or add or drop
it) and recreate the container. At the next start the marketplace is registered again at the
declared ref and each declared plugin from it is updated to what that ref offers (an older
ref moves it back), so the plugins and whatever the start command installs move together.
Nothing is removed along the way: plugins you installed from that marketplace by hand stay
installed and are not updated by the hook.

The start command runs with the agent user's privileges and environment, like `--dev-cmd`:
it is part of the container's declaration, not something a session can set. Keep it
idempotent (it runs on every start) and quick to return (start a long-lived service in the
background or in a tmux window of its own). References: Claude Code's
[`extraKnownMarketplaces`](https://code.claude.com/docs/en/settings-reference#extraknownmarketplaces)
and [plugin installation](https://code.claude.com/docs/en/plugins/install) (read 2026-10-02).

## GPU sessions (optional)

Off by default. A session that renders (Blender Cycles, EEVEE, Workbench), previews CAD
through OpenGL/EGL (VTK, PyVista, build123d), or runs CUDA can be given the host's GPU.
**NVIDIA only**, through the NVIDIA Container Toolkit's CDI spec; there is no `/dev/dri`
path and no per-device selection (the session gets `nvidia.com/gpu=all`).

**Host prerequisites:** the NVIDIA driver, the NVIDIA Container Toolkit, and its CDI spec
(`nvidia-ctk cdi generate --output=/var/run/cdi/nvidia.yaml`, or the toolkit's refresh
unit), on a Docker with CDI (28 or newer enables it by default). Check with
`docker info | grep nvidia.com/gpu`: you want `nvidia.com/gpu=all`.

**Turning it on for a stack service** (GPU access is fixed at container creation, so it
is always regenerate + recreate):

```
# 1. in the stack's scenario .conf
--gpu myrepo
# 2. regenerate, then recreate just that service
claude-compose-gen --scenario /srv/claude/personal/personal.conf
docker compose -f /srv/claude/personal/docker-compose.yml up -d myrepo
```

For a standalone container: `claude-launch <name> --gpu ...` (or `CLAUDE_GPU=1` in `.env`,
with `--no-gpu` to opt one out). Removing it is the same in reverse.

**What the service gets, and what it does not:**

- the CDI device `nvidia.com/gpu=all` on the default `runc` runtime. CDI injects the device
  nodes, the driver's user libraries (CUDA, OptiX, the EGL/GLX vendor libraries, the Vulkan
  ICD) and `nvidia-smi`, matched to the host driver. No `runtime: nvidia`, no extra
  capability, no privilege: `cap_drop: ALL`, the minimal set and `no-new-privileges` stay
  exactly as on every other session. `NVIDIA_DRIVER_CAPABILITIES` has no effect in CDI mode
  (the spec decides what is mounted).
- `/scratch` (`TMPDIR`) on a RAM tmpfs (`CLAUDE_GPU_SCRATCH_TMPFS`, 4g) instead of the disk
  volume, so render temp and kernel caches stay off a spinning pool. With the 1g `/tmp`
  that is 5g of the 16g default `CLAUDE_MEM_LIMIT`, leaving 11g for the session and the
  render's own memory.
- `CLAUDE_GPU=1`, which turns on the boot probe, the GPU line in `claude-healthcheck`, and
  a short GPU note in the session's managed memory (`/etc/claude-code/CLAUDE.md`), so the
  agent finds the tooling on its own.

Every image variant ships the vendor-neutral GL side (glvnd `libEGL`/`libGL`/`libOpenGL`,
Mesa llvmpipe as the software fallback, and the X client libraries Blender links even
headless). glvnd picks NVIDIA's EGL vendor when the device is attached and Mesa when it is
not. The image never carries NVIDIA driver libraries.

**The guard, `claude-gpu`.** The card is usually shared (a media server's NVENC transcodes,
an exporter), so GPU work goes through a polite preflight:

```
claude-gpu status            # ok | degraded (<reason>) | off, with card, driver, VRAM, NVENC, utilization
claude-gpu run -- <cmd>      # waits for the card, else runs on CPU; says which device ran and why
claude-gpu blender <args>    # Blender through the guard: Cycles on OptiX, else CUDA, else CPU
```

`run` checks the device-wide numbers (other tenants' usage included): at least
`CLAUDE_GPU_MIN_FREE_MIB` (2048) MiB free, utilization at most `CLAUDE_GPU_MAX_UTIL` (80%),
at most `CLAUDE_GPU_MAX_NVENC` (2) NVENC sessions. The 2048 MiB default is a modest
render (about 1 GiB) plus a reserve for new transcodes, which hold a few hundred MiB each.
A busy card is polled for `CLAUDE_GPU_WAIT` (120) seconds, then the job runs on CPU. A GPU
run that fails with an out-of-memory error is retried once on CPU. The child gets
`CLAUDE_GPU_DEVICE=gpu|cpu`; on CPU also `CUDA_VISIBLE_DEVICES=` and glvnd pointed at Mesa
(`__EGL_VENDOR_LIBRARY_FILENAMES`), so EGL programs render in software.
`claude-gpu env cpu` prints that contract.

**Blender.** `claude-blender-install` downloads the pinned Blender LTS for Linux x64,
verifies its SHA-256 before extracting (a mismatch deletes it and fails), and installs it
rootless and atomically into the shared `/cache/blender/<version>` under a lock, so one
install serves every container on the host; `blender` on `PATH` then runs it. It tries
blender.org, then two of its official mirrors (the checksum, not the host, is the trust).
Headless device choice uses Cycles' own `--cycles-device`, never a GUI preferences file;
`--log-level info` makes Cycles name the device it used (`Path tracing on: <card> (OptiX)`).
EEVEE and Workbench render with `-b` and no X server, through EGL. **Bumping Blender:**
pick the newest LTS, run Cycles' device list for CUDA and OptiX and a test render on each
on the oldest card you support, and update `BLENDER_VERSION`, `BLENDER_SHA256` and the
`PIN_EVIDENCE` note in `bin/claude-blender-install` together.

**When the GPU is unusable.** If the driver breaks under a running host (typically a driver
update without a reboot: `NVML: Driver/library version mismatch`), a GPU session still
boots: the log carries a `GPU DEGRADED` banner, the tmux status line shows it,
`claude-healthcheck` reports `gpu: degraded (<reason>)` without failing health, and GPU work
falls back to CPU. A **missing CDI spec** is different: Docker refuses to create the
container at all, which no image can degrade around. Regenerate the spec, or drop `--gpu`
and regenerate. Runbook: [docs/troubleshooting.md](docs/troubleshooting.md#gpu-sessions---gpu).

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
- **GPU session**: `claude-gpu status` inside says `ok` or `degraded (<reason>)`; a
  service that will not start at all usually means the host's CDI spec is missing.
  See troubleshooting, GPU sessions.

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
