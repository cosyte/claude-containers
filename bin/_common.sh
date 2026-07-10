#!/usr/bin/env bash
# Shared library for the claude-* launcher scripts. Sourced, not executed.
set -euo pipefail

# --- Locate the project root (dir containing the Dockerfile) -----------------
_src="${BASH_SOURCE[0]}"
while [[ -h "$_src" ]]; do _src="$(readlink "$_src")"; done
CLAUDE_DOCKER_ROOT="$(cd "$(dirname "$_src")/.." && pwd)"
export CLAUDE_DOCKER_ROOT

# --- Load env: base .env, then an optional scenario override layer -----------
# Precedence (weakest first): ambient env < base .env < CLAUDE_ENV_FILE < CLI.
# (`set -a; source` means a bare VAR= in .env overrides the ambient env, so the
# old "real env still wins" comment was inaccurate — ambient is the weakest.)
# The scenario override is loaded HERE, before the defaults/derivations below,
# so a scenario that overrides e.g. CLAUDE_MEM_LIMIT also drives the derived
# CLAUDE_MEM_RESERVATION. die() isn't defined yet, so this fails closed inline.
if [[ -f "$CLAUDE_DOCKER_ROOT/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$CLAUDE_DOCKER_ROOT/.env"
    set +a
fi
# CLAUDE_ENV_FILE points at a per-scenario/per-stack env file (set by
# claude-compose-gen's --scenario/--env-file). Values here win over the base
# .env. A set-but-missing path is a hard error (fail closed) — an explicitly
# named env file must never be silently ignored.
if [[ -n "${CLAUDE_ENV_FILE:-}" ]]; then
    [[ -f "$CLAUDE_ENV_FILE" ]] || {
        echo "claude: CLAUDE_ENV_FILE='$CLAUDE_ENV_FILE' does not exist — refusing (fail closed)" >&2
        exit 1
    }
    set -a
    # shellcheck disable=SC1091
    source "$CLAUDE_ENV_FILE"
    set +a
fi

# --- Defaults ----------------------------------------------------------------
CLAUDE_IMAGE="${CLAUDE_IMAGE:-claude-code-box:latest}"
AUTH_VOLUME="${AUTH_VOLUME:-claude-auth}"
SSHKEYS_VOLUME="${SSHKEYS_VOLUME:-claude-sshkeys}"
SSH_PORT_RANGE_START="${SSH_PORT_RANGE_START:-2200}"
SSH_PORT_RANGE_END="${SSH_PORT_RANGE_END:-2299}"
GIT_SSH_KEY="${GIT_SSH_KEY:-$HOME/.ssh/claude-git-key}"
SSH_AUTHORIZED_KEYS="${SSH_AUTHORIZED_KEYS:-$HOME/.ssh/authorized_keys}"
CLAUDE_SSH_BIND="${CLAUDE_SSH_BIND:-}"   # empty = publish SSH on all interfaces
CLAUDE_SHM_SIZE="${CLAUDE_SHM_SIZE:-2g}"
CLAUDE_CPU_LIMIT="${CLAUDE_CPU_LIMIT:-2}"
CLAUDE_MEM_LIMIT="${CLAUDE_MEM_LIMIT:-4g}"
CLAUDE_STOP_TIMEOUT="${CLAUDE_STOP_TIMEOUT:-20}"
# Escape hardening: drop ALL Linux capabilities and re-add only the minimal set
# the container needs (sshd binding :22 + dropping privileges to the claude user,
# plus the entrypoint's chown/setup). This removes the Docker defaults NET_RAW,
# MKNOD, and SETFCAP — the ones a compromised/ injected agent would reach for.
# CLAUDE_HARDEN_CAPS=0 falls back to Docker's default cap set if a workload needs
# more. no-new-privileges is applied regardless.
CLAUDE_HARDEN_CAPS="${CLAUDE_HARDEN_CAPS:-1}"
CLAUDE_MIN_CAPS="${CLAUDE_MIN_CAPS:-CHOWN DAC_OVERRIDE FOWNER FSETID KILL SETGID SETUID SETPCAP NET_BIND_SERVICE SYS_CHROOT AUDIT_WRITE}"

# --- Output helpers ----------------------------------------------------------
if [[ -t 1 ]]; then
    C_B="\033[1m"; C_G="\033[32m"; C_Y="\033[33m"; C_R="\033[31m"; C_0="\033[0m"
else
    C_B=""; C_G=""; C_Y=""; C_R=""; C_0=""
fi
info()  { echo -e "${C_B}==>${C_0} $*"; }
ok()    { echo -e "${C_G}==>${C_0} $*"; }
warn()  { echo -e "${C_Y}==> warning:${C_0} $*" >&2; }
err()   { echo -e "${C_R}==> error:${C_0} $*" >&2; }
die()   { err "$*"; exit 1; }

# --- Helpers -----------------------------------------------------------------
need_docker() {
    command -v docker >/dev/null 2>&1 || die "docker not found in PATH"
    docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon"
}

# Docker-run hardening flags (no-new-privileges + minimal capabilities), as a
# space-separated string the launcher reads into an array. Used by claude-launch;
# claude-compose-gen emits the equivalent YAML.
harden_run_args() {
    local out="--security-opt no-new-privileges"
    if [[ "$CLAUDE_HARDEN_CAPS" =~ ^(1|true|yes|on)$ ]]; then
        out+=" --cap-drop ALL"
        local c; for c in $CLAUDE_MIN_CAPS; do out+=" --cap-add $c"; done
    fi
    # The egress firewall needs NET_ADMIN at boot (used by root only; the agent
    # stays unprivileged and so cannot alter the rules).
    [[ "${CLAUDE_EGRESS_LOCKDOWN:-0}" =~ ^(1|true|yes|on)$ ]] && out+=" --cap-add NET_ADMIN"
    echo "$out"
}

# Warn (don't block) if the host's runC is vulnerable to the Nov-2025 container-
# escape CVEs (CVE-2025-31133 / 52565 / 52881), fixed in runC 1.2.8 / 1.3.3 /
# 1.4.0-rc.3. A weaponized in-container agent could escape an unpatched runtime,
# defeating every other control here — so this is the highest-leverage check.
preflight_runc() {
    local rv base M m p
    rv="$(runc --version 2>/dev/null | awk '/^runc version/{print $3; exit}')"
    [[ -z "$rv" ]] && rv="$(docker info 2>/dev/null | sed -n 's/.*[Rr]unc version[: ]*v\?\([0-9][^ ,]*\).*/\1/p' | head -1)"
    if [[ -z "$rv" ]]; then
        warn "could not determine host runC version — ensure it is >= 1.2.8 / 1.3.3 (CVE-2025-31133/52565/52881 escapes)"
        return 0
    fi
    base="${rv#v}"; base="${base%%-*}"
    IFS=. read -r M m p <<<"$base"; M=${M:-0} m=${m:-0} p=${p:-0}
    local safe=0
    if   (( M > 1 )); then safe=1
    elif (( M == 1 )); then
        if   (( m > 3 )); then safe=1
        elif (( m == 3 && p >= 3 )); then safe=1
        elif (( m == 2 && p >= 8 )); then safe=1
        fi
    fi
    # 1.4.0 release candidates: only rc.3+ carry the fix.
    if [[ "$base" == "1.4.0" && "$rv" == *-rc.* ]]; then
        local rc="${rv##*-rc.}"; [[ "$rc" =~ ^[0-9]+$ ]] && (( rc < 3 )) && safe=0
    fi
    if (( safe == 0 )); then
        warn "host runC $rv is vulnerable to the Nov-2025 container-escape CVEs (CVE-2025-31133/52565/52881)."
        warn "  Patch runC to >= 1.2.8 (1.2.x) / >= 1.3.3 (1.3.x) / >= 1.4.0-rc.3, then restart Docker."
        warn "  Until then, container isolation can be escaped by a weaponized agent — treat each container as fully trusted."
    fi
}

# version_ge A B — true iff dotted-numeric version A >= B (first three components).
# Both must be numeric triples (missing parts default to 0); anything non-numeric is an
# ERROR (return 2) so security callers can fail CLOSED instead of comparing garbage as 0.
# Base-10 forced (10#) so a leading zero can't trip octal arithmetic.
version_ge() {
    local aM am ap bM bm bp
    IFS=. read -r aM am ap <<<"$1"; aM=${aM:-0} am=${am:-0} ap=${ap:-0}
    IFS=. read -r bM bm bp <<<"$2"; bM=${bM:-0} bm=${bm:-0} bp=${bp:-0}
    [[ "$aM$am$ap$bM$bm$bp" =~ ^[0-9]+$ ]] || return 2
    (( 10#$aM > 10#$bM || (10#$aM == 10#$bM && (10#$am > 10#$bm || (10#$am == 10#$bm && 10#$ap >= 10#$bp))) ))
}

# Sysbox version floor for the nested-worker substrate (CC-1, umbrella ADR 0011). Nested
# workers run under sysbox-runc instead of runc, so the Nov-2025 runc escape-CVE floor
# (CVE-2025-31133 / 52565 / 52881) generalizes to "a Sysbox release that ports those
# patches" — v0.7.0 (2026-06-02) is the first. Unlike preflight_runc above (warn-only,
# because the flat K=1 launch path predates nesting and must not change behavior), this
# check is a REFUSAL: nothing may stand up a nested worker on a pre-patch runtime.
#
# SYSBOX_CVE_FLOOR is IMMOVABLE (readonly, assigned after the .env auto-source above so
# no .env/ambient value can redefine it). SYSBOX_MIN_VERSION may RAISE the operative bar
# fleet-wide; preflight_sysbox dies if it is set below the CVE floor — the same
# neutralize-the-gate vector as the test seams, closed the same way.
if ! readonly SYSBOX_CVE_FLOOR=0.7.0 2>/dev/null; then
    # Already readonly (this file sourced twice in one shell): value must be OURS.
    [[ "${SYSBOX_CVE_FLOOR:-}" == "0.7.0" ]] || die "SYSBOX_CVE_FLOOR is '$SYSBOX_CVE_FLOOR' (expected 0.7.0) — refusing"
fi
SYSBOX_MIN_VERSION="${SYSBOX_MIN_VERSION:-$SYSBOX_CVE_FLOOR}"

# sysbox_version_check <raw-version-string> — the ONE floor compare, shared by
# preflight_sysbox (host binary path) and bin/claude-worker-broker (in-container
# attestation path, CC-2) so the two can never drift. Normalizes the string
# (v-prefix, +build-metadata, pre-release suffix), fails CLOSED on garbage on either
# side, refuses below the operative floor, and refuses a pre-release of exactly the
# floor. Also re-asserts floor integrity (raise-only) so every caller binds. On
# success exports SYSBOX_VERSION (the normalized version) for callers to report.
sysbox_version_check() {
    local sv="$1"
    # The operative floor may only sit AT or ABOVE the immovable CVE floor — a lowered
    # (or garbage) SYSBOX_MIN_VERSION from env/.env dies here, fail closed. Checked
    # inside the function so an in-process reassignment after sourcing binds too.
    local floor_ok=0; version_ge "$SYSBOX_MIN_VERSION" "$SYSBOX_CVE_FLOOR" || floor_ok=$?
    (( floor_ok == 0 )) || die "SYSBOX_MIN_VERSION '$SYSBOX_MIN_VERSION' is below (or unparseable against) the immovable CVE floor $SYSBOX_CVE_FLOOR (CVE-2025-31133/52565/52881) — the floor may be raised, never lowered"

    sv="${sv#v}"
    sv="${sv%%+*}"   # build metadata (+…) carries no release semantics — off first
    local pre=""; [[ "$sv" == *-* ]] && pre="${sv#*-}"
    sv="${sv%%-*}"
    # Fail CLOSED on garbage on EITHER side: an unparseable version or floor must refuse,
    # never collapse to 0 and wave a pre-patch runtime through. (|| capture: a bare call
    # would trip callers' errexit before the case could name the reason.)
    local vge=0; version_ge "$sv" "$SYSBOX_MIN_VERSION" || vge=$?
    case $vge in
        0) ;;
        1) die "Sysbox $sv predates the Nov-2025 escape-CVE patches (CVE-2025-31133/52565/52881, ported in $SYSBOX_MIN_VERSION) — refusing to use it for nested workers" ;;
        *) die "unparseable Sysbox version '$sv' or floor '$SYSBOX_MIN_VERSION' — refusing (fail closed)" ;;
    esac
    # A pre-release of exactly the floor (e.g. 0.7.0-rc.1) cannot be proven to carry the
    # patches — fail closed. Reachable on the real path: callers' parses keep suffixes.
    if [[ -n "$pre" ]]; then
        local fM fm fp
        IFS=. read -r fM fm fp <<<"$SYSBOX_MIN_VERSION"
        if [[ "$sv" == "${fM:-0}.${fm:-0}.${fp:-0}" ]]; then
            die "Sysbox $sv-$pre is a pre-release of the floor $SYSBOX_MIN_VERSION — cannot prove it carries the CVE patches, refusing"
        fi
    fi
    SYSBOX_VERSION="$sv${pre:+-$pre}"
    export SYSBOX_VERSION
}

# Die unless a CVE-patched Sysbox is installed AND registered with Docker. On success,
# exports SYSBOX_VERSION (the parsed full version) for callers to report.
# Test seams — UNIT TESTS ONLY, loudly warned when active (bin/claude-sysbox-verify
# unsets both up front so an ambient/leftover value can never neutralize the real gate):
# CLAUDE_SYSBOX_FAKE_VERSION injects a version string (skips the binary);
# CLAUDE_SYSBOX_SKIP_DOCKER=1 skips the Docker daemon + runtime-registration check.
preflight_sysbox() {
    local sv=""
    if [[ -n "${CLAUDE_SYSBOX_FAKE_VERSION:-}" ]]; then
        warn "TEST SEAM ACTIVE: CLAUDE_SYSBOX_FAKE_VERSION='${CLAUDE_SYSBOX_FAKE_VERSION}' — the real sysbox-runc is NOT being checked"
        sv="$CLAUDE_SYSBOX_FAKE_VERSION"
    else
        command -v sysbox-runc >/dev/null 2>&1 \
            || die "sysbox-runc not found — install Sysbox >= $SYSBOX_MIN_VERSION first (docs/substrate.md)"
        # Robust to both output shapes ("sysbox-runc version X.Y.Z" and the multi-line
        # "version: X.Y.Z" form). Keep any pre-release/build suffix — the floor logic
        # in sysbox_version_check must SEE a suffix to refuse it. `|| true`: a no-match
        # grep must reach the die below with its message, not be eaten by errexit.
        sv="$(sysbox-runc --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z.+-]*' | head -1 || true)"
        [[ -n "$sv" ]] || die "could not parse a version out of 'sysbox-runc --version'"
    fi
    sysbox_version_check "$sv"
    if [[ "${CLAUDE_SYSBOX_SKIP_DOCKER:-0}" != 1 ]]; then
        need_docker
        docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"sysbox-runc"' \
            || die "Docker has no 'sysbox-runc' runtime registered — see docs/substrate.md (daemon.json + SIGHUP reload)"
    else
        warn "TEST SEAM ACTIVE: CLAUDE_SYSBOX_SKIP_DOCKER=1 — Docker runtime registration is NOT being checked"
    fi
    # SYSBOX_VERSION was normalized + exported by sysbox_version_check above.
}

# --- K-aware resource sizing (CC-3) -------------------------------------------
# THE per-worker resource profile — the single definition the broker template,
# the controller-envelope math, and the verify scripts all read (roadmap §5
# starting numbers; re-measured under CC-7/PAR-6.1 before any K-ramp). .env /
# environment overrides win (sourced above), but the K VALUE itself is never
# defined here — it comes from the umbrella operations/parallel.config.json via
# resolve_parallel_k below (one source of truth, never forked into this repo).
CLAUDE_WORKER_MEM="${CLAUDE_WORKER_MEM:-4g}"
# CLAUDE_WORKER_MEM_RESERVATION (the soft floor) is DERIVED from the worker mem
# below (once mem_reservation_for is defined) when unset — 75% of the effective
# mem, mirroring the flat-session CLAUDE_MEM_RESERVATION path. A fixed default
# (the old `3g`) would INVERT (reservation > limit) the moment an operator lowers
# CLAUDE_WORKER_MEM below it (e.g. a 2g worker profile), which Docker rejects.
CLAUDE_WORKER_CPUS="${CLAUDE_WORKER_CPUS:-2}"
CLAUDE_WORKER_PIDS="${CLAUDE_WORKER_PIDS:-2048}"
CLAUDE_WORKER_SHM="${CLAUDE_WORKER_SHM:-2g}"
# Flat-session fork-bomb guard (claude-launch / compose services). Same default
# as the worker profile — one session ≈ one worker's workload.
CLAUDE_PIDS_LIMIT="${CLAUDE_PIDS_LIMIT:-2048}"
# Controller overheads: what the controller itself (inner dockerd + broker +
# slack) needs ON TOP of Σ(K workers) — roadmap §5 table (~1 CPU / ~2 GB).
CLAUDE_CTRL_CPU_OVERHEAD="${CLAUDE_CTRL_CPU_OVERHEAD:-1}"
CLAUDE_CTRL_MEM_OVERHEAD_MIB="${CLAUDE_CTRL_MEM_OVERHEAD_MIB:-2048}"
CLAUDE_CTRL_PIDS_OVERHEAD="${CLAUDE_CTRL_PIDS_OVERHEAD:-1024}"

# size_to_mib <docker-size> — print a docker size string (4g / 3072m / 512k /
# plain bytes) as integer MiB, rounded UP so a requirement is never
# under-counted. Fails (return 2) on anything unparseable — sizing is a safety
# calculation, so garbage must refuse, never read as 0.
size_to_mib() {
    local n u
    [[ "$1" =~ ^([0-9]+)([bkmgBKMG]?)$ ]] || return 2
    n="${BASH_REMATCH[1]}"; u="$(tr '[:upper:]' '[:lower:]' <<<"${BASH_REMATCH[2]}")"
    case "$u" in
        g)   echo $(( n * 1024 )) ;;
        m)   echo "$n" ;;
        k)   echo $(( (n + 1023) / 1024 )) ;;
        b|"") echo $(( (n + 1048575) / 1048576 )) ;;
    esac
}

# mem_reservation_for <limit> — the derived soft floor for a hard memory limit:
# 75% (4g → 3072m, the same ratio as the worker profile). Keeps a per-repo /
# per-host limit override from ever inverting reservation > limit, which the
# daemon rejects. Fails (return 2) on an unparseable limit.
mem_reservation_for() {
    local mib; mib="$(size_to_mib "$1")" || return 2
    echo "$(( mib * 3 / 4 ))m"
}

# Flat-session soft memory floor: an explicit CLAUDE_MEM_RESERVATION wins; else
# derive 75% of the (possibly .env-overridden) CLAUDE_MEM_LIMIT.
if [[ -z "${CLAUDE_MEM_RESERVATION:-}" ]]; then
    CLAUDE_MEM_RESERVATION="$(mem_reservation_for "$CLAUDE_MEM_LIMIT")" \
        || die "unparseable CLAUDE_MEM_LIMIT '$CLAUDE_MEM_LIMIT' — cannot derive a memory reservation (fail closed)"
fi

# Per-worker soft memory floor (CC-4-RESIDUAL): same rule as the flat path — an
# explicit CLAUDE_WORKER_MEM_RESERVATION wins; else derive 75% of the worker mem
# so it always scales with (and never inverts above) the hard --memory limit,
# even when an operator lowers CLAUDE_WORKER_MEM below the old fixed 3g default.
if [[ -z "${CLAUDE_WORKER_MEM_RESERVATION:-}" ]]; then
    CLAUDE_WORKER_MEM_RESERVATION="$(mem_reservation_for "$CLAUDE_WORKER_MEM")" \
        || die "unparseable CLAUDE_WORKER_MEM '$CLAUDE_WORKER_MEM' — cannot derive a worker memory reservation (fail closed)"
fi

# resolve_parallel_k — print K, the fleet parallelism, read from the umbrella's
# operations/parallel.config.json (the ONE source of truth — this repo never
# defines its own K). Lookup order:
#   1. $CLAUDE_PARALLEL_CONFIG — an explicit path; missing or unparseable DIES
#      (an explicitly-named config is never silently ignored);
#   2. the umbrella-submodule layout ($CLAUDE_DOCKER_ROOT/../operations/…);
#   3. the in-container umbrella workspace (/workspace/operations/…).
# No file found → the documented umbrella default K=2, with a warning. A file
# that IS found but yields garbage DIES (fail closed): a garbage K silently
# becoming 2 could under-size a controller that then overcommits.
resolve_parallel_k() {
    local cfg="" c k=""
    if [[ -n "${CLAUDE_PARALLEL_CONFIG:-}" ]]; then
        cfg="$CLAUDE_PARALLEL_CONFIG"
        [[ -f "$cfg" ]] || die "CLAUDE_PARALLEL_CONFIG='$cfg' does not exist — refusing to guess K"
    else
        for c in "$CLAUDE_DOCKER_ROOT/../operations/parallel.config.json" \
                 /workspace/operations/parallel.config.json; do
            [[ -f "$c" ]] && { cfg="$c"; break; }
        done
    fi
    if [[ -z "$cfg" ]]; then
        warn "no umbrella operations/parallel.config.json found — using the documented umbrella default K=2"
        echo 2; return 0
    fi
    if command -v jq >/dev/null 2>&1; then
        k="$(jq -er '.K' "$cfg" 2>/dev/null)" || k=""
    else
        # No jq: capture the WHOLE value token (up to , } or whitespace) so a
        # fractional/garbage K reaches the integer validation below and refuses
        # — never truncates to its integer part.
        k="$(grep -oE '"K"[[:space:]]*:[[:space:]]*[^,}[:space:]]+' "$cfg" 2>/dev/null | head -1 | sed 's/^"K"[[:space:]]*:[[:space:]]*//')" || k=""
    fi
    [[ "$k" =~ ^[0-9]+$ ]] && (( k >= 1 && k <= 16 )) \
        || die "could not parse a sane K from $cfg (got '${k:-nothing}') — refusing (fail closed)"
    echo "$k"
}

# controller_envelope <K> — the Sysbox controller envelope for K nested workers.
# The parent cgroup caps the SUM of its children (workers + inner dockerd +
# broker), so the controller must carry Σ(K · worker profile) + overhead.
# Exports CTRL_CPUS, CTRL_MEM_MIB, CTRL_MEM_RESERVATION_MIB, CTRL_PIDS.
# Worker shm is tmpfs charged to each worker's own memory cgroup, so it rides
# inside the per-worker --memory cap — no separate controller shm term.
controller_envelope() {
    local k="$1" wm wr
    [[ "$k" =~ ^[0-9]+$ ]] && (( k >= 1 )) || die "controller_envelope: K must be a positive integer (got '$k')"
    wm="$(size_to_mib "$CLAUDE_WORKER_MEM")" \
        || die "unparseable CLAUDE_WORKER_MEM '$CLAUDE_WORKER_MEM' — refusing (fail closed)"
    wr="$(size_to_mib "$CLAUDE_WORKER_MEM_RESERVATION")" \
        || die "unparseable CLAUDE_WORKER_MEM_RESERVATION '$CLAUDE_WORKER_MEM_RESERVATION' — refusing (fail closed)"
    [[ "$CLAUDE_WORKER_PIDS" =~ ^[0-9]+$ ]] \
        || die "CLAUDE_WORKER_PIDS '$CLAUDE_WORKER_PIDS' is not an integer — refusing (fail closed)"
    [[ "$CLAUDE_WORKER_CPUS" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
        || die "CLAUDE_WORKER_CPUS '$CLAUDE_WORKER_CPUS' is not a number — refusing (fail closed)"
    [[ "$CLAUDE_CTRL_MEM_OVERHEAD_MIB" =~ ^[0-9]+$ && "$CLAUDE_CTRL_PIDS_OVERHEAD" =~ ^[0-9]+$ \
       && "$CLAUDE_CTRL_CPU_OVERHEAD" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
        || die "controller overhead settings are not numeric — refusing (fail closed)"
    CTRL_MEM_MIB=$(( k * wm + CLAUDE_CTRL_MEM_OVERHEAD_MIB ))
    CTRL_MEM_RESERVATION_MIB=$(( k * wr + CLAUDE_CTRL_MEM_OVERHEAD_MIB ))
    CTRL_PIDS=$(( k * CLAUDE_WORKER_PIDS + CLAUDE_CTRL_PIDS_OVERHEAD ))
    CTRL_CPUS="$(awk -v k="$k" -v w="$CLAUDE_WORKER_CPUS" -v o="$CLAUDE_CTRL_CPU_OVERHEAD" \
        'BEGIN{ c = k*w + o; if (c == int(c)) printf "%d", c; else printf "%.2f", c }')"
    export CTRL_CPUS CTRL_MEM_MIB CTRL_MEM_RESERVATION_MIB CTRL_PIDS
}

# --- Disk-space safety (CC-5) --------------------------------------------------
# disk_free_mib <path> — print the free space, in integer MiB, on the
# filesystem holding <path>. Backs both the broker's per-launch disk-floor
# refusal (broker_check_disk) and bin/claude-disk-gc/-verify.
#
# `df -P -B1M <path>` gives POSIX-format, 1-MiB-block output regardless of
# locale/column-width quirks; the "Available" column is the 4th field of the
# second (data) line. Parsed robustly — an unreadable/missing path, a `df`
# that errors, or non-numeric output all FAIL CLOSED (return 1, print
# nothing): a blind disk check must never be misread as "plenty of free
# space", which is the one failure mode that could wedge the host by letting
# a launch through.
#
# Test seam — UNIT TESTS ONLY, loudly warned when active:
#   CLAUDE_DISK_FREE_MIB_OVERRIDE   forces the returned value (skips `df`)
disk_free_mib() {
    local path="$1" line avail
    if [[ -n "${CLAUDE_DISK_FREE_MIB_OVERRIDE:-}" ]]; then
        warn "TEST SEAM ACTIVE: CLAUDE_DISK_FREE_MIB_OVERRIDE='${CLAUDE_DISK_FREE_MIB_OVERRIDE}' — the real free disk space is NOT being checked"
        [[ "$CLAUDE_DISK_FREE_MIB_OVERRIDE" =~ ^[0-9]+$ ]] || return 1
        echo "$CLAUDE_DISK_FREE_MIB_OVERRIDE"
        return 0
    fi
    [[ -n "$path" ]] || return 1
    # -P: POSIX one-line-per-filesystem output (no wrapping); -B1M: 1-MiB
    # blocks so the "Available" column is already in MiB. `|| true`: a df
    # error must fall through to the parse check below and fail closed there,
    # not blow up this function under the caller's set -e.
    line="$(df -P -B1M "$path" 2>/dev/null | tail -n +2 || true)"
    [[ -n "$line" ]] || return 1
    # Field 4 = Available. awk (not cut) so extra/odd whitespace from a long
    # filesystem-name column (which wraps df's normally-fixed columns even
    # under -P) can't shift the field index.
    avail="$(awk 'NR==1{print $4}' <<<"$line")"
    [[ "$avail" =~ ^[0-9]+$ ]] || return 1
    echo "$avail"
    return 0
}

# Container/volume-safe name: lowercase, only [a-z0-9._-].
sanitize() {
    local n
    n="$(echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's#[^a-z0-9._-]#-#g')"
    n="${n##-}"; n="${n%%-}"
    [[ -n "$n" ]] || die "project name '$1' sanitizes to empty"
    echo "$n"
}

cname()      { echo "claude-$1"; }
ws_volume()  { echo "claude-ws-$1"; }
cfg_volume() { echo "claude-config-$1"; }

container_state() {  # prints: running | stopped | absent
    local c="$1" s
    s="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || true)"
    case "$s" in
        running) echo running ;;
        "")      echo absent ;;
        *)       echo stopped ;;
    esac
}

ensure_image() {
    if ! docker image inspect "$CLAUDE_IMAGE" >/dev/null 2>&1; then
        info "Image $CLAUDE_IMAGE not found; building (one-time)…"
        docker build -t "$CLAUDE_IMAGE" "$CLAUDE_DOCKER_ROOT"
    fi
}

host_port_free() {  # 1 if free, 0 if taken
    local p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltn "( sport = :$p )" 2>/dev/null | grep -q ":$p " && return 1
    fi
    (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null && { exec 3>&- 3<&-; return 1; }
    return 0
}

ports_used_by_claude() {
    # Test seam — UNIT TESTS ONLY: CLAUDE_PORTS_USED_OVERRIDE forces the list
    # (space/newline-separated; may be empty = "none in use") so cross-stack
    # port reservation is testable without a live docker. Triggers when SET,
    # even to empty; inert (real docker) when unset.
    if [[ -n "${CLAUDE_PORTS_USED_OVERRIDE+set}" ]]; then
        printf '%s\n' ${CLAUDE_PORTS_USED_OVERRIDE:-} | grep -E '^[0-9]+$' || true
        return 0
    fi
    docker ps -a --filter 'label=claude.managed=1' \
        --format '{{.Label "claude.ssh_port"}}' 2>/dev/null | grep -E '^[0-9]+$' || true
}

alloc_port() {
    local used p
    used="$(ports_used_by_claude)"
    for ((p=SSH_PORT_RANGE_START; p<=SSH_PORT_RANGE_END; p++)); do
        grep -qx "$p" <<<"$used" && continue
        host_port_free "$p" && { echo "$p"; return 0; }
    done
    die "no free SSH port in range ${SSH_PORT_RANGE_START}-${SSH_PORT_RANGE_END}"
}

container_ssh_port() {
    docker inspect -f '{{ index .Config.Labels "claude.ssh_port" }}' "$1" 2>/dev/null
}

print_connect() {
    local proj="$1" port="$2"
    local host="${CLAUDE_SSH_HOST:-$(hostname -f 2>/dev/null || hostname)}"
    echo
    ok "Container '$(cname "$proj")' is up."
    echo
    echo "  SSH into the live tmux session:"
    echo -e "      ${C_B}ssh -p ${port} claude@${host}${C_0}"
    echo
    echo "  ...or attach locally on this host (no SSH key needed):"
    echo -e "      ${C_B}claude-attach ${proj}${C_0}"
    echo
    echo "  Claude mobile app: open the Code tab and look for the session named"
    echo -e "      ${C_B}${proj}${C_0}   (green dot = online)"
    echo
}
