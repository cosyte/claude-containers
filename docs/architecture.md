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

## Verified facts (Claude Code 2.1.144)

Everything below was checked against the installed binary, not just docs:

- `--remote-control [name]` is a real top-level flag; `-n/--name` is a separate
  display-name flag. `claude remote-control --permission-mode` explicitly
  accepts `bypassPermissions` in 2.1.144.
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
On 2.1.144 these compose correctly. Belt-and-suspenders: `settings.json` also
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

## Decision: worker launches are brokered by root (CC-2)

Where a controller runs nested workers (the Sysbox substrate, docs/substrate.md),
the unprivileged agent never talks to the inner `dockerd`: inside the controller,
socket access is still every peer worker, its leases, and the launch template —
even with host escape already contained by userns (CC-1). So worker creation is
owned by a **root broker** (`bin/claude-worker-broker`), the same
root-owns-the-capability pattern as the git-key broker: the agent submits a
KEY=VALUE request file (`bin/claude-worker-request`) into a write-only spool; the
broker **renames the entry into a root-only staging dir before reading it** (the
agent owns its spool entry, so validating in place is a swap-TOCTOU — a FIFO would
hang the serve loop, a symlink would leak a root file; rename opens nothing and,
once staged, the inode can't be swapped), validates it **deny-by-default** (exactly
`repo` + `item`, tight charset, size cap — an unknown key, forged cap/limit, or
flag-shaped value rejects the whole request) and launches with a **fixed hardened
template** (cap-drop ALL +
minimal re-add, `no-new-privileges`, per-worker memory/reservation/cpus/pids/shm,
secret-guard + egress inheritance, `claude.worker`/`claude.item`/`claude.repo`
labels). Lease discipline: one live worker per item, `CLAUDE_BROKER_MAX_WORKERS`
total (CC-3 single-sources K from the umbrella). Fail-closed startup: root only,
real userns in `/proc/self/uid_map`, and a host-attested CVE-patched Sysbox in
`CLAUDE_SYSBOX_ATTESTED_VERSION` (set by the launch path from `preflight_sysbox`
— the host binary is not probeable from inside; the shared `sysbox_version_check`
keeps the two floors identical). Verify: `test/broker-unit.sh` (docker-free, CI)
+ `bin/claude-broker-verify` (on-host, 28 checks). The CC-4 worker lifecycle
replaces the placeholder worker command; the template is the contract it inherits.

## Decision: per-worker observability is read-only + fail-safe (CC-7)

The umbrella's K-ramp decision (raising `CLAUDE_CONTROLLER_MAX_SLOTS` past 1) needs
real cost/capacity data, not guesses. Three additions, none of which change worker
behavior on the happy path:

- **OTEL item tag.** `claude-worker-run` prepends `claude.item=<item>,claude.repo=<repo>`
  to `OTEL_RESOURCE_ATTRIBUTES` before the one `claude -p` call it makes, so any
  OTEL cost/token telemetry the `claude` binary already emits is attributable to a
  specific backlog item — an operator-supplied `OTEL_RESOURCE_ATTRIBUTES` is
  preserved (appended after), never clobbered.
- **Secret-free spend sidecar.** Alongside the existing `run-<item>-<ts>.json` claude
  log, `claude-worker-run` now writes `run-<item>-<ts>.meta.json`: exactly
  `item`/`repo`/`ts`/`total_cost_usd`/`is_error`, nothing else — never the claude JSON
  body itself (which can carry prompt/PHI-shaped content), never env or credentials.
  This is the filename-independent source `claude-fleet-view` reads.
- **`bin/claude-fleet-view`** is the read-only aggregator: it lists active
  `claude.worker=1` containers (reusing the `claude.item`/`claude.repo` labels the
  CC-2 broker already sets), joins each to its newest spend sidecar, and reports host
  cpu/mem/disk headroom against the K-derived `controller_envelope` budget
  (`bin/_common.sh` — reused, not reinvented). `--json` feeds the umbrella's
  `scripts/run-log-report.sh --concurrent`.

Fail-safe by construction: every reading (docker, a meta file, `/proc/meminfo`, the
parallel config) degrades independently to `"unknown"` (`null` in `--json`) rather
than blocking or erroring the view — a worker's real run is never gated on
telemetry. One sharp edge worth naming for future maintainers: `bin/_common.sh`'s
`resolve_parallel_k`/`controller_envelope` fail CLOSED with a hard `exit` (not
`return`) on a garbage config/profile, which trips a classic bash `-e` gotcha —
`x="$(cmd || true)"` does **not** absorb an `exit` inside the substitution, only a
nonzero `return`; the `|| true`/`|| k=""` must sit **outside** the `$(...)` to
actually degrade that field instead of tearing down the whole view. See
`fleet_host_headroom` in `bin/claude-fleet-view` for the pattern. The same `exit`
also fires at **source time**: `_common.sh` derives the memory reservations when it
is sourced and `die`s on an unparseable `CLAUDE_MEM_LIMIT`/`CLAUDE_WORKER_MEM`
(e.g. a `4gb` typo) — before any call-site guard runs. `claude-fleet-view` closes this
two ways before it sources `_common.sh`: (a) it scrubs a malformed size-shaped var from
the **process environment** (with a stderr note), and (b) because `_common.sh` also
sources the repo-root **`.env`** internally — which the process scrub can't reach — it
**pre-seeds the two reservation vars**, and `_common.sh` skips its source-time
derivation (the only die) whenever the reservation is already set. So a `4gb` typo in
`.env` degrades instead of exiting too. The launcher/broker source `_common.sh` in their
OWN process without the seed, so they keep deriving reservations correctly and stay
fail-closed; this read-only view never launches a container, so a seeded reservation is
inert here.

One more sharp edge in spend attribution: the sidecar glob `run-<item>-*.meta.json`
also matches a **dash-suffixed sibling** id (querying `CC-4` matches
`run-CC-4-RESIDUAL-<ts>.meta.json` — both are real backlog ids). `fleet_worker_spend`
therefore decomposes each candidate name and accepts it only when the part before the
final dash-segment equals `<item>` exactly **and** the final segment is a real
`%Y%m%dT%H%M%SZ` stamp — so a sibling's cost can never be mis-attributed.

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
