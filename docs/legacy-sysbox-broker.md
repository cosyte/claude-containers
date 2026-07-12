# Legacy: Sysbox nested-broker path (frozen 2026-07-12)

The nested-Sysbox worker-broker substrate — the CC-1 through CC-7 chain plus the
PKG-1 through PKG-6 supply-chain hardening built on top of it — was retired as
the parallel-`/work-on` substrate on **2026-07-12** in favor of **Claude Code
subagents in per-worktree git worktrees**. The code is frozen (unchanged) on a
preservation branch and a preservation tag on this repo:

- **Branch:** [`legacy/sysbox-broker-2026-07-12`](https://github.com/cosyte/claude-containers/tree/legacy/sysbox-broker-2026-07-12)
- **Tag:** `legacy-sysbox-broker-2026-07-12` (annotated, points at the same commit)
- **Commit at the freeze:** [`a334902`](https://github.com/cosyte/claude-containers/commit/a334902) — `feat: durable worker image + compose-gen --broker (#25)`
- **Umbrella pointer at the freeze:** `cosyte/cosyte@8f9d664` (SC plan + ADR 0013 landed 2026-07-12)

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

**`SC-6` scope after this strip.** Of the original controller tier, only
`bin/claude-controller` survives — now a thin pass-through that `exec`s
`claude-autopilot` (its `slots>1` broker-dispatch loop went with the broker).
`SC-6` decides whether that pass-through still earns its place, and should also
reassess `bin/claude-reaper`: its worker-container-reaping duty was broker-tied
and is gone, leaving a spool-pruning duty whose spool no surviving code writes
to. `PKG-2`/`PKG-3`/`PKG-5` mechanisms (`mise` toolchain + shared `/cache` +
`ignore-scripts`/`lockfile=true`) are **not** broker-tied and stay on `main` —
the strip is broker + Sysbox + PKG-4 (curated apt) + PKG-6 (pull-through cache
proxy) only.

## Why we retired it

- **Blast radius was already contained by the outer controller container.** The
  nested Sysbox layer duplicated the protection the leaf already provides. A
  prompt-injectable agent's blast radius is one repo either way — the outer
  container is the boundary.
- **Observability collapsed under the broker.** The unprivileged coordinator
  couldn't `docker ps` or `docker logs` into workers (root-only), so debugging
  a stuck worker was guess-and-tail-the-broker. Subagent stdout returns to the
  parent directly; `SendMessage` reaches a running subagent.
- **Cold-start cost was real.** Each broker worker cloned the umbrella (or
  hydrated from a tarball), warmed `mise`, installed deps. Subagents inherit
  the warm tree at zero marginal cost.
- **Coordinator ⇄ worker was one-way with the broker, two-way with subagents.**
  Mid-flight guidance was impossible over the broker spool; native with
  `SendMessage` on a subagent's `agentId`.
- **The workload isn't a fleet.** Solo founder + one controller + mobile
  Remote Control ≠ the multi-tenant unattended-fleet scale the broker was
  designed for.

Full rationale, decisions, and reversibility contract: umbrella
`operations/plans/SUBAGENT-COCKPIT-PLAN.md` and ADR 0013
(`documentation/decisions/0013-subagent-first-cockpit.md`), which supersedes ADR
0011 and amends the substrate clause of ADR 0010.

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

The Remote-Control core (SSH → tmux → Claude Code), unattended `/next`
autopilot, launch/compose-gen (minus broker flags), housekeeping (reaper,
disk-gc, healthcheck), baked config (`claude-config/`), and the security floor
(secret guard, egress firewall) all continue on `main`. The r730xd
mobile-Remote-Control workflow is unchanged.
