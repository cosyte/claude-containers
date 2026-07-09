# The parallel worker substrate — Sysbox-nested (CC-1)

How this repo runs *containers inside a container* for the umbrella's parallel `/work-on`
workers, without handing a prompt-injectable agent a path to host root. This is the
`claude-containers` side of umbrella **ADR 0011** ("parallel worker substrate =
Sysbox-nested"); the phased plan is `operations/roadmaps/claude-containers.md` (CC-1…CC-7).

**Status:** decision accepted (founder call 2026-07-08); proven on a host only when
`bin/claude-sysbox-verify` passes there. Nothing in CC-2+ may build on a host where it
hasn't.

## The decision

The controller is a **Sysbox container** (`docker run --runtime=sysbox-runc …`) running an
**inner `dockerd`**; the K workers are **true nested children** launched by that inner
daemon. [Sysbox](https://github.com/nestybox/sysbox) puts a Linux **user namespace** on the
container: root inside the controller — and inside every nested child — maps to an
**unprivileged host uid**. The inner daemon is contained by construction, and the host's
Docker daemon is never exposed to the agent at all.

## Rejected alternatives (in writing — these are refusals, not preferences)

Two tempting shortcuts both dissolve the "blast radius of one repo" property this repo is
built around. They are **rejected**, including as fallbacks:

1. **Privileged Docker-in-Docker** (`--privileged` + nested dockerd). `--privileged` grants
   near-full host kernel access — a single injected `docker run` away from host root — and
   nested Docker under it breaks in practice anyway (storage-driver-inside-overlayfs, the
   daemon's exclusive `/var/lib/docker` lock, LSM policy conflicts, lost build cache; see
   [jpetazzo's classic write-up](https://jpetazzo.github.io/2015/09/03/do-not-use-docker-in-docker-for-ci/)).
   This is the exact posture our cap-drop hardening exists to prevent.
2. **Bind-mounting `/var/run/docker.sock` into the agent container.** Socket access **is
   host root**: anyone who can reach the daemon can
   `docker run -v /:/host --privileged …` and own the machine. Handing that to a
   semi-trusted agent deletes the container boundary entirely.

If Sysbox cannot be installed on a fleet host, the documented escalation path is the
**root-owned-broker host-sibling** model (the agent never holds a socket; a root broker
owns worker creation) — a **founder decision**, never a silent fallback. See ADR 0011.

## Version floor — a refusal, not a warning

Nested workers run under `sysbox-runc`, so the Nov-2025 runc escape CVEs
(**CVE-2025-31133 / CVE-2025-52565 / CVE-2025-52881**, fixed in runc 1.2.8 / 1.3.3 /
1.4.0-rc.3) apply to the Sysbox release line: **Sysbox v0.7.0 (2026-06-02) is the first
release that ports those patches**. `preflight_sysbox` in `bin/_common.sh` therefore
**refuses** (exits) on a missing, unregistered, or pre-0.7.0 Sysbox — unlike
`preflight_runc`, which stays warn-only because the existing flat K=1 launch path predates
nesting and its behavior must not change. `SYSBOX_MIN_VERSION` can raise the bar
fleet-wide but never lower it — that is **enforced**, not advisory: the readonly
`SYSBOX_CVE_FLOOR` constant is immovable, and `preflight_sysbox` dies on any
`SYSBOX_MIN_VERSION` below it (the same `.env`/ambient neutralize-the-gate vector as the
test seams, closed the same way).

## Host prerequisites

| Requirement | Why | This repo's check |
|---|---|---|
| Linux kernel ≥ 5.12 (≥ 5.19 preferred) | idmapped mounts replace shiftfs | `claude-sysbox-verify` phase 0 |
| User namespaces enabled | the entire containment model | `/proc/sys/user/max_user_namespaces > 0` |
| Docker installed natively (not snap), systemd | Sysbox services + runtime registration | `need_docker` + `systemctl is-active sysbox` |
| Sysbox ≥ 0.7.0 installed + registered | CVE floor above | `preflight_sysbox` |

Sysbox is a **host prerequisite this repo can verify and refuse on, but cannot supply** —
installation needs root on the host.

## Install runbook (fleet host)

Sysbox ships as a single `.deb`
([releases](https://github.com/nestybox/sysbox/releases)). This runbook is the sequence
**proven on the fleet host** (r730xd, 2026-07-08, with 63 running containers and zero
downtime). Read the maintainer scripts before trusting it on a newer release
(`dpkg-deb -e <deb> ctrl && less ctrl/config ctrl/postinst`) — the v0.7.0 behavior it is
built around:

- the **debconf `config` script aborts the whole install** (`exit 1`, package left
  half-configured) when `daemon.json` lacks `bip`/`default-address-pools` lines AND any
  container exists — it wants a Docker restart it refuses to do over live containers, and
  its "any container" test is a brittle `docker ps -a | wc -l | egrep -q "1$"` (a total of
  exactly 11/21/31… lines reads as *empty* and triggers a **restart** instead — check
  `docker ps -a | wc -l` first). **Pre-seeding the two keys makes the whole restart
  question moot**: the network branch finds nothing to change;
- the postinst then merges `runtimes."sysbox-runc"` into `daemon.json` and applies it with
  a **SIGHUP** (`runtimes` is documented reload-safe:
  [dockerd → configuration reload behavior](https://docs.docker.com/reference/cli/dockerd/)
  — running containers untouched), starts `sysbox`/`sysbox-mgr`/`sysbox-fs`, and bumps
  kernel-keyring sysctl limits (all inert until a container uses `--runtime=sysbox-runc`).

```bash
# 0) fetch + checksum (compare against the release page before installing)
wget https://github.com/nestybox/sysbox/releases/download/v0.7.0/sysbox-ce_0.7.0.linux_amd64.deb
sha256sum sysbox-ce_0.7.0.linux_amd64.deb

# 1) back up, then pre-seed the network keys with values that PIN current behavior:
#    bip = exactly what docker0 already is (ip -4 addr show docker0), and a pool base
#    covering the 172.16/12 range bridges already draw from — deliberately excluding
#    192.168.x so a future docker network can never collide with a home LAN. Existing
#    networks keep their persisted subnets regardless.
sudo cp -a /etc/docker/daemon.json /etc/docker/daemon.json.bak-cc1
sudo sh -c 'jq --indent 4 ". + {\"bip\": \"172.17.0.1/16\",
    \"default-address-pools\": [{\"base\": \"172.16.0.0/12\", \"size\": 16}]}" \
    /etc/docker/daemon.json.bak-cc1 > /etc/docker/daemon.json'

# 2) install — with the keys pre-seeded there is no restart path left; the runtime is
#    registered live via SIGHUP. (An "_apt … Permission denied" download note is cosmetic.)
sudo apt-get install -y ./sysbox-ce_0.7.0.linux_amd64.deb

# 3) confirm: runtime registered, services up, fleet untouched
docker info --format '{{json .Runtimes}}' | grep -o sysbox-runc
systemctl is-active sysbox
docker ps -q | wc -l

# 4) prove containment before building anything on it
bin/claude-sysbox-verify
```

If the install already aborted once (the half-configured `iF` state blocks every later
`apt` run): pre-seed as in step 1, then `sudo dpkg --configure sysbox-ce` — that is the
exact recovery used on the fleet host. Rollback (also container-safe):
`sudo apt-get remove -y sysbox-ce && sudo cp /etc/docker/daemon.json.bak-cc1
/etc/docker/daemon.json && sudo kill -SIGHUP "$(pidof dockerd)"`.

## Verification — `bin/claude-sysbox-verify`

Run `--check` for host prerequisites only; run bare for the full stand-up + containment
proof. The full run stands up a small Sysbox controller (`docker:28-dind`, 1 CPU / 1 GB /
512 pids), launches one true nested child through the inner daemon, and asserts:

- **userns containment** — `/proc/self/uid_map` inside the controller *and* the nested
  child shows container-root → a non-root host uid; the child's process is owned by that
  non-root uid in the **host's** `ps`.
- **No host-daemon exposure** — the inner daemon ID differs from the host's; inner
  `docker ps` cannot see host containers; a device-node grab (`mknod` of a block device)
  is refused.
- **cgroup limits enforce inside** (the nested-cgroup "shadowing" caveat): `memory.max` /
  `pids.max` read back exactly as set on the controller, and an over-limit nested
  container is OOM-killed **in isolation** — controller and inner daemon survive.
- **The version floor refuses** — a simulated pre-patch Sysbox (0.6.7) is rejected by
  `preflight_sysbox`.

It prints an evidence block formatted for ADR 0011's pending-verification checklist and
exits non-zero if any proof fails. The exhaustive resource-isolation matrix (per-worker
OOM/fork-bomb budgets at K) is `bin/claude-sizing-verify` (CC-3, below); disk budgets are
**CC-5**'s scope (Storage/disk safety, below).

## K-aware resource sizing (CC-3)

The controller's cgroup caps the **sum** of its nested children, so it must be sized for
**Σ(K workers) + its own overhead** (inner dockerd + broker). Everything is derived from
two inputs, each with one home:

- **K** — read from the umbrella `operations/parallel.config.json` by
  `resolve_parallel_k` (`bin/_common.sh`), looked up via `$CLAUDE_PARALLEL_CONFIG`, the
  umbrella-submodule layout (`../operations/…`), or the in-container workspace
  (`/workspace/operations/…`). **One source of truth — K is never defined in this repo.**
  No config found → the documented umbrella default K=2, loudly; a config that is found
  but unparseable **refuses** (a garbage K silently becoming 2 could under-size a
  controller that then overcommits).
- **The per-worker profile** — `CLAUDE_WORKER_MEM/…_MEM_RESERVATION/…_CPUS/…_PIDS/…_SHM`
  (defaults `4g / 3g / 2 / 2048 / 2g`), single-sourced in `bin/_common.sh` and consumed
  by the broker's fixed template, the envelope math, and the verify scripts alike.

`bin/claude-controller-size` prints the derived envelope (`--flags` emits the docker-run
argv). With the defaults, **K=2 → 5 CPUs / 10240 MiB (reservation 8192 MiB) / 5120 pids**
(the roadmap §5 table; the K=4 ceiling — 9 CPUs / 18 GiB — is deferred to the umbrella
`PAR-7.1` founder ramp). Worker `shm` needs no separate controller term: it is tmpfs
charged to each worker's own memory cgroup, i.e. it rides inside the per-worker
`--memory` cap.

**Overcommit is a refusal, not a warning**, at both ends:

- `claude-controller-size` refuses (with the deficit) when the envelope exceeds the
  host's CPUs/MemTotal;
- the broker refuses to **serve** (startup refusal 5, `broker_check_capacity`) when
  Σ(its worker cap · profile) + overhead exceeds the controller's **own** cgroup budget —
  read from `memory.max` / `pids.max` / `cpu.max` as Sysbox presents them, falling back
  to `/proc/meminfo` / `nproc` when unlimited. An undersized controller never quietly
  admits workers whose bursts could OOM a peer or the inner daemon.

The flat K=1 session path inherits the same guards: `claude-launch` and the generated
compose services carry `--memory-reservation` **derived at 75 % of the effective limit**
(so a per-repo `--mem` / per-host limit override can never invert reservation > limit —
dockerd rejects that) and `--pids-limit`. The static `docker-compose.yml` also carries
`pids_limit`, but raw `docker compose` cannot run the derivation, so its reservation is
**opt-in** (`CLAUDE_MEM_RESERVATION`, default `0` = disabled) — if you set it alongside a
lowered `CLAUDE_MEM_LIMIT`, keep it below the limit.

### Verification — `bin/claude-sizing-verify`

The on-host proof (needs Sysbox; run `claude-sysbox-verify` first): generated flags match
the K-derived budget and an impossible K refuses with the deficit; controller **and**
worker limits read back exactly as set *inside* the Sysbox container (the shadowing
caveat — verified, not assumed); a worker driven over `--memory` is OOM-killed **in
isolation** (peer worker, controller, and inner daemon all survive); a fork-bomb hits
`--pids-limit` and harms no peer; a broker whose cap needs more than its controller's
budget refuses to serve. The docker-free math/refusal matrix runs in CI
(`test/sizing-unit.sh`). **Run `claude-sizing-verify` green on the fleet host before
CC-6 wires controller mode — it is the K>1 precondition this doc's limits table points
at.**

### ZFS note (this fleet)

Older Sysbox reports ([#849](https://github.com/nestybox/sysbox/issues/849)) show inner
Docker failing on ZFS-backed hosts — overlayfs historically couldn't use a ZFS upperdir.
OpenZFS ≥ 2.2 supports overlayfs upperdirs (the current fleet host runs OpenZFS 2.3 and
already runs the *host* daemon as `overlay2` on ZFS). The nested proof exercises this
empirically: the inner daemon pulls an image and runs containers, so a ZFS/overlay
incompatibility fails the proof rather than surfacing later in a worker.

## Worker lifecycle (CC-4)

Two pieces close the loop between "the broker launches a worker" (CC-2) and "the worker
is gone and its slot is free again": a one-shot run driver inside each worker, and a
reaper alongside the broker that mops up whatever an unclean exit leaves behind.

### `bin/claude-worker-run` — the worker's one-shot command

The broker's `CLAUDE_BROKER_WORKER_CMD` now defaults to `claude-worker-run` (was the
CC-2 placeholder `sleep infinity`); `broker_launch` appends the request's validated
`<repo> <item>` as trailing argv, so a worker's actual command line is
`claude-worker-run <repo> <item>`. Inside the worker it:

1. re-validates `<repo>`/`<item>` against the same charset the broker already enforced
   (belt-and-suspenders — a worker could in principle be driven directly, not just via
   the broker);
2. locates the umbrella (`CLAUDE_WORKER_UMBRELLA`, else `/workspace`) — **fails closed**
   if neither has both `.gitmodules` and `scripts/isolate.sh`;
3. confirms `<repo>` is a real submodule listed in `.gitmodules` — refuses an unknown
   repo name outright;
4. materializes an isolated worktree via `scripts/isolate.sh` and exports
   `COSYTE_WORKTREE` (the isolation contract `/work-on` itself builds on);
5. starts a best-effort background lease-heartbeat loop (`scripts/lease.sh renew`,
   default every `CLAUDE_WORKER_HEARTBEAT_SECS=60`) if `scripts/lease.sh` exists —
   never fails the run if it's absent or a renew fails;
6. runs **exactly one** `/work-on <repo> <item>` via `claude -p … --output-format json`
   and exits with that run's status.

Because the broker launches every worker `--rm`, a clean exit here makes the container
vanish with **no residue** — nothing to reap. `CLAUDE_WORKER_RUN_DRYRUN=1` prints the
resolved isolate + `claude` invocation plan without touching docker/claude/the umbrella
(unit-tested in `test/worker-run-unit.sh`, which asserts the plan names `/work-on`
exactly once — never a loop).

### `bin/claude-reaper` — mopping up what `--rm` missed

An **unclean** exit (a `kill -9`, an OOM, an inner-daemon restart mid-run) can leave a
worker container behind despite `--rm`, and can orphan broker-spool files. The reaper
runs two idempotent, fail-safe duties:

1. **Remove dead worker containers.** Queries `claude.worker=1` containers with
   `status=exited` / `dead` / `created` and removes them — freeing the container name so
   a re-request of the same item doesn't hit a docker name conflict. **Running workers
   are never touched** (the status filter is exact), and if a status can't be determined
   the reaper skips it rather than guessing (fail closed on ambiguity).
2. **Prune the broker spool** (`$CLAUDE_BROKER_DIR`, default `/run/claude/broker`):
   `responses/` files older than `CLAUDE_REAPER_SPOOL_TTL` (default 3600s), plus orphaned
   `requests/`/`staging/` files past the same age. `.lock` is never touched. Missing
   directories are a silent no-op (a controller that never started the broker has no
   spool yet).

Every docker call funnels through one `reaper_docker()` wrapper (the unit-test stub
point); a docker or spool error is a loud `warn` and the reap continues — it never
`die`s mid-cycle, and under `--loop` one bad cycle logs and moves on. Run modes:

```
bin/claude-reaper           # one-shot: reap once, print counts, exit 0
bin/claude-reaper --loop    # reap every CLAUDE_REAPER_INTERVAL seconds (default 300), forever
```

In controller mode (`CLAUDE_WORKER_BROKER=1`), `entrypoint.sh` starts `claude-reaper
--loop` as root alongside the broker, logging to `/var/log/claude-reaper.log`.
`CLAUDE_REAPER_DRYRUN=1` reports what it would remove/prune without changing anything.

### Verification

The docker-free logic (arg validation, umbrella/submodule checks, run-exactly-once;
exited/dead/created selection, spool-file age selection, idempotency, fail-safe-on-error)
runs in CI: `test/worker-run-unit.sh` and `test/reaper-unit.sh`. The on-host proof —
needs Sysbox + the broker proven first — is `bin/claude-worker-lifecycle-verify`: a
broker-launched worker (a trivial stub swapped in for the real `claude-worker-run` via
`CLAUDE_BROKER_WORKER_CMD`, since a real run needs `claude` credentials the verify
script doesn't have) runs once and vanishes with no residue; a `kill -9`'d worker is left
as `exited`, then the reaper removes it and the freed name is proven reusable; a second
reap over clean state is a no-op; an aged `responses/` file is pruned while a fresh one
and `.lock` are kept. `bin/claude-worker-lifecycle-verify --check` runs the arg/selection
half safely on any host (no Sysbox needed).

## Storage/disk safety (CC-5)

Nested workers (CC-2/CC-4) land their image/container/build-cache layers on the
controller's **inner dockerd data-root** — by default `/var/lib/docker` inside the
controller. Left unmanaged, that fills the host across enough worker cycles. CC-5 closes
this with two halves — a runtime refusal and a scheduled reclaim — plus two structural
requirements that CC-6 wires and this doc documents + the verify script asserts.

### The free-space floor (broker refusal)

`bin/_common.sh`'s `disk_free_mib <path>` prints the free space, in integer MiB, on the
filesystem holding `<path>` — parsed from `df -P -B1M <path>`'s "Available" column.
**Fails closed**: an unreadable/missing path, a `df` error, or unparseable output all
return nonzero/empty rather than ever being misread as "plenty of free space" — the one
failure mode that could wedge the host by letting a launch through blind.
`CLAUDE_DISK_FREE_MIB_OVERRIDE` forces the value for tests (loud `TEST SEAM ACTIVE` warn).

The broker (`bin/claude-worker-broker`) reads `CLAUDE_DISK_FLOOR_MIB` (default `10240` =
10 GiB) and `CLAUDE_DISK_DATA_ROOT` (default `/var/lib/docker`, the inner dockerd
data-root) and calls `broker_check_disk` **per launch** — in `broker_process_request`,
right before `broker_launch`, mirroring the worker-cap-reached refusal exactly. Unlike the
CC-3 capacity check (a **startup** refusal — the controller's own cgroup budget doesn't
change while it's serving), free disk drains and refills continuously as workers run and
`claude-disk-gc` reclaims, so this must be re-checked on every launch, not just once at
boot. On refusal: `broker_respond "$id" "error disk pressure: <free> MiB free < floor
<floor> MiB on <data-root> — retry after gc"`, logged, staging cleaned, and the handler
returns 0 — the item is never partially launched and stays retry-able, exactly like every
other broker refusal path. **Fails closed**: if free space can't be determined at all, the
launch is refused with a "could not determine free space" message, never silently allowed.

### The GC timer (`bin/claude-disk-gc`)

Scheduled Docker GC on the inner daemon so nested-worker layers + build cache don't
accumulate unbounded. Runs **both** `docker system prune -f` (dangling images, stopped
containers, unused networks) **and** `docker builder prune -f` (the build cache —
`system prune` alone does not touch it), reporting free space before/after + reclaimed.
**Never** touches a running container or a volume: plain `-f` with no `-a`/`--all`/
`--volumes` only ever reaps stopped/dangling/unused resources, so a live worker's image
layers and data are untouched by construction — `disk_gc_plan` is unit-tested to assert
exactly that shape. One-shot by default; `--loop` runs every `CLAUDE_DISK_GC_INTERVAL`
seconds (default 3600). Fail-safe like the reaper: a docker error on either prune is a
loud `warn`, the other prune still runs, and under `--loop` one bad cycle logs and
continues — it never dies mid-cycle. `CLAUDE_DISK_GC_DRYRUN=1` prints the prune commands
without running them. In controller mode (`CLAUDE_WORKER_BROKER=1`), `entrypoint.sh`
starts `claude-disk-gc --loop` as root alongside the broker + reaper, logging to
`/var/log/claude-disk-gc.log`.

### Sized data-root + image reuse (structural requirements)

Two things the free-space floor and the GC timer *watch* rather than *are* — required for
either to mean anything on a real fleet host:

- **A sized data-root volume.** The floor and GC operate on whatever filesystem backs
  `CLAUDE_DISK_DATA_ROOT`. If the Sysbox controller's inner `/var/lib/docker` is backed by
  the controller's own (unbounded) root filesystem, worker layers can still fill the
  **host** root fs even while the floor correctly reports "plenty free" on that path — the
  floor is only as good as the volume it's measuring. **CC-6 wires the actual controller
  launch to mount a sized volume at the inner data-root**; CC-5's job is documenting the
  requirement and building the floor that watches it once that volume exists.
- **Image reuse, not per-worker rebuild.** Workers already reuse the prebuilt
  `CLAUDE_WORKER_IMAGE` (`claude-code-box`, the broker's fixed template — CC-2/CC-4): the
  broker's `broker_launch` runs `docker run … "$WORKER_IMAGE" …`, never `docker build`, so
  no worker cycle adds a new image layer set. This is disk-safety-**by-construction** — it
  bounds per-cycle growth to container/log/cache churn rather than image storage, which is
  what makes the floor + GC combination tractable in the first place. `bin/claude-disk-verify`
  asserts it on the real path (same image ID + created-time across two workers).

### Verification — `bin/claude-disk-verify`

The docker-free logic (`disk_free_mib` parsing + fail-closed behavior, the
`broker_check_disk` refusal matrix, `disk_gc_plan`'s never-`-a`/`--volumes` shape, and
`disk_gc_once`'s fail-safe posture) runs in CI: `test/disk-unit.sh`. The on-host proof —
needs Sysbox + the broker proven first — is `bin/claude-disk-verify`: N sequential worker
cycles with `claude-disk-gc` run between them don't grow disk unbounded; a launch under an
absurdly-high `CLAUDE_DISK_FLOOR_MIB` is refused with "disk pressure" on the real broker
path; the worker image's ID + created-time are identical across workers (reused, never
rebuilt). `bin/claude-disk-verify --check` runs the docker-free half safely on any host (no
Sysbox needed) — the same logic test/disk-unit.sh covers, re-run here for a one-command
fleet-host sanity pass alongside the other `*-verify --check` scripts.

## Known limitations (do not over-trust)

- Sysbox isolation is **stronger than runc, weaker than a VM/gVisor/Kata**. A container —
  Sysbox included — is **not** a security boundary against a fully-weaponized agent;
  multi-tenant/hostile-tenant use stays a non-goal (see README).
- This substrate makes K>1 **runnable and safe**; it does not raise K. The ramp is
  founder-gated umbrella-side (`PAR-7.1`).
- The flat, unprivileged K=1 leaf-container path is completely unchanged — `sysbox-runc`
  is used only where a controller must run nested workers.
- Every capability here builds **on top of** the Sysbox floor; a green
  `claude-sysbox-verify` is each one's precondition, not its proof. The **root-owned worker
  broker (CC-2) is built**: `bin/claude-worker-broker` owns worker creation on the inner
  daemon (fixed hardened template, deny-by-default requests, lease discipline; the agent
  never touches the inner socket) and fails closed without userns containment + a
  host-attested CVE-patched Sysbox — its own on-host proof is `bin/claude-broker-verify`.
  The **K-aware sizing (CC-3) is built** (section above), with one open proof:
  `bin/claude-sizing-verify` has **not yet run on the fleet host** (it was built on a box
  without Sysbox) — run it green there before CC-6 turns controller mode on. The sizing
  numbers themselves are §5 *starting* values, re-measured under CC-7/`PAR-6.1` before
  any K-ramp. The **worker lifecycle (CC-4) is built** (section above): the broker now
  drives every worker through `claude-worker-run`'s one-shot-then-exit contract, and
  `claude-reaper` mops up unclean-exit residue + spool litter; its own on-host proof,
  `bin/claude-worker-lifecycle-verify`, has **not yet run on the fleet host** either (same
  reason — built on a box without Sysbox) — run it green there alongside
  `claude-sizing-verify` before CC-6. The **storage/disk safety (CC-5) is built** (section
  above): the broker refuses a launch under `CLAUDE_DISK_FLOOR_MIB` free space on the inner
  data-root, and `claude-disk-gc --loop` reclaims image/build-cache layers alongside the
  broker + reaper; its own on-host proof, `bin/claude-disk-verify`, has **not yet run on the
  fleet host** either (same reason) — run it green there too before CC-6. CC-5 assumes CC-6
  mounts a **sized volume** at the inner data-root; until then the floor is watching an
  unbounded path and only bounds the *rate* workers can fill it, not the ceiling.
