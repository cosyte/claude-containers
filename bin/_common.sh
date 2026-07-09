#!/usr/bin/env bash
# Shared library for the claude-* launcher scripts. Sourced, not executed.
set -euo pipefail

# --- Locate the project root (dir containing the Dockerfile) -----------------
_src="${BASH_SOURCE[0]}"
while [[ -h "$_src" ]]; do _src="$(readlink "$_src")"; done
CLAUDE_DOCKER_ROOT="$(cd "$(dirname "$_src")/.." && pwd)"
export CLAUDE_DOCKER_ROOT

# --- Load .env defaults (real env still wins) --------------------------------
if [[ -f "$CLAUDE_DOCKER_ROOT/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$CLAUDE_DOCKER_ROOT/.env"
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
# Leaf (single-session) launch resource guards — OPT-IN, default empty so the flat
# K=1 autopilot launch stays byte-for-byte unchanged (roadmap §6 non-regression).
# Set to add a soft memory floor / a fork-bomb guard to session containers too; the
# WORKER profile (above) always carries these, the leaf path only when asked.
CLAUDE_MEM_RESERVATION="${CLAUDE_MEM_RESERVATION:-}"   # e.g. 3g — omitted when empty
CLAUDE_PIDS_LIMIT="${CLAUDE_PIDS_LIMIT:-}"             # e.g. 2048 — omitted when empty
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

# Optional leaf-launch resource guards as a space-separated string (empty when
# neither is set → the flat launch is byte-identical). claude-launch reads this
# into an array; claude-compose-gen emits the YAML equivalent. Values are simple
# tokens (a size / an integer), so space-joining is safe.
leaf_resource_args() {
    local out=""
    [[ -n "${CLAUDE_MEM_RESERVATION:-}" ]] && out+=" --memory-reservation $CLAUDE_MEM_RESERVATION"
    [[ -n "${CLAUDE_PIDS_LIMIT:-}" ]]      && out+=" --pids-limit $CLAUDE_PIDS_LIMIT"
    echo "${out# }"
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

# =============================================================================
# K-aware resource sizing + single-source config (CC-3, roadmap §5)
# =============================================================================
# The parallel engine runs up to K worker containers under one Sysbox controller.
# Every sizing decision is derived from TWO inputs and no more: the number K and
# one per-worker resource profile. So the controller/host envelope is computed,
# never guessed, and never double-sourced.
#
# K is single-sourced from the UMBRELLA operations/parallel.config.json (the
# founder-set value — K=2 there today). This repo deliberately keeps NO K of its
# own: a forked copy would drift from the umbrella control plane the moment the
# founder ramps K (PAR-7.1). resolve_k walks up from the submodule to that file;
# absent it (this repo used standalone, no parallel engine) K collapses to 1 —
# today's single-container autopilot, unchanged.

# resolve_parallel_config — echo the umbrella parallel.config.json path, else
# return 1. COSYTE_PARALLEL_CONFIG overrides outright; otherwise walk up from the
# submodule root (this repo is a submodule of the umbrella; the file sits at the
# umbrella's operations/parallel.config.json, above the submodule dir).
resolve_parallel_config() {
    if [[ -n "${COSYTE_PARALLEL_CONFIG:-}" ]]; then
        [[ -f "$COSYTE_PARALLEL_CONFIG" ]] && { echo "$COSYTE_PARALLEL_CONFIG"; return 0; }
        return 1
    fi
    local d="$CLAUDE_DOCKER_ROOT"
    while [[ -n "$d" && "$d" != "/" ]]; do
        if [[ -f "$d/operations/parallel.config.json" ]]; then
            echo "$d/operations/parallel.config.json"; return 0
        fi
        d="$(dirname "$d")"
    done
    return 1
}

# resolve_k — echo the single-source worker count K (integer >= 1). Priority:
#   1. CLAUDE_K explicit override (tests / a manual run) — validated, never < 1;
#   2. the umbrella parallel.config.json .K (the founder-set source of truth);
#   3. no umbrella config found → 1 (standalone: no parallel engine, single box).
# Fails CLOSED: a config that IS present but carries a non-numeric / absent K dies
# rather than defaulting, so a corrupt control-plane value can never silently size
# a controller wrong. Uses jq when present; a suffix-free sed fallback otherwise.
resolve_k() {
    local k="" cfg
    if [[ -n "${CLAUDE_K:-}" ]]; then
        k="$CLAUDE_K"
    elif cfg="$(resolve_parallel_config)"; then
        if command -v jq >/dev/null 2>&1; then
            k="$(jq -r '.K // empty' "$cfg" 2>/dev/null || true)"
        else
            # Capture the WHOLE numeric token (incl. any '.') so a float like 2.5
            # reaches the ^[0-9]+$ validator below and is REFUSED — matching the jq
            # path — instead of being silently truncated to '2'.
            k="$(sed -n 's/.*"K"[[:space:]]*:[[:space:]]*\([0-9][0-9.]*\).*/\1/p' "$cfg" | head -1)"
        fi
        [[ -n "$k" ]] || die "parallel.config.json ($cfg) has no numeric K — refusing to guess (fail closed)"
    else
        k=1
    fi
    [[ "$k" =~ ^[0-9]+$ ]] || die "K value '$k' is not a non-negative integer — refusing (fail closed)"
    (( k >= 1 )) || die "K value '$k' is < 1 — the engine needs at least one worker"
    echo "$k"
}

# --- per-worker resource profile (the single source) -------------------------
# A full /work-on worker ~= today's single-container leaf envelope (roadmap §5
# starting numbers). The broker (bin/claude-worker-broker) AND the controller
# sizing below both read THESE names — the profile is defined once, here.
# Override per-fleet via env/.env; re-measured before any K-ramp (PAR-6.1/CC-7).
CLAUDE_WORKER_CPUS="${CLAUDE_WORKER_CPUS:-2}"
CLAUDE_WORKER_MEM="${CLAUDE_WORKER_MEM:-4g}"
CLAUDE_WORKER_MEM_RESERVATION="${CLAUDE_WORKER_MEM_RESERVATION:-3g}"
CLAUDE_WORKER_PIDS="${CLAUDE_WORKER_PIDS:-2048}"
CLAUDE_WORKER_SHM="${CLAUDE_WORKER_SHM:-2g}"
# Controller overhead ON TOP of Σ(K workers): the lead agent session + the broker
# + the inner dockerd + headroom (roadmap §5: ~1 CPU / ~2g).
CLAUDE_CONTROLLER_CPU_OVERHEAD="${CLAUDE_CONTROLLER_CPU_OVERHEAD:-1}"
CLAUDE_CONTROLLER_MEM_OVERHEAD="${CLAUDE_CONTROLLER_MEM_OVERHEAD:-2g}"

# mem_to_mib <size> — parse a Docker memory size (Ng | Nm | Nk | Nb | bare bytes)
# to integer MiB, rounding UP. Returns 2 (fail closed) on anything unparseable, so
# a bad size can never collapse to 0 and under-size a controller. Docker's own
# convention: a bare number is BYTES (our profile always suffixes, but honor it).
mem_to_mib() {
    local s="$1" n unit
    [[ "$s" =~ ^([0-9]+)([bBkKmMgG]?)$ ]] || return 2
    n="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2],,}"
    case "$unit" in
        g) echo $(( n * 1024 )) ;;
        m) echo "$n" ;;
        k) echo $(( (n + 1023) / 1024 )) ;;
        b|"") echo $(( (n + 1048575) / 1048576 )) ;;
    esac
}

# mib_to_docker <mib> — render integer MiB as a Docker --memory arg: Ng on an exact
# GiB multiple, else Nm.
mib_to_docker() {
    local mib="$1"
    if (( mib % 1024 == 0 )); then echo "$(( mib / 1024 ))g"; else echo "${mib}m"; fi
}

# is_num <val> — true iff a non-negative decimal (integer or one/more fractional
# digits), the shape Docker --cpus accepts. Used to fail closed before awk math.
is_num() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }

# controller_envelope <K> — compute the Sysbox controller envelope that must hold
# Σ(K workers) + overhead, and set CTRL_CPUS / CTRL_CPUS_MILLI / CTRL_MEM /
# CTRL_MEM_MIB / CTRL_SHM. Under Sysbox nesting the controller's --cpus/--memory is
# a HARD ceiling on the SUM of its nested children (cgroup v2), so it must cover Σ
# (roadmap §5 — verify actual enforcement on-host via bin/claude-cgroup-verify;
# a parent cgroup can shadow a child limit in some nested setups).
controller_envelope() {
    local k="$1"
    { [[ "$k" =~ ^[0-9]+$ ]] && (( k >= 1 )); } || die "controller_envelope: K '$k' invalid"
    is_num "$CLAUDE_WORKER_CPUS"              || die "CLAUDE_WORKER_CPUS '$CLAUDE_WORKER_CPUS' is not numeric"
    is_num "$CLAUDE_CONTROLLER_CPU_OVERHEAD"  || die "CLAUDE_CONTROLLER_CPU_OVERHEAD '$CLAUDE_CONTROLLER_CPU_OVERHEAD' is not numeric"
    # pids is the one profile field with no downstream parse — validate it here so a
    # garbage/quote-bearing value fails closed (not silently into --pids-limit or the
    # sizing JSON). Must be a positive integer.
    { [[ "$CLAUDE_WORKER_PIDS" =~ ^[0-9]+$ ]] && (( CLAUDE_WORKER_PIDS >= 1 )); } \
        || die "CLAUDE_WORKER_PIDS '$CLAUDE_WORKER_PIDS' is not a positive integer"
    local wmib omib wshm
    wmib="$(mem_to_mib "$CLAUDE_WORKER_MEM")"             || die "unparseable CLAUDE_WORKER_MEM '$CLAUDE_WORKER_MEM'"
    omib="$(mem_to_mib "$CLAUDE_CONTROLLER_MEM_OVERHEAD")" || die "unparseable CLAUDE_CONTROLLER_MEM_OVERHEAD '$CLAUDE_CONTROLLER_MEM_OVERHEAD'"
    wshm="$(mem_to_mib "$CLAUDE_WORKER_SHM")"             || die "unparseable CLAUDE_WORKER_SHM '$CLAUDE_WORKER_SHM'"
    # A zero-sized worker (--memory 0g / --cpus 0) is misuse, not a valid envelope —
    # refuse rather than sizing a controller of pure overhead that "fits" any host.
    (( wmib >= 1 )) || die "CLAUDE_WORKER_MEM '$CLAUDE_WORKER_MEM' resolves to 0 MiB — a worker needs real memory"
    awk -v w="$CLAUDE_WORKER_CPUS" 'BEGIN{ exit (w > 0) ? 0 : 1 }' \
        || die "CLAUDE_WORKER_CPUS '$CLAUDE_WORKER_CPUS' must be > 0"
    CTRL_MEM_MIB=$(( k * wmib + omib ))
    CTRL_MEM="$(mib_to_docker "$CTRL_MEM_MIB")"
    CTRL_SHM="$(mib_to_docker $(( k * wshm )))"
    # CPU may be fractional (--cpus accepts floats). awk keeps a clean integer when
    # exact, else two decimals; CTRL_CPUS_MILLI is the integer-milli form for
    # host-headroom compares that must not use bash-only integer math on a float.
    CTRL_CPUS="$(awk -v k="$k" -v w="$CLAUDE_WORKER_CPUS" -v o="$CLAUDE_CONTROLLER_CPU_OVERHEAD" \
        'BEGIN{ c=k*w+o; if (c==int(c)) printf "%d", c; else printf "%.2f", c }')"
    CTRL_CPUS_MILLI="$(awk -v k="$k" -v w="$CLAUDE_WORKER_CPUS" -v o="$CLAUDE_CONTROLLER_CPU_OVERHEAD" \
        'BEGIN{ printf "%d", (k*w+o)*1000 }')"
    export CTRL_CPUS CTRL_CPUS_MILLI CTRL_MEM CTRL_MEM_MIB CTRL_SHM
}

# detect_host_cpus / detect_host_mem_mib — the host's total CPU and memory. Test
# seams (loudly warned) let the unit tests drive the fail-safe on any machine.
detect_host_cpus() {
    if [[ -n "${CLAUDE_HOST_CPUS_OVERRIDE:-}" ]]; then
        warn "TEST SEAM ACTIVE: CLAUDE_HOST_CPUS_OVERRIDE=${CLAUDE_HOST_CPUS_OVERRIDE} — host CPU count is NOT being probed"
        echo "$CLAUDE_HOST_CPUS_OVERRIDE"; return 0
    fi
    nproc 2>/dev/null || echo 0
}
detect_host_mem_mib() {
    if [[ -n "${CLAUDE_HOST_MEM_MIB_OVERRIDE:-}" ]]; then
        warn "TEST SEAM ACTIVE: CLAUDE_HOST_MEM_MIB_OVERRIDE=${CLAUDE_HOST_MEM_MIB_OVERRIDE} — host memory is NOT being probed"
        echo "$CLAUDE_HOST_MEM_MIB_OVERRIDE"; return 0
    fi
    local kb
    kb="$(sed -n 's/^MemTotal:[[:space:]]*\([0-9]*\).*/\1/p' /proc/meminfo 2>/dev/null | head -1)"
    [[ -n "$kb" ]] && echo $(( kb / 1024 )) || echo 0
}

# check_controller_capacity <K> — the FAIL-SAFE (roadmap §4.3 / CC-3 done-line): if
# the K-derived controller envelope exceeds detected host capacity, REFUSE (die)
# and report the deficit. Never silently overcommit. A host that cannot be probed
# (0) is reported as a deficit, not waved through (fail closed). On success emits a
# one-line "fits" summary to stderr and returns 0, with CTRL_* set for the caller.
check_controller_capacity() {
    local k="$1"
    controller_envelope "$k"
    local hcpus hmem host_milli reasons=()
    hcpus="$(detect_host_cpus)"; hmem="$(detect_host_mem_mib)"
    host_milli="$(awk -v h="$hcpus" 'BEGIN{ printf "%d", h*1000 }' 2>/dev/null || echo 0)"
    if (( host_milli <= 0 )); then
        reasons+=("host CPU count unknown (could not probe) — cannot prove headroom")
    elif (( CTRL_CPUS_MILLI > host_milli )); then
        reasons+=("needs ${CTRL_CPUS} CPUs, host has ${hcpus}")
    fi
    if (( hmem <= 0 )); then
        reasons+=("host memory unknown (could not probe) — cannot prove headroom")
    elif (( CTRL_MEM_MIB > hmem )); then
        reasons+=("needs ${CTRL_MEM} (${CTRL_MEM_MIB} MiB), host has $(mib_to_docker "$hmem") (${hmem} MiB)")
    fi
    if (( ${#reasons[@]} > 0 )); then
        local r; for r in "${reasons[@]}"; do err "capacity: $r"; done
        die "K=$k controller envelope (${CTRL_CPUS} CPU / ${CTRL_MEM} / ${CTRL_SHM} shm) exceeds host capacity — refusing to overcommit (lower K in operations/parallel.config.json, shrink the worker profile, or add host capacity)"
    fi
    ok "K=$k fits: controller ${CTRL_CPUS} CPU / ${CTRL_MEM} / ${CTRL_SHM} shm  ≤  host ${hcpus} CPU / $(mib_to_docker "$hmem")" >&2
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
