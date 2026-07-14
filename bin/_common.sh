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
# Shared tool cache (PKG-3): ONE volume shared across every managed container,
# mounted at /cache, holding mise's install store + the language package-manager
# caches. Empty string ("" / "off"/"none" from a launcher flag) disables it —
# the container then provisions per-container into its own layer (fail-safe).
CACHE_VOLUME="${CLAUDE_CACHE_VOLUME:-claude-cache}"
CACHE_MOUNT="/cache"
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
#
# harden_run_args [docker_mode] — pass 1 for a --docker (Sysbox) container.
#
# In docker mode the cap-drop is SKIPPED, because an inner dockerd cannot run under
# the minimal set (it needs NET_ADMIN for its bridge/iptables and SYS_ADMIN to mount
# layers; neither is even in Docker's *default* set). This is not the loss it looks
# like. Measured on this host — `docker run --runtime=sysbox-runc alpine cat
# /proc/self/status,/proc/self/uid_map`:
#
#   runc         CapEff 00000000a80425fb   uid_map 0 0 4294967295  → container-root IS host root
#   sysbox-runc  CapEff 000001ffffffffff   uid_map 0 165536 65536  → container-root is host uid 165536
#
# Sysbox hands container-root the FULL capability set, but inside a user namespace whose
# root maps to an unprivileged host uid — so those caps are powers over the container's
# own namespace, not the host. Dropping them would break the daemon while buying nothing
# the userns isn't already buying. no-new-privileges is kept either way (verified: nested
# build+run works with it on); its one real cost is that setuid binaries inside an INNER
# container (sudo, ping) can't elevate.
harden_run_args() {
    local docker_mode="${1:-0}"
    local out="--security-opt no-new-privileges"
    if [[ ! "$docker_mode" =~ ^(1|true|yes|on)$ ]] \
       && [[ "$CLAUDE_HARDEN_CAPS" =~ ^(1|true|yes|on)$ ]]; then
        out+=" --cap-drop ALL"
        local c; for c in $CLAUDE_MIN_CAPS; do out+=" --cap-add $c"; done
    fi
    # The egress firewall needs NET_ADMIN at boot (used by root only; the agent
    # stays unprivileged and so cannot alter the rules).
    [[ "${CLAUDE_EGRESS_LOCKDOWN:-0}" =~ ^(1|true|yes|on)$ ]] && out+=" --cap-add NET_ADMIN"
    echo "$out"
}

# Refuse --docker on a host with no Sysbox runtime. Without it the inner daemon has no
# user namespace to live in and dies ~60s later inside the container, surfacing as an
# opaque entrypoint timeout — so fail here instead, loudly, with the fix. The ONLY
# alternatives to Sysbox are --privileged and a host-socket mount, and both hand a
# prompt-injectable agent the host, so neither is offered as a fallback.
preflight_sysbox() {
    docker info --format '{{range $r, $_ := .Runtimes}}{{$r}} {{end}}' 2>/dev/null \
        | grep -qw 'sysbox-runc' && return 0
    die "--docker needs the Sysbox runtime, which this host's Docker daemon does not have.
       Sysbox runs the inner daemon in a user namespace (container-root → an unprivileged
       host uid), which is what makes nested Docker safe without --privileged or a host
       socket mount. Neither of those is an acceptable substitute here: each would give
       the agent root on the host.
       Install:  https://github.com/nestybox/sysbox   then:  docker info | grep sysbox-runc"
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
# ERROR (return 2) so security-minded callers can fail CLOSED instead of comparing
# garbage as 0. Base-10 forced (10#) so a leading zero can't trip octal arithmetic.
version_ge() {
    local aM am ap bM bm bp
    IFS=. read -r aM am ap <<<"$1"; aM=${aM:-0} am=${am:-0} ap=${ap:-0}
    IFS=. read -r bM bm bp <<<"$2"; bM=${bM:-0} bm=${bm:-0} bp=${bp:-0}
    [[ "$aM$am$ap$bM$bm$bp" =~ ^[0-9]+$ ]] || return 2
    (( 10#$aM > 10#$bM || (10#$aM == 10#$bM && (10#$am > 10#$bm || (10#$am == 10#$bm && 10#$ap >= 10#$bp))) ))
}

# Flat-session fork-bomb guard (claude-launch / compose services).
CLAUDE_PIDS_LIMIT="${CLAUDE_PIDS_LIMIT:-2048}"

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

# --- Disk-space safety --------------------------------------------------------
# disk_free_mib <path> — print the free space, in integer MiB, on the
# filesystem holding <path>. Backs bin/claude-disk-gc's before/after reporting.
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
# Per-container /var/lib/docker for --docker sessions. Sysbox gives each container its own
# inner image store, but that store dies WITH the container — so without this volume every
# recreate re-pulls every base image and rebuilds every layer from cold. Per-container (not
# shared): two daemons must never write one image store. claude-rm --purge deletes it; it is
# the one volume here that can reach tens of GB, so it is called out in the purge prompt.
docker_volume() { echo "claude-docker-$1"; }

# --- Shared tool cache (PKG-3) -----------------------------------------------
# cache_name — the shared cache volume name, or "" when disabled. A launcher may
# pass an override (its --cache value); "", "off", "none", "0", "false" all disable.
cache_name() {
    local v="${1-$CACHE_VOLUME}"
    case "$v" in ""|off|none|0|false|no) echo ""; return 0 ;; esac
    echo "$v"
}

# cache_mount_args <volname-or-override> — echo the `-v <vol>:/cache` docker arg
# for the shared cache, or nothing when disabled. Docker auto-creates the named
# volume on first use (seeded from the image's /cache), so this NEVER errors a
# launch — a missing cache degrades to per-container installs, it does not fail.
cache_mount_args() {
    local n; n="$(cache_name "${1-$CACHE_VOLUME}")"
    [[ -n "$n" ]] && printf -- '-v\n%s\n' "$n:$CACHE_MOUNT"
}

# dir_size_mib <path> — integer MiB used by a directory subtree, or "" if it
# cannot be determined (fail-soft: callers treat unknown as "do not trim").
# `du -s -B1M` gives 1-MiB-block totals; the TEST SEAM forces the value.
dir_size_mib() {
    local path="$1" line
    if [[ -n "${CLAUDE_CACHE_SIZE_MIB_OVERRIDE:-}" ]]; then
        warn "TEST SEAM ACTIVE: CLAUDE_CACHE_SIZE_MIB_OVERRIDE='${CLAUDE_CACHE_SIZE_MIB_OVERRIDE}' — real cache size is NOT being measured"
        [[ "$CLAUDE_CACHE_SIZE_MIB_OVERRIDE" =~ ^[0-9]+$ ]] || return 1
        echo "$CLAUDE_CACHE_SIZE_MIB_OVERRIDE"; return 0
    fi
    [[ -d "$path" ]] || return 1
    line="$(du -s -B1M "$path" 2>/dev/null | awk '{print $1}' || true)"
    [[ "$line" =~ ^[0-9]+$ ]] || return 1
    echo "$line"
}

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
