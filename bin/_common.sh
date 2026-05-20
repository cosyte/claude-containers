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
