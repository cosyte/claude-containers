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

# Sysbox version floor for the nested-worker substrate (CC-1, umbrella ADR 0011). Nested
# workers run under sysbox-runc instead of runc, so the Nov-2025 runc escape-CVE floor
# (CVE-2025-31133 / 52565 / 52881) generalizes to "a Sysbox release that ports those
# patches" — v0.7.0 (2026-06-02) is the first. Unlike preflight_runc above (warn-only,
# because the flat K=1 launch path predates nesting and must not change behavior), this
# check is a REFUSAL: nothing may stand up a nested worker on a pre-patch runtime.
SYSBOX_MIN_VERSION="${SYSBOX_MIN_VERSION:-0.7.0}"

# Die unless a CVE-patched Sysbox is installed AND registered with Docker.
# Test seams: CLAUDE_SYSBOX_FAKE_VERSION injects a version string (skips the binary);
# CLAUDE_SYSBOX_SKIP_DOCKER=1 skips the Docker runtime-registration check.
preflight_sysbox() {
    local sv=""
    if [[ -n "${CLAUDE_SYSBOX_FAKE_VERSION:-}" ]]; then
        sv="$CLAUDE_SYSBOX_FAKE_VERSION"
    else
        command -v sysbox-runc >/dev/null 2>&1 \
            || die "sysbox-runc not found — install Sysbox >= $SYSBOX_MIN_VERSION first (docs/substrate.md)"
        # Robust to both output shapes ("sysbox-runc version X.Y.Z" and the multi-line
        # "version: X.Y.Z" form): first semver token wins.
        sv="$(sysbox-runc --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
        [[ -n "$sv" ]] || die "could not parse a version out of 'sysbox-runc --version'"
    fi
    sv="${sv#v}"
    local pre=""; [[ "$sv" == *-* ]] && pre="${sv#*-}"
    sv="${sv%%[+-]*}"
    local M m p fM fm fp
    IFS=. read -r M m p <<<"$sv";                 M=${M:-0} m=${m:-0} p=${p:-0}
    IFS=. read -r fM fm fp <<<"$SYSBOX_MIN_VERSION"; fM=${fM:-0} fm=${fm:-0} fp=${fp:-0}
    [[ "$M$m$p" =~ ^[0-9]+$ ]] || die "unparseable Sysbox version '$sv'"
    if ! (( M > fM || (M == fM && m > fm) || (M == fM && m == fm && p >= fp) )); then
        die "Sysbox $sv predates the Nov-2025 escape-CVE patches (CVE-2025-31133/52565/52881, ported in $SYSBOX_MIN_VERSION) — refusing to use it for nested workers"
    fi
    # A pre-release of exactly the floor (e.g. 0.7.0-rc.1) cannot be proven to carry the
    # patches — fail closed. (Release-line parses never carry a suffix; this guards the seam.)
    if [[ -n "$pre" && "$M.$m.$p" == "$fM.$fm.$fp" ]]; then
        die "Sysbox $M.$m.$p-$pre is a pre-release of the floor $SYSBOX_MIN_VERSION — cannot prove it carries the CVE patches, refusing"
    fi
    if [[ "${CLAUDE_SYSBOX_SKIP_DOCKER:-0}" != 1 ]]; then
        docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"sysbox-runc"' \
            || die "Docker has no 'sysbox-runc' runtime registered — see docs/substrate.md (daemon.json + SIGHUP reload)"
    fi
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
