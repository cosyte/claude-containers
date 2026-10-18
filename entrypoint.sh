#!/bin/bash
# Claude Code container entrypoint.
# Starts as root: sets up sshd, fixes volume ownership, merges baked-in config,
# prepares the workspace, then drops to the unprivileged `claude` user to run
# Claude Code inside a persistent tmux session.
set -euo pipefail

# Root resolves commands through system directories only, whatever the container's
# environment says. The agent's PATH (CLAUDE_AGENT_PATH, the Dockerfile ENV) leads with
# directories the agent can write, so it is handed only to processes that run as the agent
# (asclaude below). Everything this file and entrypoint.d/ start inherits ROOT_PATH.
ROOT_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH="$ROOT_PATH"
export CLAUDE_AGENT_PATH="${CLAUDE_AGENT_PATH:-$ROOT_PATH}"

CLAUDE_USER="${CLAUDE_USER:-claude}"
CLAUDE_HOME="$(getent passwd "$CLAUDE_USER" | cut -d: -f6)"
CLAUDE_UID="$(id -u "$CLAUDE_USER")"
CLAUDE_GID="$(id -g "$CLAUDE_USER")"
export CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$CLAUDE_HOME/.claude}"

# shellcheck disable=SC2034  # the sections in entrypoint.d/ read these
{
AUTH_DIR="/auth"                              # shared credentials volume
HOSTKEY_DIR="/etc/ssh/host-keys"              # shared host-key volume
BAKE_DIR="/opt/claude-config"                 # image-baked config source
AUTHKEYS_SRC="/etc/claude/authorized_keys"    # host-mounted, read-only
GITKEY_SRC="/etc/claude/git-key"              # host-mounted, read-only
WORKSPACE="/workspace"
}

log()  { echo "[entrypoint] $*"; }
die()  { echo "[entrypoint] ERROR: $*" >&2; exit 1; }
# Run as the agent, with the agent's PATH (root's own PATH stays ROOT_PATH).
asclaude() { gosu "$CLAUDE_USER" env PATH="$CLAUDE_AGENT_PATH" CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" HOME="$CLAUDE_HOME" "$@"; }
# Hand a tree to the agent user, touching only what is not already its own. `chown -R` writes
# every inode (a chown with the same owner still updates ctime), so on maker's config volume
# and ten-repo workspace on spinning disk it held every boot for minutes before any session
# started (2026-10-07). find only reads a tree that is already right. -h: a symlink itself,
# never its target, as chown -R did; find does not follow symlinks either. -execdir, not -exec:
# the workspace pass runs while the agent is up (§12g), and -h guards only the last component,
# so a parent directory swapped for a symlink between find and chown would hand the agent a
# root file. -execdir chowns ./name from inside the directory find already holds.
# OWN_TREE_KEEP_IDS="LO HI" (a --containers session) leaves files whose owner or group is in
# that range alone: they belong to a nested container (postgres's 999 is 100998 here; a file its
# root writes with the postgres group is 1000:100998), and handing them to the agent breaks that
# container's bind-mounted data on the next boot. Set here, before any section runs, because
# the first passes (§2's config volume, §2c's /state) come before §2d, which gives the agent
# this same range in /etc/subuid and /etc/subgid.
CONTAINERS_SUBID_START=100000 CONTAINERS_SUBID_COUNT=65536
OWN_TREE_KEEP_IDS=""
if [[ "${CLAUDE_CONTAINERS:-0}" =~ ^(1|true|yes|on)$ ]]; then
    OWN_TREE_KEEP_IDS="$CONTAINERS_SUBID_START $((CONTAINERS_SUBID_START + CONTAINERS_SUBID_COUNT - 1))"
fi
own_tree() {
    local keep=() _lo _hi
    if [[ -n "${OWN_TREE_KEEP_IDS:-}" ]]; then
        read -r _lo _hi <<<"$OWN_TREE_KEEP_IDS"
        keep=(! \( -uid "+$((_lo - 1))" -uid "-$((_hi + 1))" \)
              ! \( -gid "+$((_lo - 1))" -gid "-$((_hi + 1))" \))
    fi
    find "$@" \( ! -uid "$CLAUDE_UID" -o ! -gid "$CLAUDE_GID" \) "${keep[@]}" \
        -execdir chown -h "$CLAUDE_UID:$CLAUDE_GID" {} +
}

# --- Sections ------------------------------------------------------------------
# Each numbered section is its own file in $ENTRYPOINT_D (entrypoint.d/ in the repo), named
# NN[x]-name.sh after its number, and sourced here in that order: into this shell, so the
# variables, functions and background jobs a section leaves are there for every later one,
# and `set -euo pipefail` holds inside each. Sorted in the C locale: elsewhere a collation
# that skips punctuation would put 00b- before 00-. Each section is announced as "§<n> <name>"
# so the boot log shows where every line came from. A file's last command is source's status,
# so none may end in a skipped `[[ ]] && x` (test/entrypoint-unit.sh checks each last line).
# §13 never returns.
ENTRYPOINT_D=/usr/local/lib/claude/entrypoint.d
mapfile -t _sections < <(printf '%s\n' "$ENTRYPOINT_D"/[0-9]*.sh | LC_ALL=C sort)
[[ -f "${_sections[0]}" ]] || die "no sections in $ENTRYPOINT_D: the image is incomplete"
for _section in "${_sections[@]}"; do
    _name="${_section##*/}"; _name="${_name%.sh}"; _n="${_name%%-*}"
    log "§${_n#0} ${_name#*-}"
    # shellcheck source=/dev/null  # each file is linted on its own (Makefile LINT_SH)
    source "$_section"
done
unset _sections _section _name _n
