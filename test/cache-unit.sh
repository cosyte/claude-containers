#!/usr/bin/env bash
# cache-unit.sh — pure-static + function-level tests for the PKG-3 shared tool cache.
# NO docker, NO network, NO image build — safe for CI / scripts/verify.sh.
#
# PKG-3 points mise's install store + the cargo/go/npm/uv/pip caches at ONE shared /cache
# volume, so a toolchain/CLI provisioned by one container is a cache hit for the next and
# for parallel workers, bounded by a fail-safe trim. The LIVE proof (two sessions reuse a
# cached install, real trim reclaim, no cross-worker corruption, a missing cache degrades
# to per-container installs) needs a real build and is the on-host manual gate documented
# in docs/shared-tool-cache.md; bin/claude-disk-verify additionally re-runs the
# docker-free cache-trim safety here as a one-command sanity pass. Here we prove the
# WIRING is present and correctly scoped:
#   - the Dockerfile relocates the caches to /cache and keeps it fail-safe (baked, chowned)
#   - the _common.sh cache helpers (name normalization, mount args, size measurement)
#   - the claude-disk-gc cache trim (fixed re-fetchable-only plan; idle-only; fail-safe)
#   - claude-launch / claude-compose-gen mount the shared cache and honor --no-cache
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERFILE="$REPO_ROOT/Dockerfile"

# Source claude-disk-gc ONCE — it pulls in bin/_common.sh transitively, so the cache_*
# helpers AND the disk-gc cache trim are all defined in this one process. Sourcing
# _common.sh a SECOND time in the same process is fatal (a repeated `readonly` under
# set -e), so everything that needs those functions rides this single source; anything
# needing a clean run goes through a fresh `bash -c` / subprocess (compose-gen below).
# shellcheck disable=SC1091
source "$REPO_ROOT/bin/claude-disk-gc"
set +e   # _common.sh sets -e; this harness counts failures instead of dying on the first

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

echo "PKG-3 shared tool cache"

# ============================================================================
echo "== Dockerfile: caches relocated to the shared /cache tree, fail-safe =="
# ============================================================================
# The /cache tree is baked + chowned to the claude uid so it works as a mounted shared
# volume (docker seeds a fresh named volume from it) AND as a plain image-layer dir when
# no volume is mounted (per-container installs — the fail-safe).
grep -Eq 'mkdir -p /cache/mise' "$DOCKERFILE" \
  && ok "the /cache tree (mise/cargo/go/npm/uv) is created in the image" \
  || bad "no 'mkdir -p /cache/mise …' — /cache would not exist for the unmounted (fail-safe) case"
grep -Eq 'chown -R \$\{CLAUDE_UID\}:\$\{CLAUDE_GID\} /cache' "$DOCKERFILE" \
  && ok "/cache is chowned to the claude uid (writable rootless; volume seed keeps ownership)" \
  || bad "/cache is not chowned to the claude uid — a mounted volume/per-container dir would be root-owned"

# The install store + language caches must point INTO /cache (the shared surface).
for kv in \
  'MISE_DATA_DIR=/cache/mise' \
  'CARGO_HOME=/cache/cargo' \
  'GOPATH=/cache/go' \
  'GOMODCACHE=/cache/go/pkg/mod' \
  'npm_config_cache=/cache/npm' \
  'UV_CACHE_DIR=/cache/uv' \
  'PIP_CACHE_DIR=/cache/pip'; do
  if grep -Fq "$kv" "$DOCKERFILE"; then ok "ENV $kv → shared cache"; else bad "ENV $kv missing — that cache would not be shared"; fi
done

# shims (now under /cache) prepended to PATH for the non-interactive agent; PATH preserved.
grep -Fq 'PATH=/cache/mise/shims:' "$DOCKERFILE" && grep -Fq ':${PATH}' "$DOCKERFILE" \
  && ok "the /cache/mise/shims dir is prepended to PATH (agent resolves cached tools), PATH preserved" \
  || bad "/cache/mise/shims is not prepended to PATH — the agent would not find cached tools"

# interactive consistency: a fresh SSH shell that did NOT inherit the Dockerfile ENV must
# still activate mise against the SHARED store (bashrc re-exports before `mise activate`).
grep -Eq 'export MISE_DATA_DIR="\$\{MISE_DATA_DIR:-/cache/mise\}"' "$DOCKERFILE" \
  && ok "~/.bashrc re-exports MISE_DATA_DIR=/cache/mise (interactive shells share the store too)" \
  || bad "~/.bashrc does not re-export MISE_DATA_DIR — a non-tmux interactive shell would diverge from the cache"

# ============================================================================
echo "== _common.sh: cache name / mount-arg / size helpers =="
# ============================================================================
[[ "$(cache_name)" == "claude-cache" ]] \
  && ok "cache_name default is 'claude-cache'" || bad "cache_name default wrong: '$(cache_name)'"
disabled_ok=1
for v in "" off none 0 false no; do [[ -z "$(cache_name "$v")" ]] || disabled_ok=0; done
(( disabled_ok )) && ok "cache_name treats ''/off/none/0/false/no as disabled" \
  || bad "cache_name did not disable on a documented off-value"
[[ "$(cache_name teamcache)" == "teamcache" ]] \
  && ok "cache_name passes through a custom volume name" || bad "cache_name mangled a custom name"

mnt="$(cache_mount_args | tr '\n' ' ')"
[[ "$mnt" == "-v claude-cache:/cache " ]] \
  && ok "cache_mount_args emits '-v claude-cache:/cache' by default" \
  || bad "cache_mount_args default wrong: '$mnt'"
[[ -z "$(cache_mount_args off)" ]] \
  && ok "cache_mount_args emits nothing when disabled (no mount → per-container installs)" \
  || bad "cache_mount_args should emit nothing when disabled"

got="$(CLAUDE_CACHE_SIZE_MIB_OVERRIDE=4096 dir_size_mib /nonexistent 2>/dev/null)"
[[ "$got" == "4096" ]] \
  && ok "dir_size_mib honors the CLAUDE_CACHE_SIZE_MIB_OVERRIDE test seam" \
  || bad "dir_size_mib override seam broken (got '$got')"
if dir_size_mib "/no/such/cache/path/PKG-3" >/dev/null 2>&1; then
  bad "dir_size_mib must fail on a missing path (fail-soft: unknown size ⇒ do not trim)"
else
  ok "dir_size_mib fails on a missing path (unknown size ⇒ trim is skipped)"
fi

# ============================================================================
echo "== claude-disk-gc: the cache trim is fixed, re-fetchable-only, idle-only, fail-safe =="
# ============================================================================
# GOLDEN: the trim plan must stay exactly the re-fetchable download/registry caches —
# never an installs/ dir, never /cache itself, never a shims dir (those would un-provision
# a tool or wipe the whole shared store).
mapfile -t PLAN < <(cache_gc_plan)
EXPECTED=(
  /cache/mise/downloads
  /cache/mise/cache
  /cache/cargo/registry/cache
  /cache/cargo/registry/src
  /cache/go/pkg/mod/cache/download
  /cache/npm/_cacache
  /cache/uv
  /cache/pip
)
if [[ "${PLAN[*]}" == "${EXPECTED[*]}" ]]; then
  ok "cache_gc_plan is exactly the fixed re-fetchable-cache list (golden)"
else
  bad "cache_gc_plan drifted from the golden list: got '${PLAN[*]}'"
fi
# safety: the plan must NEVER contain an installs dir, a bare /cache, or a shims dir
if printf '%s\n' "${PLAN[@]}" | grep -Eq '(^/cache$|/installs(/|$)|/shims(/|$)|/cargo/bin|/go/bin)'; then
  bad "cache_gc_plan includes an installed-toolchain / shims / bare-/cache path — a trim would un-provision tools"
else
  ok "cache_gc_plan never touches installs/, shims/, cargo|go/bin, or bare /cache (installed tools survive a trim)"
fi

# cache_gc_once branches — stub gc_docker so nothing real runs. cache_gc_once calls
# gc_docker for `ps`/`volume inspect` INSIDE $(...) command substitutions, so a shell-var
# recorder would be lost in the subshell; record to a FILE (survives subshells) instead.
RANFILE="$(mktemp)"; trap 'rm -f "$RANFILE"' EXIT
ranfile_reset() { : > "$RANFILE"; }
ran() { cat "$RANFILE"; }
gc_docker() { echo "$*" >>"$RANFILE"; case "$1" in ps) echo "$STUB_PS";; volume) echo "$STUB_MNT";; run) return 0;; *) return 0;; esac; }
STUB_PS="" STUB_MNT="/var/lib/docker/volumes/claude-cache/_data"

# over budget, idle → trims (dry-run prints, runs nothing)
ranfile_reset
out="$(CLAUDE_DISK_GC_DRYRUN=1 CLAUDE_CACHE_SIZE_MIB_OVERRIDE=30000 CLAUDE_CACHE_MAX_MIB=20480 cache_gc_once 2>&1)"
grep -q 'would rm -rf: /cache/mise/downloads' <<<"$out" \
  && ok "cache_gc_once (over budget, idle, dry-run) prints the trim, runs nothing" \
  || bad "cache_gc_once over-budget dry-run did not print the trim plan"

# under budget → no trim
ranfile_reset
out="$(CLAUDE_CACHE_SIZE_MIB_OVERRIDE=100 CLAUDE_CACHE_MAX_MIB=20480 cache_gc_once 2>&1)"
{ grep -q 'no trim needed' <<<"$out" && ! grep -q '^run ' "$RANFILE"; } \
  && ok "cache_gc_once under budget does not trim" \
  || bad "cache_gc_once trimmed while under budget (out='$out')"

# ANY cache-mounting container running → defer even when over budget (never rm mid-install).
# The guard MUST gate on the volume (--filter volume=<vol>), not a worker label, so it also
# covers the claude.managed=1 launch/compose containers that mount the cache but carry no
# claude.worker label (the gate-refuter's MAJOR).
ranfile_reset; STUB_PS="some-managed-container"
out="$(CLAUDE_CACHE_SIZE_MIB_OVERRIDE=30000 CLAUDE_CACHE_MAX_MIB=20480 cache_gc_once 2>&1)"
{ grep -qi 'deferring trim' <<<"$out" && ! grep -q '^run ' "$RANFILE"; } \
  && ok "cache_gc_once defers the trim while a container uses the cache (no rm mid-install)" \
  || bad "cache_gc_once trimmed while a container used the cache (out='$out')"
if grep -Eq 'ps -q --filter volume=claude-cache' "$RANFILE"; then
  ok "the idle guard filters on the CACHE VOLUME (covers workers AND launch/compose containers)"
else
  bad "the idle guard does not filter on --filter volume=<vol> — a launch/compose mid-install could be missed (ran='$(ran)')"
fi
STUB_PS=""

# unknown size (empty mountpoint + no override) → fail-soft, no trim
ranfile_reset; STUB_MNT=""
out="$(unset CLAUDE_CACHE_SIZE_MIB_OVERRIDE; CLAUDE_CACHE_MAX_MIB=20480 cache_gc_once 2>&1)"
{ grep -qi 'size unknown' <<<"$out" && ! grep -q '^run ' "$RANFILE"; } \
  && ok "cache_gc_once with an unmeasurable cache skips the trim (fail-soft)" \
  || bad "cache_gc_once trimmed despite unknown size (out='$out')"
STUB_MNT="/var/lib/docker/volumes/claude-cache/_data"

# cache disabled → immediate no-op (never even queries docker). cache_gc_once reads the
# resolved CACHE_VOLUME (set from CLAUDE_CACHE_VOLUME when _common.sh was sourced), so
# disable it via CACHE_VOLUME here — exactly what a CLAUDE_CACHE_VOLUME=off process yields.
ranfile_reset
out="$(CACHE_VOLUME=off CLAUDE_CACHE_SIZE_MIB_OVERRIDE=30000 cache_gc_once 2>&1)"
[[ ! -s "$RANFILE" ]] \
  && ok "cache_gc_once is a no-op (no docker calls) when the cache is disabled" \
  || bad "cache_gc_once touched docker with the cache disabled (ran='$(ran)')"

# the REAL trim (non-dry-run) uses a throwaway root helper on /bin/sh, mounts ONLY the
# cache volume, and its rm never carries a dangerous flag.
ranfile_reset
CLAUDE_CACHE_SIZE_MIB_OVERRIDE=30000 CLAUDE_CACHE_MAX_MIB=20480 cache_gc_once >/dev/null 2>&1
if grep -q 'run --rm --user 0:0 --entrypoint /bin/sh' "$RANFILE" \
   && grep -q -- '-v claude-cache:/cache' "$RANFILE" \
   && grep -q 'rm -rf /cache/mise/downloads' "$RANFILE"; then
  ok "the real trim runs a root /bin/sh helper mounting only the cache volume, rm-ing the plan"
else
  bad "the real trim helper argv is wrong (ran='$(ran)')"
fi
if grep -Eq 'run .*(--volumes|[^a-z]-a[^a-z]|-v /var|:/var/lib/docker)' "$RANFILE"; then
  bad "the trim helper carries a dangerous flag/mount (--volumes / -a / host docker root)"
else
  ok "the trim helper never uses --volumes / -a / a host-docker-root mount"
fi

# ============================================================================
echo "== claude-launch: mounts the shared cache, honors --no-cache =="
# ============================================================================
LAUNCH="$REPO_ROOT/bin/claude-launch"
bash -n "$LAUNCH" && ok "claude-launch parses (bash -n)" || bad "claude-launch has a syntax error"
grep -Eq 'cache_mount_args' "$LAUNCH" \
  && ok "claude-launch builds the cache mount via cache_mount_args" \
  || bad "claude-launch does not call cache_mount_args"
grep -Eq '"\$\{CACHE_MOUNT_ARGS\[@\]\}"' "$LAUNCH" \
  && ok "claude-launch passes CACHE_MOUNT_ARGS into docker run" \
  || bad "CACHE_MOUNT_ARGS is not passed into docker run"
grep -Eq -- '--no-cache\)' "$LAUNCH" && grep -Eq -- '--cache\)' "$LAUNCH" \
  && ok "claude-launch accepts --cache <vol> and --no-cache" \
  || bad "claude-launch is missing the --cache / --no-cache flags"

# ============================================================================
echo "== claude-compose-gen: emits the shared cache, honors --no-cache =="
# ============================================================================
GEN="$REPO_ROOT/bin/claude-compose-gen"
OUT="$(mktemp -u)"; trap 'rm -f "$OUT" "$RANFILE"' EXIT
run_gen() { "$GEN" --out "$OUT" "$@" acme/repo-a acme/repo-b >/dev/null 2>&1; }

if run_gen; then
  { grep -q 'claude-cache:/cache' "$OUT" && grep -Eq '^  claude-cache:' "$OUT" && grep -q 'name: claude-cache' "$OUT"; } \
    && ok "compose-gen default: each service mounts claude-cache:/cache + the top-level volume is declared" \
    || bad "compose-gen default did not emit the shared cache mount + volume"
else
  bad "compose-gen failed to generate a default stack"
fi

if run_gen --no-cache; then
  grep -q 'claude-cache' "$OUT" \
    && bad "compose-gen --no-cache still emitted a cache volume/mount" \
    || ok "compose-gen --no-cache emits no cache mount or volume (per-container installs)"
else
  bad "compose-gen --no-cache failed to generate"
fi

if run_gen --cache teamcache; then
  { grep -q 'claude-cache:/cache' "$OUT" && grep -q 'name: teamcache' "$OUT"; } \
    && ok "compose-gen --cache <name> remaps the top-level volume name, keeps the /cache mount" \
    || bad "compose-gen --cache <name> did not remap the volume name"
else
  bad "compose-gen --cache <name> failed to generate"
fi

echo
echo "cache-unit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
