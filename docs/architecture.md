# Architecture & design decisions

## Component map

- **Dockerfile** — `node:24-bookworm-slim`, system packages, `gh`, `uv`,
  Claude Code via npm (pinned), non-root `claude` user, hardened sshd config,
  baked-in `claude-config/`.
- **entrypoint.sh** — runs as root: refuses API-key auth, sets up sshd, fixes
  volume ownership, reconciles credentials, pre-accepts trust, merges baked-in
  config, prepares `/workspace`, then `gosu`-drops to `claude` and launches
  Claude Code inside a detached tmux session. Stays PID 1 for clean signals.
- **claude-session** — the tmux pane command: `cd /workspace`, exec
  `claude --dangerously-skip-permissions --remote-control "<project>"`, and
  fall back to a shell if Claude exits so SSH stays usable.
- **bash_profile** — interactive SSH logins `exec tmux attach` to the live
  `claude` session; non-interactive SSH (scp/rsync) is untouched.
- **bin/** — `claude-launch/list/stop/rm/logs` over a shared `_common.sh`.
- **.claude/skills/claude-containers/** — project skill: when this repo is
  opened in Claude Code, it teaches the model the architecture, invariants,
  and operational playbook so it can drive build/login/launch/customize/debug.

## Verified facts (Claude Code 2.1.220)

Everything below was checked against the installed binary, not just docs:

- `--remote-control [name]` is a real top-level flag; `-n/--name` is a separate
  display-name flag. The **top-level** launch this image actually makes —
  `claude --dangerously-skip-permissions --remote-control "<project>"` — was
  verified to parse and start on 2.1.220 (as the unprivileged `claude` user; the
  CLI refuses skip-permissions when running as root, by design). Verify it on a
  TTY: with no tty the CLI falls into `--print` mode and exits on missing input
  *before* proving anything about the interactive launch.
  *Not re-verified:* the `claude remote-control` **subcommand**'s own option
  surface. On the then-pinned 2.1.207 that subcommand short-circuited on auth before parsing its
  options (every flag, valid or bogus, returns "You must be logged in"), so its
  accepted options cannot be established from inside the container. The earlier
  "`remote-control --permission-mode` accepts `bypassPermissions`" claim was made
  against 2.1.144 and is left unasserted here rather than silently re-dated.
- `--dangerously-skip-permissions` ≡ `--permission-mode bypassPermissions`.
- Setting `CLAUDE_CONFIG_DIR` relocates **everything**, including the otherwise
  HOME-level `.claude.json`, into that directory. Verified empirically — this
  is what lets one per-container volume capture all session state.
- Workspace trust + onboarding live in `<config>/.claude.json` as
  `hasCompletedOnboarding` and `projects["<path>"].hasTrustDialogAccepted`.
- Plugins are declarative: `settings.json` `extraKnownMarketplaces` +
  `enabledPlugins` are synced by Claude Code on startup.
- `--bare` forces API-key-only auth and disables plugins/CLAUDE.md, so it is
  **not** used here.

## Decision: split credentials from per-container config (deviation)

The spec describes one shared `claude-auth` volume mounted at
`/home/claude/.claude` across all containers. Implemented differently, on
purpose:

- `claude-auth` (shared) → `/auth`, credentials only.
- `claude-config-<project>` (per container) → `/home/claude/.claude`
  (`CLAUDE_CONFIG_DIR`), all session/history/state.

Reason: Claude rewrites `.claude.json`, `history.jsonl` and `sessions/`
constantly. With one shared config dir, parallel containers race those files,
and every container's workspace is `/workspace` so they collide on the same
`projects["/workspace"]` key — one session could resume another's. That breaks
spec acceptance criteria 6 (resume preserved) and 7 (independent parallel
containers). The split preserves the spec's actual goal — *one login, every
container reuses it* — via a shared credentials volume, while keeping sessions
isolated.

**Credential convergence.** Claude refreshes the OAuth token and rewrites
`.credentials.json` in its config dir. A background loop in the entrypoint keeps
`/auth/.credentials.json` and the per-container copy converged (newest mtime
wins, atomic replace, ~30s). Net effect: one login propagates to all
containers, and refreshed tokens propagate back through the shared volume.
Limitation: if two containers refresh within the same ~30s window the later
write wins; refreshes are infrequent (hours apart) so this is acceptable for a
homelab. A token-rotation regression would surface as a re-login prompt, not
data loss.

## Decision: per-container workspace defaults to a named volume

`claude-ws-<project>` (named volume) is the default — consistent with the other
volumes, cleanly removed by `claude-rm --purge`, and matches the spec's
"per-container workspace volume" wording. `--workspace <path>` bind-mounts a
host checkout instead (use that when you want the repo directly on the host
filesystem for backups/inspection). Back up a named volume with
`docker run --rm -v claude-ws-<p>:/w -v "$PWD":/b alpine tar czf /b/<p>.tgz -C /w .`

## Decision: MCP secrets are runtime-only

Baked `mcp/*.json` use `${VAR}` placeholders, expanded by `envsubst` from the
container environment at registration time. Secrets come from `.env`
(`--env-file`), never the image. Confirms the spec's stated preference.

## Decision: frontend debugging is an opt-in image variant

The default image stays lean. A `WITH_BROWSER=1` build arg
(`make build-browser`, tag `claude-code-box:browser`) bakes Debian's headless
**Chromium** (multi-arch) and the official
[`chrome-devtools-mcp`](https://github.com/ChromeDevTools/chrome-devtools-mcp)
server — adding ~200 MB. At runtime, **launching on the browser image is
sufficient**: the entrypoint auto-detects the baked binaries and registers the
MCP by default (`CLAUDE_BROWSER` is tri-state — unset = auto, `1`/`--browser` =
force on and fail loud on a lean image, `0`/`--no-browser` = opt out;
`claude-compose-gen --browser REPO` selects the image and forces it on). So
Claude gets the full Chrome DevTools Protocol surface
(navigate / evaluate / console / network / Lighthouse / perf trace / heap
snapshots / screenshots — 55+ tools) against any frontend the agent runs in
`/workspace`. Headless-only inside the container; the agent reads pages back
via screenshots and DOM queries.

Why a build arg, not a runtime install: Chromium is ~200 MB and would cost
every user, including those who never debug a frontend. Why MCP, not a CLI
wrapper: it composes with the stack's existing MCP discipline — declarative,
secret-free (the MCP needs none), removable per session. Why Chromium over
`@puppeteer/browsers install chrome` at build time: Debian's package is
multi-arch with one apt line, vs Puppeteer's per-arch binary download +
runtime-managed cache. The launcher reads the image's `claude.browser` LABEL to
fail loud + early if `--browser` is requested against the lean image; the
in-container entrypoint can't read its own image labels, so it auto-detects the
variant by probing the baked binaries on `PATH`.
Chrome is started with `--no-sandbox --disable-dev-shm-usage --disable-gpu`
(required in unprivileged Docker; Chrome's user-namespace sandbox conflicts
with the default seccomp).

## Decision: container workflows are an opt-in image variant on Sysbox

A session whose job involves containers (a Dockerfile, a compose stack,
testcontainers) needs a real Docker engine. `WITH_DOCKER=1`
(`make build-docker`, tag `claude-code-box:docker`) bakes dockerd + CLI +
containerd + the compose and buildx plugins, ~400 MB. `--docker` (or
`CLAUDE_DOCKER=1`, or `claude-compose-gen --docker REPO`) starts that daemon
**inside** the session container and puts the agent in the `docker` group.
Orthogonal to `WITH_BROWSER`: `make build-docker-browser` bakes both.

**Why an inner daemon under Sysbox, and not the two obvious alternatives.**
There are exactly three ways to give a container Docker, and two of them end the
same way:

| approach | what the agent gets | host blast radius |
|---|---|---|
| mount `/var/run/docker.sock` | the **host** daemon | `docker run -v /:/host` → host root |
| `--privileged` DinD | its own daemon, full host caps | mknod/mount host devices → host root |
| **Sysbox** (`--runtime=sysbox-runc`) | its own daemon in a **user namespace** | container-root is an unprivileged host uid |

The first two are FORBIDDEN in this repo and asserted against in
`test/unit.sh` + `test/docker-unit.sh` — with `--dangerously-skip-permissions`
on by design, a prompt-injectable agent plus either shortcut is host root.
Sysbox is the only option that keeps nested Docker a *boundary*. Measured on
the r730xd (`docker run --runtime=sysbox-runc alpine cat /proc/self/status
/proc/self/uid_map`):

```
runc         CapEff 00000000a80425fb   uid_map 0 0 4294967295   → container-root IS host root
sysbox-runc  CapEff 000001ffffffffff   uid_map 0 165536 65536   → container-root is host uid 165536
```

So the `--docker` container carries the **full** capability set and that is
fine: the caps are namespaced, and root maps to a host nobody. This is why
`harden_run_args` **skips `--cap-drop ALL`** in docker mode — an inner daemon
cannot start under the minimal set (it needs `NET_ADMIN` for its bridge and
`SYS_ADMIN` to mount layers; neither is in Docker's *default* set either) — and
why skipping it costs nothing the userns isn't already providing. Verified end
to end: with `no-new-privileges` still on, an inner dockerd starts, builds an
image and runs a container, and the inner daemon selects `overlayfs` (not the
slow `vfs` fallback). `no-new-privileges` is therefore kept; its one real cost
is that setuid binaries *inside an inner container* (`sudo`, `ping`) cannot
elevate. `preflight_sysbox` fails the launch closed if the runtime is absent
rather than degrading to something unsafe.

**What this deliberately gives up.** Socket access is a path to root *inside*
the container. The host boundary holds, but two in-container controls assume
root is separate from the agent, and on a `--docker` session they do not bind:
`CLAUDE_BROKER_GIT_KEY` (root-owned `ssh-agent` hiding the deploy key — an agent
with Docker reads the key file directly) and `CLAUDE_EGRESS_LOCKDOWN` (filters
`OUTPUT`; inner-container traffic is `FORWARD`ed, and container-root can flush
the rules). Both default off; the launcher and generator warn on the
combination rather than refusing, since the operator may not care about either
on a given box. Do not treat them as active on a `--docker` container.

**Not the worker broker.** This reuses the retired substrate's *runtime* and
nothing else — no broker, no worker plane, no spool, no controller
([legacy-sysbox-broker.md](legacy-sysbox-broker.md)). It also inverts that
design's central move: the broker chowned the socket to root and mediated every
launch to keep the agent OFF the daemon; here the agent using Docker *is* the
feature. Note `CC-BINS` had deleted `WITH_DOCKER` on the correct grounds that
nothing could start the baked engine (no runtime, no privilege, no socket) — the
Sysbox runtime is precisely the missing piece, and `test/unit.sh` now pins the
wiring (entrypoint starts it, launcher supplies the runtime) instead of pinning
its absence.

**Operational consequences.** Inner containers share the session's cgroup, so
`CLAUDE_MEM_LIMIT`/`CPU`/`PIDS` must cover the whole stack (the launcher warns
below 8g). The inner image store is a per-project `claude-docker-<name>` volume
so a recreate doesn't re-pull every base image; it can reach tens of GB and
`claude-rm --purge` deletes it. The entrypoint's shutdown trap stops inner
containers and the daemon before PID 1 exits — without that, force-killing a
Sysbox container with a live inner daemon makes Docker fail the removal with
"did not receive an exit event", which stranded volumes mid-purge.

## Decision: one substantive build stage

A heavy builder stage was considered and rejected: the image weight is the
required system packages (`build-essential`, Python, gh) which must be in the
final image per spec. Claude Code is pure JS via npm with the cache cleaned. A
multi-stage split wouldn't meaningfully shrink the result, so the final stage
stays single with aggressive apt/npm cleanup. (There is one trivial throwaway
stage that only re-exports the `uv` binaries — BuildKit forbids variable
expansion directly in `COPY --from=`, so it must go through a named stage.)
Multi-arch
(`linux/amd64,linux/arm64`) is handled by `docker buildx` (`make build-all` /
`make push`); `make build` loads the host arch locally because Docker can't
`--load` a multi-arch manifest into the local engine.

## Decision: workspace trust pre-acceptance

The cleanest non-interactive method is seeding `<config>/.claude.json` with
`hasCompletedOnboarding: true` and `projects["/workspace"]
.hasTrustDialogAccepted: true` (the exact shape Claude Code uses). Done with a
`jq` merge that only fills missing keys. No `--bare`, no piping `/dev/null`,
no `-p` — those each disable features we need.

## Permission mode & Remote Control

Launch is `claude --dangerously-skip-permissions --remote-control "<project>"`.
On 2.1.220 these compose correctly. Belt-and-suspenders: `settings.json` also
sets `permissions.defaultMode = bypassPermissions` and
`skipDangerousModePermissionPrompt: true` (a real settings key). If a future
Claude Code regresses the interaction, set `CLAUDE_PERMISSION_MODE=acceptEdits`
— see troubleshooting for the end-to-end verification.

## Decision: telemetry stays ON (Remote Control depends on it)

Remote Control eligibility is the GrowthBook feature flag `tengu_ccr_bridge`,
fetched at startup. `DISABLE_TELEMETRY`, `DO_NOT_TRACK`, and
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` each make Claude Code skip the
GrowthBook fetch, so the flag falls back to its `false` default and RC reports
"not yet enabled for your account" — even on a fully eligible account
(confirmed against Anthropic's docs and 50+ upstream issues; reproduced and
fixed here). An earlier revision of this image set `DISABLE_TELEMETRY=1` /
`DO_NOT_TRACK=1` (Dockerfile ENV **and** the entrypoint's settings.json `env`)
and that was the sole reason Remote Control never appeared. They are now never
set; only `DISABLE_AUTOUPDATER=1` (unrelated to flags) remains. The entrypoint
also self-heals pre-existing per-container config volumes: it strips these keys
from `settings.json` and, if any were present, clears
`cachedGrowthBookFeatures`/`statsig` so the next run re-resolves the gate.
Trade-off accepted: this image cannot be fully telemetry-silent and also
provide Remote Control; RC is the product, so telemetry stays on.

## Retired: the nested-Sysbox worker-broker substrate (CC-1 through CC-7)

An earlier revision of this repo ran a nested-Sysbox "worker broker" substrate so a
controller container could spawn autonomous nested workers: a root-owned
broker (CC-2) that launched hardened nested workers on an inner `dockerd` under Sysbox
(CC-1), K-aware resource sizing (CC-3), a worker-lifecycle run/reap contract (CC-4),
disk-safety floors + GC (CC-5), a controller mode wiring it to an external
lease/scheduler control plane (CC-6), and per-worker spend/capacity
observability (CC-7) — plus the PKG-4 (curated worker apt) and PKG-6 (pull-through
cache proxy) supply-chain hardening built on top of it.

That whole substrate was retired on 2026-07-12 in favor of Claude Code subagents in
per-worktree git worktrees, and stripped from `main` (SC-5). A follow-up, **CC-BINS**
(2026-07-14), pruned the residue the strip left behind — `bin/claude-controller` (by then
a pass-through to `claude-autopilot`; `CLAUDE_CONTROLLER=1` now refuses to boot),
`bin/claude-reaper` (it pruned a spool nothing writes to), the `WITH_DOCKER` controller
image variant (an unreachable `dockerd`), and the autopilot's default command
(`CLAUDE_AUTOPILOT_CMD` is now required). The frozen implementation, the full rationale,
and the CC-BINS resolution live in
[docs/legacy-sysbox-broker.md](legacy-sysbox-broker.md); nothing above or below this
note describes it.

## Acceptance

| # | Criterion | How it's met / verify |
|---|---|---|
| 1 | `make build` works (amd64+arm64) | `make build` (host arch, loaded); `make build-all`/`make push` for both arches via buildx |
| 2 | `make login` persists creds | Login-mode entrypoint runs `claude auth login --claudeai` with `CLAUDE_CONFIG_DIR=/auth`; creds land in `claude-auth` |
| 3 | launch clones + starts + prints | `claude-launch myproj --repo …`; entrypoint clones, launches with flags; connect info printed |
| 4 | SSH → live tmux | `bash_profile` `exec tmux attach -t claude`; session started by entrypoint before sshd accepts logins |
| 5 | Appears in app, named, green | `--remote-control "<project>"`, outbound HTTPS; name = project name |
| 6 | stop→launch resumes | Per-container `claude-config`/`claude-ws` volumes survive `docker stop`; `claude-launch` does `docker start` |
| 7 | Two parallel, independent | Distinct container names, ports (`alloc_port`), per-container volumes, separate app sessions |
| 8 | Baked MCP/plugins/commands/skills usable | In a session: `/mcp`, `/plugin`, `/container-info`, the `example-skill`; see customizing-bakeins.md |
