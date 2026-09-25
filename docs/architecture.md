# Architecture & design decisions

## Component map

- **Dockerfile**: `node:24-trixie-slim`, system packages, `gh`, `uv`,
  Claude Code via npm (pinned), non-root `claude` user, hardened sshd config,
  baked-in `claude-config/`.
- **entrypoint.sh**: runs as root: refuses API-key auth, sets up sshd, fixes
  volume ownership, reconciles credentials, pre-accepts trust, merges baked-in
  config, prepares `/workspace`, then `gosu`-drops to `claude` and launches
  Claude Code inside a detached tmux session. Stays PID 1 for clean signals.
- **claude-session**: the tmux pane command: `cd /workspace`, exec
  `claude --dangerously-skip-permissions --remote-control "<project>"`, and
  fall back to a shell if Claude exits so SSH stays usable.
- **bash_profile**: interactive SSH logins `exec tmux attach` to the live
  `claude` session; non-interactive SSH (scp/rsync) is untouched.
- **bin/**: `claude-launch/list/stop/rm/logs` over a shared `_common.sh`; inside the
  image also `claude-gpu` (the GPU guard) and `claude-blender-install`.
- **.claude/skills/claude-containers/**: project skill: when this repo is
  opened in Claude Code, it teaches the model the architecture, invariants,
  and operational playbook so it can drive build/login/launch/customize/debug.

## Verified facts (Claude Code 2.1.280)

Everything below was checked against the installed binary, not just docs:

- `--remote-control [name]` is a real top-level flag; `-n/--name` is a separate
  display-name flag. The **top-level** launch this image actually makes:
  `claude --dangerously-skip-permissions --remote-control "<project>"`: was
  verified to parse and start on 2.1.280 (as the unprivileged `claude` user; the
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
  HOME-level `.claude.json`, into that directory. Verified empirically: this
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
`projects["/workspace"]` key: one session could resume another's. That breaks
spec acceptance criteria 6 (resume preserved) and 7 (independent parallel
containers). The split preserves the spec's actual goal: *one login, every
container reuses it*: via a shared credentials volume, while keeping sessions
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

`claude-ws-<project>` (named volume) is the default: consistent with the other
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
server: adding ~200 MB. At runtime, **launching on the browser image is
sufficient**: the entrypoint auto-detects the baked binaries and registers the
MCP by default (`CLAUDE_BROWSER` is tri-state, unset = auto, `1`/`--browser` =
force on and fail loud on a lean image, `0`/`--no-browser` = opt out;
`claude-compose-gen --browser REPO` selects the image and forces it on). So
Claude gets the full Chrome DevTools Protocol surface
(navigate / evaluate / console / network / Lighthouse / perf trace / heap
snapshots / screenshots: 55+ tools) against any frontend the agent runs in
`/workspace`. Headless-only inside the container; the agent reads pages back
via screenshots and DOM queries.

Why a build arg, not a runtime install: Chromium is ~200 MB and would cost
every user, including those who never debug a frontend. Why MCP, not a CLI
wrapper: it composes with the stack's existing MCP discipline, declarative,
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

## Decision: GPU sessions are CDI devices on plain runc

`--gpu` (`claude-compose-gen --gpu REPO`, `claude-launch --gpu`, `CLAUDE_GPU=1`) gives a
session the host's NVIDIA GPU. NVIDIA only; no `/dev/dri`, no device selection.

**Mechanism: the CDI device `nvidia.com/gpu=all`, requested by name, on the default `runc`
runtime.** The NVIDIA Container Toolkit's CDI spec lists everything the device needs (the
`/dev/nvidia*` nodes, the driver's user libraries including CUDA, OptiX, the EGL/GLX
vendor libraries and the Vulkan ICD, and `nvidia-smi`), and Docker injects it at creation,
matched to the host driver. Nothing about the hardening changes: `cap_drop: ALL`, the
minimal cap set and `no-new-privileges` stay, no capability is added, nothing is
privileged, no host network, no socket. The alternatives were rejected:

| approach | why not |
|---|---|
| `runtime: nvidia` | a second runtime to keep installed and in step, for what CDI does on runc |
| `--gpus all` (the legacy device request) | mounts the compute libraries only (no EGL vendor file), so no headless graphics: EEVEE and VTK fall back to Mesa |
| baking driver libraries into the image | they must match the host's kernel module exactly; a copy drifts and shadows the right one |

**Compose syntax, verified on Docker 28.5 with Compose 2.39.** Both
`devices: [nvidia.com/gpu=all]` and `deploy.resources.reservations.devices` with
`driver: cdi` produce the same thing on the container (`HostConfig.DeviceRequests`:
`Driver cdi`, `DeviceIDs [nvidia.com/gpu=all]`, `Runtime runc`), and `nvidia-smi` works
in both. The generator emits `devices:` because it is the same shape as
`docker run --device nvidia.com/gpu=all` and carries no `deploy:` semantics. Compose
prints it back as `source/target: nvidia.com/gpu=all`. `NVIDIA_DRIVER_CAPABILITIES` does
nothing in CDI mode: the spec is generated with every capability, and the mounted
library set is identical with or without the variable.

**The image carries the vendor-neutral half, in every variant:** glvnd's dispatch
libraries (`libEGL`, `libGL`, `libOpenGL`, `libGLX`), Mesa llvmpipe (the CPU renderer,
and the only one a session without a GPU has), OSMesa for VTK, and the X client
libraries Blender's official build links even when it runs headless. That is about
230 MB, mostly LLVM for llvmpipe, and it is also what lets a CPU-only session render a
preview at all (OCP, behind build123d, hard-links `libGL.so.1`). glvnd reads
`/usr/share/glvnd/egl_vendor.d`: CDI mounts `10_nvidia.json`, the image has
`50_mesa.json`, so EGL picks NVIDIA when the device is attached and Mesa when it is not.

**Degrade, do not fail.** With `CLAUDE_GPU=1` the entrypoint probes the card once, bounded
(20 s at most), records `ok` or `degraded (<reason>)` in root-owned
`/run/claude-gpu/state`, and on a failure prints a banner and puts it on the tmux status
line; `claude-healthcheck` appends the GPU state to its healthy line and never fails on
it. A session that loses its GPU is still a working session, and an unhealthy verdict
would only get it restarted into the same state. The boundary: a missing CDI spec makes
Docker refuse to create the container, before any code of ours runs, so that case is a
loud creation error instead (the launcher and generator check for the device first).

**Sharing the card: `claude-gpu`.** A GPU on a homelab host is rarely exclusive (a media
server's NVENC transcodes, a metrics exporter). From inside a container `nvidia-smi` sees
only device-wide numbers, not other containers' processes, and those are exactly what a
polite preflight needs: free VRAM, SM utilization, NVENC session count. `claude-gpu run`
waits for all three to be under their limits, falls back to CPU through an environment
contract (`CLAUDE_GPU_DEVICE`, `CUDA_VISIBLE_DEVICES=`, glvnd pointed at Mesa), retries
a GPU out-of-memory failure once on CPU, and always says which device ran. Per-process
attribution needs the host PID namespace, so it lives on the host side, not in the guard.

**`/scratch` on RAM.** Blender's render temp and kernel caches, and throwaway venvs,
churn under `TMPDIR`; on a spinning pool that churn is the D-state wedge class the browser
variant already moved to RAM. 4g plus the 1g `/tmp` leaves 11g of the 16g default limit.

**Blender is installed, not baked.** A pinned, SHA-256-verified blender.org LTS tarball
(`claude-blender-install`) goes rootless into the shared `/cache/blender`, under a lock
and renamed into place when complete: one download serves every container, the image
stays the same size for sessions that never render, and a Blender bump is a one-line pin
change, not an image variant.

## Decision: one substantive build stage

A heavy builder stage was considered and rejected: the image weight is the
required system packages (`build-essential`, Python, gh) which must be in the
final image per spec. Claude Code is pure JS via npm with the cache cleaned. A
multi-stage split wouldn't meaningfully shrink the result, so the final stage
stays single with aggressive apt/npm cleanup. (There is one trivial throwaway
stage that only re-exports the `uv` binaries: BuildKit forbids variable
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
no `-p`: those each disable features we need.

## Permission mode & Remote Control

Launch is `claude --dangerously-skip-permissions --remote-control "<project>"`.
On 2.1.280 these compose correctly. Belt-and-suspenders: `settings.json` also
sets `permissions.defaultMode = bypassPermissions` and
`skipDangerousModePermissionPrompt: true` (a real settings key). If a future
Claude Code regresses the interaction, set `CLAUDE_PERMISSION_MODE=acceptEdits`.
See troubleshooting for the end-to-end verification.

## Decision: policy is delivered where the agent user cannot write

`~/.claude/settings.json` is owned by the agent user, sits on a volume that
outlives the container, and the entrypoint's merge lets the existing file win, so
the process being policed owned the file the policy was written in. The settings
that are *policy* rather than preference are therefore also written to the
root-owned `/etc/claude-code/managed-settings.json`, which Claude Code reads
above every other settings level, before the agent process starts. Which settings
count as policy, how an operator changes them from the host, and why
`permissions.disableBypassPermissionsMode` is deliberately not set:
[docs/managed-settings.md](managed-settings.md). It is additive by design: the
`settings.json` composition above is unchanged, so a container whose managed file
is missing or unparseable behaves exactly as it did before, and says so in the
boot log rather than claiming an enforcement it does not have. The boot log is
derived from the file on disk rather than from what the entrypoint attempted, so
it is equally incapable of denying an enforcement that is there: a policy file an
operator mounted is reported even on a boot where this image delivered none.

## Decision: telemetry stays ON (Remote Control depends on it)

Remote Control eligibility is the GrowthBook feature flag `tengu_ccr_bridge`,
fetched at startup. `DISABLE_TELEMETRY`, `DO_NOT_TRACK`, and
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` each make Claude Code skip the
GrowthBook fetch, so the flag falls back to its `false` default and RC reports
"not yet enabled for your account": even on a fully eligible account
(confirmed against Anthropic's docs and 50+ upstream issues; reproduced and
fixed here). An earlier revision of this image set `DISABLE_TELEMETRY=1` /
`DO_NOT_TRACK=1` (Dockerfile ENV **and** the entrypoint's settings.json `env`)
and that was the sole reason Remote Control never appeared. They are now never
set. `DISABLE_AUTOUPDATER=1` (unrelated to flags) is no longer set either: as of
CC-CLAUDE-CODE-UPGRADE (the 2.1.258 bump), auto-update is ON by default, so a
running container's binary can self-update past the pinned `CLAUDE_CODE_VERSION`
unless an operator sets `DISABLE_AUTOUPDATER=1` themselves. (Until the 2.1.280
bump that was only nominal: the CLI sat in root-owned `/usr/local`, so every
update failed with "Insufficient permissions to install update". It now lives in
the claude-owned npm prefix `/opt/claude-code`, and `/usr/local/bin/claude` is
`bin/claude-launcher`, which re-runs the postinstall that the claude user's
`ignore-scripts=true` skips during a self-update.) The entrypoint
also self-heals pre-existing per-container config volumes: it strips these keys
from `settings.json` and, if any were present, clears
`cachedGrowthBookFeatures`/`statsig` so the next run re-resolves the gate.
Trade-off accepted: this image cannot be fully telemetry-silent and also
provide Remote Control; RC is the product, so telemetry stays on.

## Retired: the nested-Sysbox worker-broker substrate, and the per-session Docker engine

An earlier revision of this repo ran a nested-Sysbox "worker broker" substrate so a
controller container could spawn autonomous nested workers: a root-owned
broker that launched hardened nested workers on an inner `dockerd` under Sysbox,
K-aware resource sizing, a worker-lifecycle run/reap contract,
disk-safety floors + GC, a controller mode wiring it to an external
lease/scheduler control plane, and per-worker spend/capacity
observability, plus the curated worker `apt` and the pull-through
cache proxy) supply-chain hardening built on top of it.

That whole substrate was retired on 2026-07-12 in favor of Claude Code subagents in
per-worktree git worktrees, and stripped from `main`. A follow-up prune
(2026-07-14), pruned the residue the strip left behind: `bin/claude-controller` (by then
a pass-through to `claude-autopilot`; `CLAUDE_CONTROLLER=1` now refuses to boot),
`bin/claude-reaper` (it pruned a spool nothing writes to), the controller image variant
(an unreachable `dockerd`), and the autopilot's default command
(`CLAUDE_AUTOPILOT_CMD` is now required).

A later per-session Docker engine (`--docker`: an inner `dockerd` in the session, under
the same user-namespaced runtime, so the agent could build images and run containers)
was removed as well. It was the last thing that needed a non-default runtime on the host,
it had to skip the capability drop every other session keeps, and it voided two
in-container controls (the git-key broker and egress lockdown) because socket access is
a route to root inside the container. Every session now runs on plain `runc` with
`--cap-drop ALL`; the removed flags refuse, naming the removal.

The frozen implementation, the full rationale, and the follow-up resolution live in
[docs/legacy-sysbox-broker.md](legacy-sysbox-broker.md); nothing above or below this
note describes either.

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
