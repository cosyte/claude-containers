# claude-containers shared tool cache = one `/cache` volume, fail-safe, bounded

**Status:** ACCEPTED — 2026-07-11. This is the design record for how provisioned
toolchains and package downloads are **reused across container restarts and across parallel
workers**. It builds directly on the toolchain provisioner in
[`docs/toolchain-provisioning.md`](toolchain-provisioning.md) and the containment in
[`docs/package-provisioning-security.md`](package-provisioning-security.md), and
**inherits, never re-decides, them**. The design record is this file.

## What shipped

A single shared **`/cache`** tree holds mise's install store **and** the language
package-manager caches, so a toolchain or CLI provisioned by one container is a **cache hit**
for the next launch of that project and for every parallel worker on the host — no re-download.

```
/cache
├── mise/        MISE_DATA_DIR — installed toolchains (installs/), shims/, downloads/, cache/
├── cargo/       CARGO_HOME — installed bins (bin/) + registry cache
├── go/          GOPATH — pkg/mod (module cache) + bin
├── npm/         npm_config_cache
├── uv/          UV_CACHE_DIR (also serves mise `pipx:` via uv)
└── pip/         PIP_CACHE_DIR
```

`claude-launch` mounts a **shared docker named volume** (default `claude-cache`) at `/cache`;
`claude-compose-gen` mounts the **same** volume into every service in a stack. Because every
container runs **this** image (same OS/arch), mise's cross-machine store caveat¹ does not
apply, so the install store is safe to share.

```bash
claude-launch myproj --repo …              # cache ON by default (claude-cache at /cache)
claude-launch myproj --repo … --cache teamcache   # a differently-named shared volume
claude-launch myproj --repo … --no-cache   # opt out → per-container installs
claude-compose-gen --out stack.yml --org your-org …          # one shared cache across the stack
claude-compose-gen --out stack.yml --no-cache …            # per-container installs
```

## How it's wired

1. **Baked, owned, fail-safe (`Dockerfile`).** The `/cache` subtree is created in the image
   and `chown`ed to the `claude` user (UID 1000). This makes the design **fail-safe by
   construction**:
   - **Volume mounted** → docker seeds the fresh named volume from the image's `/cache`
     (ownership preserved), and every container/worker shares it.
   - **No volume** → `/cache` is just the image-layer dir. Provisioning still works; writes
     land in the container's own writable layer (per-container, ephemeral). **A missing or
     again-empty cache never errors a launch** — it only forgoes the cross-container hit.

2. **Env points the tools at `/cache` (`Dockerfile` ENV).** `MISE_DATA_DIR`, `CARGO_HOME`,
   `GOPATH`, `GOMODCACHE`, `npm_config_cache`, `UV_CACHE_DIR`, `PIP_CACHE_DIR` all resolve
   under `/cache`. The **agent** (the Claude Code process + its non-interactive `bash -c`
   calls) inherits these from the image ENV. `PATH` prepends `/cache/mise/shims` (so the
   agent resolves mise-installed tools with no shell activation — the provisioner's guarantee, just
   relocated) plus `/cache/cargo/bin` and `/cache/go/bin` (so `cargo install` / `go install`
   CLIs resolve too).

3. **Interactive shells stay consistent (`~/.bashrc`).** An SSH login normally attaches to
   the tmux session the entrypoint started, which already carries the image ENV. A *fresh*
   non-tmux fallback shell would **not** inherit it, so the interactive-activation
   block re-exports the cache dirs (`${VAR:-/cache/…}`) **before** `eval "$(mise activate
   bash)"` — a human who SSHes in to debug uses the same shared store as the agent, never the
   home default.

4. **Read-mostly share + per-worker write discipline.** Version **selection** is
   per-container: mise reads `/workspace/mise.toml`, and `/workspace` is a *per-container*
   mount — so two workers can pin different versions without fighting over a shared "active"
   pointer. The **install store** is content-addressed by version (`installs/<tool>/<ver>`),
   and each package manager (mise, cargo, go, npm, uv) locks its own writes, so concurrent
   workers **append** to the shared store without corrupting each other. The share is
   therefore read-mostly: the common case is a hit (read); a miss is one worker's guarded
   write that becomes every worker's next hit.

## Bounding the cache

The `/cache` volume is a **named** volume, so `claude-disk-gc`'s `docker system prune -f` /
`builder prune -f` deliberately never touch it. `claude-disk-gc` is a standalone
maintenance tool (run it by hand or on your own cron/timer) that spans it:

- **Free-space reporting.** The shared volume lives on the docker data root
  (`CLAUDE_DISK_DATA_ROOT`, default `/var/lib/docker`), so a filling cache lowers the free
  space `claude-disk-gc` reports before/after each cycle.

- **Reclaim — the cache trim.** Each `claude-disk-gc` cycle also runs a **cache
  trim** (`cache_gc_once`). When the volume exceeds `CLAUDE_CACHE_MAX_MIB` (default 20 GiB) it
  removes **only the re-fetchable download/registry caches** — the installed toolchains,
  shims, and `cargo`/`go` bins are **kept**, so a trim frees space without un-provisioning a
  tool (the next use just re-downloads any evicted archive). The exact reclaimed paths are a
  fixed, golden-tested list:

  ```
  /cache/mise/downloads   /cache/mise/cache
  /cache/cargo/registry/cache   /cache/cargo/registry/src
  /cache/go/pkg/mod/cache/download
  /cache/npm/_cacache   /cache/uv   /cache/pip
  ```

  The trim is **fail-safe and idle-gated**: it is a no-op when the cache is disabled, when its
  size can't be measured (fail-soft — unknown ⇒ do not trim), when it is under budget, and —
  critically — **while any container mounting the cache is running** (the guard is `docker ps
  --filter volume=<vol>`, so it covers every `claude-launch`/compose container that mounts
  `/cache`, gating on the volume rather than a narrower label). An `rm` of a download cache
  mid-install would break that install, so the trim only runs when the cache is idle. The
  reclaim itself is a throwaway root `/bin/sh` helper that mounts **only** the cache volume and
  `rm -rf`s the fixed list — never `-a`, never `--volumes`, never a host path.

  **Residual (bounded) race.** There is a narrow TOCTOU window between the idle check and the
  `rm`: a container that starts *after* the `docker ps` check but *before* the helper runs
  could have an in-flight download cache removed. This is **contained by design, not
  eliminated** — the trim only ever removes **re-fetchable** paths, so the worst case is a
  transient failed/retried install (the tool re-downloads), never loss of an installed
  toolchain or any persistent data. gc runs hourly by default, so the window is rare. Closing
  it entirely (a lock the launch path also takes) is deferred; the fail-safe surface makes it
  a non-issue in practice.

  ```bash
  claude-disk-gc                 # one-shot: docker prune + cache trim
  claude-disk-gc --loop          # every CLAUDE_DISK_GC_INTERVAL seconds
  claude-disk-gc --no-cache-trim # docker prune only (skip the shared-cache trim)
  ```

## Verification

CI runs `test/cache-unit.sh` — a docker-free, network-free static + function-level gate
asserting: the `/cache` relocation is present and the tree is baked + chowned (fail-safe); the
`_common.sh` cache helpers normalize/disable/measure correctly; the disk-gc cache trim plan is
**exactly** the re-fetchable list and **never** an `installs/`/`shims/`/bin path or a bare
`/cache`; `cache_gc_once` trims only when over budget **and** idle, and is fail-safe on unknown
size / disabled cache; and `claude-launch` / `claude-compose-gen` mount the shared cache and
honor `--no-cache`. `test/mise-unit.sh` additionally proves the relocated shims dir is still on
`PATH` for the agent and `/workspace`-only config trust is intact.

`bin/claude-disk-verify` re-runs the docker-free cache-trim safety (the plan is
re-fetchable-only, and the idle guard gates on the cache **volume** so it covers every
`claude-launch`/compose container) as a one-command sanity pass. The **live proof** needs
a full image build and is the manual on-host procedure below (like `make smoke`). As UID
1000, with no `sudo`, cache **on** (the default):

```bash
# session A provisions; session B is a HIT
claude-launch a --repo … ; ssh … 'mise use node@22'          # downloads to /cache/mise
claude-launch b --repo … ; ssh … 'time mise use node@22'     # cache hit — no refetch

# fail-safe: no cache volume → per-container install, launch never errors
claude-launch c --repo … --no-cache ; ssh … 'mise use node@22'   # works, ephemeral

# bounded: over-budget trim reclaims the download caches, keeps installs
CLAUDE_CACHE_MAX_MIB=1 claude-disk-gc         # trims re-fetchable caches; node@22 still resolves
```

## The trust boundary (inherited + new)

A single cache **shared across every container on a host** is a shared-fate surface: a package
one container fetches is reused by the others. This is **acceptable and bounded**, not a new
hole:

- The containers on a host are **one operator's fleet** — the same trust domain that already
  shares the git-key broker and the auth volume.
- **What can enter the cache is still governed by the egress containment**: under `CLAUDE_EGRESS_LOCKDOWN=1`
  only the curated, IP-pinned registries are reachable, and credentials are unreachable
  during a fetch. The cache holds tool binaries and **public** package archives — **no repo
  content, no secrets, no PHI** (repos live in per-container `/workspace`, credentials in the
  per-container config volume, neither of which is `/cache`).
- The cache is **reconstructible**: nothing in it is authoritative. A trim, a `docker volume
  rm claude-cache`, or a `compose down -v` loses only speed, never correctness.

## Non-goals

- **Not a security boundary.** The shared cache sits on top of the egress containment and the manifest hardening
  (script hardening); it does not replace them. It does not add isolation between co-tenant
  workers beyond what they already share.
- **No cross-host sharing.** `/cache` is a per-host docker volume. Sharing a store across
  physically different hosts is exactly mise's cross-machine caveat¹; a pull-through proxy
 used to offer that, but was retired (docs/legacy-sysbox-broker.md).
- **No system `.so` libraries.** Inherited from the mise provisioner: the cache holds binaries and language
  packages, never system libraries — no self-service path provisions those (the worker-tier apt
  path that used to close that gap has been retired; see docs/legacy-sysbox-broker.md).

---

¹ mise warns that its data dir is not portable across machines with different OS/arch. Every
container here runs the same image, so the store is portable across containers **on one host**
— which is exactly the sharing scope of a docker named volume.
