# Legacy: Sysbox nested-broker path (frozen 2026-07-12)

The nested-Sysbox worker-broker substrate — the CC-1 through CC-7 chain plus the
PKG-1 through PKG-6 supply-chain hardening built on top of it — was retired as
the parallel-`/work-on` substrate on **2026-07-12** in favor of **Claude Code
subagents in per-worktree git worktrees**. The code is frozen (unchanged) on a
preservation branch and a preservation tag on this repo:

- **Branch:** [`legacy/sysbox-broker-2026-07-12`](https://github.com/cosyte/claude-containers/tree/legacy/sysbox-broker-2026-07-12)
- **Tag:** `legacy-sysbox-broker-2026-07-12` (annotated, points at the same commit)
- **Commit at the freeze:** [`a334902`](https://github.com/cosyte/claude-containers/commit/a334902) — `feat: durable worker image + compose-gen --broker (#25)`
- **Consumer pointer at the freeze:** recorded in the maintainer's private planning repo (not
  public); nothing on this branch depends on it.

## What's frozen on the branch

All of the following live *only* on the preservation branch after `SC-5` strips
them from `main`. Any of them can be recovered by checking that branch out.

- **Broker + worker plane** — `bin/claude-worker-broker`, `bin/claude-worker-request`,
  `bin/claude-worker-run`, `bin/claude-broker-verify`, `bin/claude-worker-lifecycle-verify`.
- **Sysbox + PKG-broker-tied tools** — `bin/claude-sysbox-verify`,
  `bin/claude-apt-provision`, `bin/claude-cache-proxy`, `bin/claude-fleet-view`.
- **Broker/controller entrypoint sections** — `entrypoint.sh` §5a (inner dockerd +
  broker), §5b (broker controller mode), §5c (broker-must-be-serving), §5d (cache
  proxy), §8a-bis (broker CLAUDE.d loader).
- **Broker session-config fragment** — `claude-config/CLAUDE.d/broker.md`.
- **Broker tests** — `test/broker-unit.sh`, `test/broker-interactive-unit.sh`,
  `test/broker-claude-d-unit.sh`, `test/cache-proxy-unit.sh`,
  `test/apt-provision-unit.sh`, `test/worker-run-unit.sh`, `test/fleet-view-unit.sh`.
  (`test/compose-gen-unit.sh` carried **no** broker cases — the `SC-5` `done:` line
  claimed it did; that was wrong, and the file was left untouched.)
- **Broker-only launch/compose flags** — `--broker`, `--sysbox`, `--worker-tarball`
  on `bin/claude-launch` and `bin/claude-compose-gen`. Both now **reject** these
  flags with a "removed in SC-5" error rather than ignoring them.
- **Broker-only env plumbing** — `CLAUDE_WORKER_*`, `CLAUDE_SYSBOX_*`,
  `CLAUDE_CACHE_PROXY*`, `CLAUDE_APT_PROVISION*`, and `CLAUDE_BROKER_*`
  **except `CLAUDE_BROKER_GIT_KEY`**.

  > ⚠️ **`CLAUDE_BROKER_GIT_KEY` STAYS on `main` — do not strip it.** Despite the
  > name it has nothing to do with the worker broker: it is the **git-key broker**,
  > a live credential-isolation control that holds the SSH deploy key in a
  > root-owned `ssh-agent` so the unprivileged agent can sign/push but cannot read
  > the key bytes (`entrypoint.sh` §5; `README.md`; and §3.3 of
  > `docs/package-provisioning-security.md`, which names it as one of the two
  > controls that make package provisioning safe). A `CLAUDE_BROKER_*` glob applied
  > naively in `SC-6`/`SC-7` would delete it — don't.
- **Controller-envelope sizing tier** — `bin/claude-controller-size`,
  `bin/claude-controller-verify`, `bin/claude-sizing-verify`. These sized and
  verified a controller for *K nested Sysbox workers*; with the workers gone
  they have no non-broker function (`claude-controller-size`'s docker-args
  output leads with `--runtime=sysbox-runc`). The reusable sizing math
  (`size_to_mib` / `mem_reservation_for`) was kept in `bin/_common.sh`.
- **The `CLAUDE.d/` per-mode fragment loader** — `bin/claude-md-fragments` and
  `entrypoint.sh` §8a-bis. It existed solely to teach the broker channel via
  `claude-config/CLAUDE.d/broker.md`; `claude-config/settings.json`'s only
  content was the `SessionStart` hook that invoked it.

  > **Upgrade note.** That hook was persisted into every per-project **config
  > volume** by pre-`SC-5` images, and §8b's merge lets existing user settings
  > win — so removing the binary alone would have left the hook firing an ENOENT
  > at every session start on any upgraded volume. `entrypoint.sh` §8b therefore
  > carries a **self-heal** that drops a `SessionStart` hook pointing at
  > `/usr/local/bin/claude-md-fragments` (a user's own hooks are untouched),
  > mirroring the existing telemetry-kill migration. Covered by `test/unit.sh`.
- **PKG-4 curated apt manifest** — `claude-config/apt-manifest.txt`.
- **Broker-tier docs** — `docs/caching-proxy.md` (PKG-6) and `docs/substrate.md`
  (the Sysbox substrate); this page replaces them.
  `docs/package-provisioning-security.md` was **retained**, reduced to the PKG-1
  / PKG-5 controls that are still live — only its PKG-4/PKG-6 sections were cut.

`PKG-2`/`PKG-3`/`PKG-5` mechanisms (`mise` toolchain + shared `/cache` +
`ignore-scripts`/`lockfile=true`) are **not** broker-tied and stay on `main` —
the strip is broker + Sysbox + PKG-4 (curated apt) + PKG-6 (pull-through cache
proxy) only.

## The follow-up strip: `CC-BINS` (2026-07-14) — resolving what `SC-5` left dangling

`SC-5` deferred three things to a follow-up (it called it `SC-6`; it shipped as
**`CC-BINS`**). All three turned out to be residue, and all three were removed:

- **`bin/claude-controller` — REMOVED.** With the broker-dispatch tier gone it was a
  byte-identical pass-through that `exec`'d `claude-autopilot`: a *mode whose only job
  was selecting another mode*. **`CLAUDE_CONTROLLER=1` now REFUSES to boot** (`entrypoint.sh`,
  the mode-selection block) rather than being warn-and-ignored the way §0 treats the inert
  broker env vars. The distinction is deliberate: those vars are dead leftovers in a `.env`,
  but `CLAUDE_CONTROLLER=1` is an **active request for unattended operation**. Ignoring it
  would boot an unattended fleet container into an *interactive* Remote-Control session that
  nobody is watching and that never runs the loop — a container that looks alive and does
  nothing. The refusal names `CLAUDE_AUTOPILOT=1`, which is the same loop and always was.
  (`CLAUDE_CONTROLLER=0`, which every pre-`CC-BINS` `.env.example` carries, still boots
  cleanly — a stale line must never brick a container.)
- **`bin/claude-reaper` — REMOVED.** Its worker-container-reaping duty went with the broker,
  leaving a generic pruner for a spool (`/run/claude/reaper-spool`) that **no surviving code
  writes to and no entrypoint path starts**. `CLAUDE_REAPER_*` went with it. Note this is
  *not* `bin/claude-disk-gc`, which survives: disk-gc reclaims real Docker layers on the host
  and has a reason independent of the broker.
- **The autopilot's `/next` default — REMOVED; `CLAUDE_AUTOPILOT_CMD` is now required.**
  `/next` was the cosyte cockpit's continuous-build command, and this is a *generic* image
  that bakes no such skill (`claude-config/skills/` ships only `example-skill` and
  `frontend-debugging`), so on almost every container the default resolved to nothing. The
  rule is now **no command, no run**: the autopilot refuses to start without one, and a queue
  consumer with no fallback command *idles* on an empty queue rather than inventing work.

  > **The sharp edge, verified by hand against the pinned CLI (2.1.207).** An unknown slash
  > command is **not an error** to `claude -p`. It returns a zero-turn *success*:
  > `{"subtype":"success","is_error":false,"num_turns":0,"result":"Unknown command: /typo",`
  > `"total_cost_usd":0}`, exit **0** — the model is never invoked. The autopilot's success
  > check (`exit 0` + `is_error != true`) therefore scored the old `/next` default as a
  > **healthy run**, every interval, forever: `fails` stayed 0 so backoff never engaged, each
  > cycle logged `run #N` and `cost: $0`, and a **queued task** would be filed to `done/` —
  > silently marking work that never ran as done, on the very `claude-scm-observer` → queue
  > path built to run a fleet unattended. A container that looks perfectly alive and does
  > literally nothing is the worst failure this script can have. CC-BINS therefore also makes
  > a zero-turn `Unknown command:` result a **FAILURE** (both conditions, so a legitimate run
  > that merely *discusses* an unknown command cannot trip it) — which closes the whole class,
  > not just `/next`: an operator typo, a renamed skill, or a workspace whose `.claude/` never
  > cloned now fails loudly instead of spinning.

**Also removed: the `WITH_DOCKER` "controller" image variant** (`make build-controller`,
`CLAUDE_IMAGE_CONTROLLER`, `LABEL claude.controller`, ~400 MB of `dockerd` + CLI +
`containerd`). It existed only to host the nested-Sysbox substrate. Nothing started `dockerd`
after `SC-5` — and nothing *could*: `claude-launch`, `claude-compose-gen` and
`docker-compose.yml` grant no `--privileged` and mount no Docker socket, so the baked engine
was unreachable even in principle.

> ⚠️ **`CLAUDE_BROKER_GIT_KEY` survived `CC-BINS` too, exactly as this page warned.** The
> `CLAUDE_BROKER_*` glob was checked hit-by-hit rather than swept. It stays.

## Why we retired it

- **Blast radius was already contained by the outer controller container.** The
  nested Sysbox layer duplicated the protection the leaf already provides. A
  prompt-injectable agent's blast radius is one repo either way — the outer
  container is the boundary.
- **Observability collapsed under the broker.** The unprivileged coordinator
  couldn't `docker ps` or `docker logs` into workers (root-only), so debugging
  a stuck worker was guess-and-tail-the-broker. Subagent stdout returns to the
  parent directly; `SendMessage` reaches a running subagent.
- **Cold-start cost was real.** Each broker worker cloned the consuming repo (or
  hydrated from a tarball), warmed `mise`, installed deps. Subagents inherit
  the warm tree at zero marginal cost.
- **Coordinator ⇄ worker was one-way with the broker, two-way with subagents.**
  Mid-flight guidance was impossible over the broker spool; native with
  `SendMessage` on a subagent's `agentId`.
- **The workload isn't a fleet.** Solo founder + one controller + mobile
  Remote Control ≠ the multi-tenant unattended-fleet scale the broker was
  designed for.

The full rationale, decision record and reversibility contract live in the maintainer's private
planning repo (the ADR that superseded this substrate's own ADR). They are **not public**; what a
reader of this repo needs is above, and the frozen implementation is on the branch named at the top.

## How to check out the frozen state

```bash
# Clone this repo, then:
git fetch origin legacy/sysbox-broker-2026-07-12
git checkout legacy/sysbox-broker-2026-07-12

# Or by tag:
git fetch origin tag legacy-sysbox-broker-2026-07-12
git checkout tags/legacy-sysbox-broker-2026-07-12
```

The branch is intentionally not maintained — no CI, no dependency updates, no
security patches. It exists solely as evidence of what shipped and as a
recovery path if the subagent substrate ever needs to be reversed. Reversing
would checkout this branch on `claude-containers`, rebuild the image, and
re-enable the broker + Sysbox path — no code merge back into `main` from this
branch is planned.

## What stays on `main`

The Remote-Control core (SSH → tmux → Claude Code), the unattended autopilot loop
(driven by `CLAUDE_AUTOPILOT_CMD`, plus the durable task queue and the SCM observer),
launch/compose-gen (minus broker flags), housekeeping (disk-gc, healthcheck), baked
config (`claude-config/`), and the security floor (secret guard, egress firewall,
`CLAUDE_BROKER_GIT_KEY`) all continue on `main`. The r730xd mobile-Remote-Control
workflow is unchanged.

## Postscript: the Sysbox *runtime* came back — the broker did not

`--docker` (2026-07-14) gives a session its own Docker engine so it can build images
and run containers/compose stacks, and it runs the container under
`--runtime=sysbox-runc`. That is a deliberate reuse of the **runtime** this substrate
introduced, and of nothing else: there is no broker, no worker plane, no spool, no
controller mode, no `CLAUDE_WORKER_*`. The retired flags (`--broker`, `--sysbox`,
`--worker-tarball`) remain hard errors; `--sysbox` now redirects to `--docker`, which
selects the runtime itself.

It also **inverts** this substrate's central design move. The broker chowned the inner
socket to root and mediated every launch specifically to keep the agent OFF the inner
daemon (the agent was the untrusted party). Under `--docker`, the agent using Docker
*is* the feature, so it is placed in the `docker` group and handed the socket — which
means it can reach root inside its own container. Sysbox's user namespace is what makes
that acceptable (container-root maps to an unprivileged host uid), but the consequence
is that `CLAUDE_BROKER_GIT_KEY` and `CLAUDE_EGRESS_LOCKDOWN` — both of which assume root
is separate from the agent — do not bind on a `--docker` container. See
[architecture.md](architecture.md) ("container workflows are an opt-in image variant on
Sysbox").

Worth recording for anyone reading the CC-BINS commit: it deleted `WITH_DOCKER` on the
correct grounds that the baked engine was unreachable — no runtime, no privilege, no
socket, and nothing that started `dockerd`. The Sysbox runtime is exactly the missing
piece, and `test/unit.sh` now pins the *wiring* rather than the absence, so the engine
cannot silently become dead weight again.
