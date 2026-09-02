#!/usr/bin/env bash
# Claude Code container entrypoint.
# Starts as root: sets up sshd, fixes volume ownership, merges baked-in config,
# prepares the workspace, then drops to the unprivileged `claude` user to run
# Claude Code inside a persistent tmux session.
set -euo pipefail

CLAUDE_USER="${CLAUDE_USER:-claude}"
CLAUDE_HOME="$(getent passwd "$CLAUDE_USER" | cut -d: -f6)"
CLAUDE_UID="$(id -u "$CLAUDE_USER")"
CLAUDE_GID="$(id -g "$CLAUDE_USER")"
export CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$CLAUDE_HOME/.claude}"

AUTH_DIR="/auth"                              # shared credentials volume
HOSTKEY_DIR="/etc/ssh/host-keys"              # shared host-key volume
BAKE_DIR="/opt/claude-config"                 # image-baked config source
AUTHKEYS_SRC="/etc/claude/authorized_keys"    # host-mounted, read-only
GITKEY_SRC="/etc/claude/git-key"              # host-mounted, read-only
WORKSPACE="/workspace"

log()  { echo "[entrypoint] $*"; }
die()  { echo "[entrypoint] ERROR: $*" >&2; exit 1; }
asclaude() { gosu "$CLAUDE_USER" env CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" HOME="$CLAUDE_HOME" "$@"; }

# --- 0. Refuse retired broker/Sysbox env -------------------------------
# bin/claude-launch and bin/claude-compose-gen already REFUSE the removed --broker /
# --sysbox / --worker-tarball flags. The env vars those flags used to set are now simply
# UNREAD, and silence there is not safe: an operator running CLAUDE_CACHE_PROXY_HOST with
# CLAUDE_EGRESS_LOCKDOWN=1 had a single audited egress choke point (public npm blocked, all
# package traffic through their proxy). Since the strip the var means nothing, the firewall
# composes its default allowlist, and registry.npmjs.org is directly reachable again: a
# real, silent loosening of their posture. So say so, loudly, at boot.
#
# WARN (not die) because these are inert leftovers in a .env, not an active request: a
# container that refused to boot on a stale .env line would be a worse regression than the
# one we are warning about. CLAUDE_BROKER_GIT_KEY is deliberately NOT in this list: it is
# the git-key broker, a LIVE credential-isolation control, unrelated to the worker broker.
RETIRED_VARS=(
    CLAUDE_WORKER_BROKER CLAUDE_WORKER_TARBALL CLAUDE_BROKER_DIR CLAUDE_BROKER_SPOOL
    CLAUDE_SYSBOX CLAUDE_SYSBOX_VERIFY
    CLAUDE_CACHE_PROXY CLAUDE_CACHE_PROXY_HOST CLAUDE_CACHE_PROXY_PORT
    CLAUDE_APT_PROVISION CLAUDE_EGRESS_APT
    CLAUDE_CONTROLLER_MAX_SLOTS
)
_retired_set=()
for _v in "${RETIRED_VARS[@]}"; do
    [[ -n "${!_v:-}" ]] && _retired_set+=("$_v")
done
if (( ${#_retired_set[@]} > 0 )); then
    log "WARNING: these env vars were RETIRED with the worker-broker substrate and are now IGNORED: ${_retired_set[*]}"
    log "WARNING: the Sysbox worker-broker, the curated apt tier, and the pull-through"
    log "WARNING: cache proxy were removed, see docs/legacy-sysbox-broker.md."
    for _v in "${_retired_set[@]}"; do
        case "$_v" in
            CLAUDE_CACHE_PROXY_HOST|CLAUDE_CACHE_PROXY|CLAUDE_CACHE_PROXY_PORT)
                log "WARNING: $_v no longer routes package traffic through a proxy. If you relied"
                log "WARNING: on it as an audited egress choke point, that is GONE: the firewall now"
                log "WARNING: composes its default allowlist and registry.npmjs.org is reachable"
                log "WARNING: directly. Re-establish the choke point outside this container." ;;
            CLAUDE_EGRESS_APT|CLAUDE_APT_PROVISION)
                log "WARNING: $_v is inert, there is no in-session system-package install path at"
                log "WARNING: all now (a base-image rebuild is the only route to a new syslib)." ;;
        esac
    done
fi
unset _v _retired_set RETIRED_VARS

# --- 0b. Refuse the retired CLAUDE_CONTROLLER mode ------------------
# The substrate strip deleted the broker-dispatch tier this mode existed to drive, leaving
# bin/claude-controller a byte-identical pass-through to claude-autopilot: a mode whose only
# job was selecting another mode, so it was removed.
#
# This DIES where §0 above merely WARNS, and the difference is the point. Those vars are inert
# leftovers in a .env: nothing reads them, so warning is enough and refusing to boot on a stale
# line would be the worse bug. CLAUDE_CONTROLLER=1 is not inert: it is an ACTIVE request for
# UNATTENDED operation. Warn-and-ignore would fall through to interactive mode and boot a fleet
# container into a Remote-Control session that nobody is watching and that never runs the loop:
# a container that looks alive and does nothing, which is the worst state this image can be in.
# So refuse, and name the replacement. It costs the operator one character.
#
# Fails FAST: here, not at mode selection ~500 lines down, so a `--restart unless-stopped`
# container doesn't crashloop through sshd, volume chown and a repo clone before saying why.
# (CLAUDE_CONTROLLER=0, which every older .env.example carries, matches nothing and boots
# clean: a stale line must never brick a container.)
case "${CLAUDE_CONTROLLER:-0}" in
    1|true|yes|on)
        die "CLAUDE_CONTROLLER was REMOVED. It had been a byte-identical pass-through
       to CLAUDE_AUTOPILOT=1 ever since the strip retired the Sysbox nested-worker-broker
       dispatch tier it existed to drive (see docs/legacy-sysbox-broker.md). Set
       CLAUDE_AUTOPILOT=1 instead: it is the same loop, and always was." ;;
esac

# --- 1. Refuse API-key auth --------------------------------------------------
# This image is OAuth-subscription only. An API key would silently override the
# subscription and bill per-token, so fail fast and loud.
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    die "ANTHROPIC_API_KEY is set. This image uses OAuth subscription auth only.
       Unset ANTHROPIC_API_KEY (it is not needed and would override your
       Claude subscription with per-token API billing)."
fi

# --- Login mode --------------------------------------------------------------
# `make login` runs the image with CLAUDE_LOGIN_MODE=1 to perform the one-time
# OAuth flow and write credentials to the shared claude-auth volume.
if [[ "${CLAUDE_LOGIN_MODE:-0}" == "1" ]]; then
    mkdir -p "$AUTH_DIR"
    chown -R "$CLAUDE_UID:$CLAUDE_GID" "$AUTH_DIR"
    log "Starting OAuth login. Open the printed URL in a browser, then paste"
    log "the code back here. Credentials persist to the claude-auth volume."
    exec gosu "$CLAUDE_USER" env CLAUDE_CONFIG_DIR="$AUTH_DIR" HOME="$CLAUDE_HOME" \
        claude auth login --claudeai
fi

# --- 1b. Multi-account mode (opt-in) ------------------------------------------
# CLAUDE_ACCOUNTS (comma-separated names) redirects AUTH_DIR from the single
# shared /auth volume to one of several named /auth-accounts/<name> volumes
# mounted by `claude-launch --accounts`: each created by `claude-account-login
# <name>`. Works with any account count >= 1: a single account still benefits
# (bin/claude-usage-watchdog auto-resumes it once its usage window resets), and
# unset (the default) leaves AUTH_DIR="/auth" with every line below unchanged.
# The "active" account persists in a state file so a rotation survives a plain
# `docker start` (which reuses creation-time env/mounts, not a fresh launch).
ACCOUNT_NAMES=()
if [[ -n "${CLAUDE_ACCOUNTS:-}" ]]; then
    IFS=',' read -ra ACCOUNT_NAMES <<< "$CLAUDE_ACCOUNTS"
    (( ${#ACCOUNT_NAMES[@]} > 0 )) || die "CLAUDE_ACCOUNTS is set but empty"
    for n in "${ACCOUNT_NAMES[@]}"; do
        [[ -d "/auth-accounts/$n" ]] || die "account '$n' listed in CLAUDE_ACCOUNTS has no volume mounted at /auth-accounts/$n: check claude-launch --accounts wiring"
    done
    mkdir -p "$CLAUDE_CONFIG_DIR"
    ACTIVE_FILE="$CLAUDE_CONFIG_DIR/.active-account"
    [[ -s "$ACTIVE_FILE" ]] || echo "${ACCOUNT_NAMES[0]}" > "$ACTIVE_FILE"
    ACTIVE_ACCOUNT="$(cat "$ACTIVE_FILE")"
    case ",${CLAUDE_ACCOUNTS}," in
        *",${ACTIVE_ACCOUNT},"*) ;;
        *) log "WARNING: previously-active account '$ACTIVE_ACCOUNT' is no longer in CLAUDE_ACCOUNTS: falling back to '${ACCOUNT_NAMES[0]}'"
           ACTIVE_ACCOUNT="${ACCOUNT_NAMES[0]}"
           echo "$ACTIVE_ACCOUNT" > "$ACTIVE_FILE" ;;
    esac
    AUTH_DIR="/auth-accounts/$ACTIVE_ACCOUNT"
    log "Multi-account mode  : ${#ACCOUNT_NAMES[@]} account(s) (${CLAUDE_ACCOUNTS}); active=$ACTIVE_ACCOUNT"
fi

# --- 2. Fix ownership of mounted volumes -------------------------------------
mkdir -p "$CLAUDE_CONFIG_DIR" "$AUTH_DIR" "$HOSTKEY_DIR" "$CLAUDE_HOME/.ssh" "$WORKSPACE"
chown -R "$CLAUDE_UID:$CLAUDE_GID" "$CLAUDE_CONFIG_DIR" "$CLAUDE_HOME/.ssh"
chown "$CLAUDE_UID:$CLAUDE_GID" "$WORKSPACE" 2>/dev/null || true
chmod 700 "$CLAUDE_HOME/.ssh"

# --- 2a. Disk-backed scratch (TMPDIR) ----------------------------------------
# /tmp is a tmpfs: RAM, ~1g, charged to the memory cgroup. With TMPDIR unset everything
# large lands there: pip/uv wheel builds, `docker save|load` tarballs, the inner
# containerd's mount dirs, and dies at the cap with an ENOSPC that reads like a bug, while
# the host has terabytes free. So point TMPDIR at a disk-backed volume. TMPDIR is exported
# by the launcher/compose (so dockerd, containerd and every child inherit it); this block
# just makes the directory usable, and tolerates its absence so an older container (or a
# plain `docker run` of this image) still boots with the historical /tmp behaviour.
SCRATCH_DIR="${TMPDIR:-}"
if [[ -n "$SCRATCH_DIR" && "$SCRATCH_DIR" != "/tmp" ]]; then
    if mkdir -p "$SCRATCH_DIR" 2>/dev/null; then
        # 1777 like /tmp: the agent is unprivileged, but root writes here too (dockerd).
        chown "$CLAUDE_UID:$CLAUDE_GID" "$SCRATCH_DIR" 2>/dev/null || true
        chmod 1777 "$SCRATCH_DIR" 2>/dev/null || true
        # Clear stale contents on boot. This is scratch, not state: a volume (unlike a tmpfs)
        # survives restarts, so without this it accumulates every abandoned wheel build and
        # half-written tarball forever, and slowly fills the pool. Deleting only at boot means
        # nothing in flight is ever pulled out from under a running process.
        find "$SCRATCH_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
        log "Scratch (TMPDIR)    : $SCRATCH_DIR (disk-backed; cleared on boot)"
    else
        log "WARNING: TMPDIR=$SCRATCH_DIR is not creatable, falling back to /tmp (a 1g tmpfs)."
        log "WARNING: Large installs/builds may fail with ENOSPC. Mount a scratch volume there."
        unset TMPDIR
    fi
fi

# --- 3. SSH host keys (persistent) -------------------------------------------
if [[ ! -f "$HOSTKEY_DIR/ssh_host_ed25519_key" ]]; then
    log "Generating persistent SSH host keys"
    ssh-keygen -q -t ed25519 -f "$HOSTKEY_DIR/ssh_host_ed25519_key" -N ''
    ssh-keygen -q -t rsa -b 4096 -f "$HOSTKEY_DIR/ssh_host_rsa_key" -N ''
fi
chmod 600 "$HOSTKEY_DIR"/ssh_host_*_key
chmod 644 "$HOSTKEY_DIR"/ssh_host_*_key.pub

# --- 4. Authorized keys (SSH access) -----------------------------------------
if [[ -s "$AUTHKEYS_SRC" ]]; then
    install -o "$CLAUDE_UID" -g "$CLAUDE_GID" -m 600 \
        "$AUTHKEYS_SRC" "$CLAUDE_HOME/.ssh/authorized_keys"
    log "Installed authorized_keys for SSH"
else
    log "WARNING: no authorized_keys mounted at $AUTHKEYS_SRC"
    log "         SSH will be unusable; Remote Control still works."
fi

# --- 5. Git SSH key + identity -----------------------------------------------
# A mounted deploy key is BROKERED BY DEFAULT: it is loaded into a ROOT-owned
# ssh-agent and only a relay socket is exposed to the claude user, so git can
# sign/push with the key while the unprivileged (prompt-injectable) agent can
# never read the private key bytes and so cannot exfiltrate it. An operator who
# needs the historical readable ~/.ssh/id_ed25519 opts OUT explicitly with
# CLAUDE_BROKER_GIT_KEY=0. Either way the key is never baked into the image.
#
# THE VALUE RULE, and why it is written as "opt out" rather than "opt in":
# only a RECOGNISED disabling value (0/false/no/off) selects the readable file.
# Unset brokers, an enabling value brokers, and anything unrecognised (a typo,
# an empty value, "yes please") ALSO brokers. Containment must never be
# downgraded by a value nobody meant, so the fallible direction is the safe one.
#
# FAIL CLOSED. When brokering is engaged and cannot be established there is NO
# readable-file fallback: no key file is installed, git is left unable to
# authenticate with that key for this boot, and the failure is logged loudly.
# A failed push is recoverable; an exfiltrated deploy key is not. Only an
# operator who explicitly recorded CLAUDE_BROKER_GIT_KEY=0 ever gets a readable
# key file.
#
# Every path below (brokered, readable file, broker failed, no key mounted)
# ends with a "Deploy key readable :" line stating in plain language whether the
# agent user can read the key right now, so an operator scanning the boot log
# never has to infer it from which other line appeared.
#
# BROKER_RUN_DIR / BROKER_PROFILE_D are named here rather than inlined below
# because they are the two ROOT-ONLY paths in this section: naming them lets
# test/unit.sh run this exact block, unmodified in every decision it makes,
# against a sandbox instead of needing root.
git_brokered=0                                            # outcome flag; test/unit.sh reads it
BROKER_RUN_DIR="/run/claude"                              # root-owned socket dir
BROKER_PROFILE_D="/etc/profile.d/claude-ssh-agent.sh"     # login-shell SSH_AUTH_SOCK export
if [[ -s "$GITKEY_SRC" ]]; then
    cat > "$CLAUDE_HOME/.ssh/config" <<EOF
Host *
    StrictHostKeyChecking accept-new
    UserKnownHostsFile ~/.ssh/known_hosts
EOF
    if [[ "${CLAUDE_BROKER_GIT_KEY:-}" =~ ^(0|false|no|off)$ ]]; then
        # THE EXPLICIT OPT-OUT, and the only path that writes a readable key.
        # Drop any relay export a previous brokered boot of THIS container left
        # in /etc/profile.d: `docker restart` keeps the container filesystem, so
        # without this a login shell would point SSH_AUTH_SOCK at a dead socket.
        rm -f "$BROKER_PROFILE_D"
        install -o "$CLAUDE_UID" -g "$CLAUDE_GID" -m 600 \
            "$GITKEY_SRC" "$CLAUDE_HOME/.ssh/id_ed25519"
        printf 'Host *\n    IdentityFile ~/.ssh/id_ed25519\n' >> "$CLAUDE_HOME/.ssh/config"
        log "Git SSH key         : installed as a readable file at ~/.ssh/id_ed25519 (CLAUDE_BROKER_GIT_KEY=${CLAUDE_BROKER_GIT_KEY} opt-out)"
        log "Deploy key readable : YES. The agent user can read this deploy key's private bytes (mode 600, owned by $CLAUDE_USER). Unset CLAUDE_BROKER_GIT_KEY to broker it instead."
    else
        # Key lives only in a ROOT ssh-agent's memory (+ the root-only mounted
        # key file). ssh-agent rejects cross-uid peers, so a root socat relay
        # exposes a claude-usable socket and forwards to the root agent: claude
        # signs through it (git push works) but can neither extract the key
        # (agent protocol never returns private keys) nor read root's memory.
        #
        # FIRST, delete any readable key file an EARLIER boot of this same
        # container installed. `docker restart` keeps the container filesystem,
        # so a container that once ran with CLAUDE_BROKER_GIT_KEY=0 and is
        # restarted without it would otherwise broker the key AND leave the old
        # agent-readable copy sitting in ~/.ssh. Brokering has to mean the bytes
        # are gone from the agent's home, not merely that this boot did not add
        # them. (The ssh config was rewritten from scratch above, so its
        # IdentityFile line is already gone.)
        rm -f "$CLAUDE_HOME/.ssh/id_ed25519" "$CLAUDE_HOME/.ssh/id_ed25519.pub"
        mkdir -p "$BROKER_RUN_DIR" && chmod 711 "$BROKER_RUN_DIR"
        AGENT_SOCK="$BROKER_RUN_DIR/agent-root.sock"     # root-only
        CLAUDE_SOCK="$BROKER_RUN_DIR/agent.sock"         # claude-usable, via relay
        rm -f "$AGENT_SOCK" "$CLAUDE_SOCK"
        if ssh-agent -a "$AGENT_SOCK" >/dev/null 2>&1; then
            for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -S "$AGENT_SOCK" ]] && break; sleep 0.2; done
        fi
        if [[ -S "$AGENT_SOCK" ]] && SSH_AUTH_SOCK="$AGENT_SOCK" ssh-add "$GITKEY_SRC" >/dev/null 2>&1; then
            socat "UNIX-LISTEN:$CLAUDE_SOCK,fork,mode=0600,user=$CLAUDE_USER" \
                  "UNIX-CONNECT:$AGENT_SOCK" >/dev/null 2>&1 &
            for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -S "$CLAUDE_SOCK" ]] && break; sleep 0.2; done
        fi
        if [[ -S "$CLAUDE_SOCK" ]]; then
            chmod 600 "$AGENT_SOCK" 2>/dev/null || true     # keep the real agent root-only
            export SSH_AUTH_SOCK="$CLAUDE_SOCK"
            printf 'export SSH_AUTH_SOCK=%s\n' "$CLAUDE_SOCK" > "$BROKER_PROFILE_D"
            git_brokered=1
            log "Git SSH key broker  : key held in a root ssh-agent (claude signs via relay, cannot read it)"
            log "Deploy key readable : NO. The agent user cannot read this deploy key's private bytes: no key file exists under $CLAUDE_HOME, and signing happens inside a root-owned ssh-agent."
        else
            # FAIL CLOSED: no readable-file fallback, ever. Loud, because the
            # operator's git pushes over this key will now fail and the reason
            # has to be on the first screen of `docker logs`.
            rm -f "$AGENT_SOCK" "$CLAUDE_SOCK" "$BROKER_PROFILE_D"
            log "Git SSH key broker  : ERROR, the ssh-agent/relay could not be established."
            log "Git SSH key broker  : ERROR, NOT falling back to a readable key file. git cannot authenticate with this deploy key for this boot."
            log "Git SSH key broker  : ERROR, set CLAUDE_BROKER_GIT_KEY=0 to accept an agent-readable key instead, then restart the container."
            log "Deploy key readable : NO. The agent user cannot read this deploy key's private bytes: brokering failed and no key file was installed, so git has no key to authenticate with."
        fi
    fi
    chown "$CLAUDE_UID:$CLAUDE_GID" "$CLAUDE_HOME/.ssh/config"
    chmod 600 "$CLAUDE_HOME/.ssh/config"
else
    log "No git SSH key mounted at $GITKEY_SRC (https/public repos still work)"
    log "Deploy key readable : n/a, no deploy key is mounted, so there is nothing to read."
fi

# Git identity: env vars win; otherwise inherit whatever the launcher passed
# from the host's git config. Applied to the claude user's global config.
git_id() {
    local k="$1" v="$2"
    [[ -n "$v" ]] && asclaude git config --global "$k" "$v" || true
}
git_id user.name  "${GIT_AUTHOR_NAME:-}"
git_id user.email "${GIT_AUTHOR_EMAIL:-}"
# safe.directory is multi-valued: `--add` every boot would append a duplicate
# line per restart. Add it only if it isn't already present.
asclaude git config --global --get-all safe.directory 2>/dev/null \
    | grep -qxF "$WORKSPACE" \
    || asclaude git config --global --add safe.directory "$WORKSPACE" || true
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

# Secret guard: a fleet-wide pre-commit hook (global core.hooksPath) that blocks
# committing obvious secrets/credentials: important because the agent commits
# and pushes autonomously with a mounted key and one shared credential volume.
# Disable with CLAUDE_SECRET_GUARD=0. The hook chains to a repo's own pre-commit.
HOOKS_DIR="$CLAUDE_HOME/.claude-hooks"
case "${CLAUDE_SECRET_GUARD:-1}" in
    0|false|no|off)
        asclaude git config --global --unset core.hooksPath 2>/dev/null || true
        log "Secret guard         : disabled (CLAUDE_SECRET_GUARD=0)" ;;
    *)
        asclaude mkdir -p "$HOOKS_DIR"
        ln -sf /usr/local/bin/claude-secret-guard "$HOOKS_DIR/pre-commit"
        chown -h "$CLAUDE_UID:$CLAUDE_GID" "$HOOKS_DIR/pre-commit" 2>/dev/null || true
        asclaude git config --global core.hooksPath "$HOOKS_DIR"
        log "Secret guard         : on (blocks committing secrets; bypass with git commit --no-verify)" ;;
esac

# GitHub HTTPS auth (dynamic, additive): when GH_TOKEN is supplied, wire the
# `gh` CLI in as git's credential helper for github.com so HTTPS clone/push
# also work with the token. SSH remotes keep using the mounted deploy key, so
# a session can use either transport. `gh auth setup-git` resets the helper
# before re-adding its own, so running it on every boot stays idempotent.
if [[ -n "${GH_TOKEN:-}" ]]; then
    if asclaude gh auth setup-git --hostname github.com >/dev/null 2>&1; then
        log "GH_TOKEN set: gh wired in as git credential helper (HTTPS + SSH both usable)"
    else
        log "WARNING: 'gh auth setup-git' failed; HTTPS git auth via GH_TOKEN unavailable"
    fi
else
    log "No GH_TOKEN: git uses the SSH deploy key only; gh CLI is unauthenticated"
fi

# --- 5a. Inner Docker daemon (CLAUDE_DOCKER=1, the :docker image variant) ------
# Gives the session a REAL Docker engine of its own, so the agent can build images and
# run containers (Dockerfiles, compose stacks, testcontainers) as part of normal work.
#
# The daemon runs INSIDE this container. It is never the host daemon: mounting the host's
# /var/run/docker.sock, or running --privileged, would each hand a prompt-injectable agent
# root on the host, and both stay FORBIDDEN. What makes an inner daemon safe *without*
# privilege is the runtime: under Sysbox (--runtime=sysbox-runc) this container's root is
# mapped into a user namespace onto an unprivileged host uid, so dockerd gets the caps it
# needs over its OWN namespace and none over the host. bin/claude-launch --docker selects it.
#
# NOTE: this deliberately INVERTS the retired worker-broker (docs/legacy-sysbox-broker.md),
# which chowned the socket to root and brokered every launch to keep the agent OFF the inner
# daemon. Here the agent using Docker IS the feature, so we put it in the `docker` group and
# hand it the socket. The honest consequence: socket access is a path to root INSIDE this
# container (`docker run -v /:/rootfs …`). Under Sysbox that root is still an unprivileged
# nobody on the host: the boundary that matters holds, but it does mean in-container
# controls that assume "root is separate from the agent" no longer bind. Two exist:
# CLAUDE_BROKER_GIT_KEY (§5, root-owned ssh-agent hiding the deploy key) and
# CLAUDE_EGRESS_LOCKDOWN (root-owned iptables). claude-launch warns when either is combined
# with --docker; see README "Container workflows" and docs/architecture.md.
if [[ "${CLAUDE_DOCKER:-0}" =~ ^(1|true|yes|on)$ ]]; then
    command -v dockerd >/dev/null 2>&1 \
        || die "CLAUDE_DOCKER=1 needs the Docker engine, but 'dockerd' is not in this image.
       Rebuild the docker variant:  make build-docker
         (or:  make build WITH_DOCKER=1 CLAUDE_IMAGE=<tag>, then set CLAUDE_IMAGE)
       and launch it with --docker (which selects --runtime=sysbox-runc)."

    # Let the unprivileged agent talk to the socket. dockerd creates /var/run/docker.sock as
    # root:docker 0660, so group membership is the whole mechanism. `groupadd -f` is a no-op
    # when the docker-ce postinst already made the group; usermod is idempotent.
    groupadd -f docker
    usermod -aG docker "$CLAUDE_USER"

    if docker info >/dev/null 2>&1; then
        log "Inner dockerd       : already reachable, reusing it (not starting a second daemon)"
    else
        DOCKERD_WAIT="${CLAUDE_DOCKERD_WAIT:-60}"
        # A POSITIVE integer with no leading zero: `(( … ))` reads a leading-zero value as
        # octal (090 → error, spins forever), and 0 would time out before dockerd could even
        # create its socket. Both are refused up front (fail closed, clear message).
        [[ "$DOCKERD_WAIT" =~ ^[1-9][0-9]*$ ]] \
            || die "CLAUDE_DOCKERD_WAIT '$DOCKERD_WAIT' is not a positive integer (no leading zero)"
        # Clear a stale pidfile an ungracefully-killed daemon left behind, so a container
        # restart (--restart unless-stopped) doesn't boot-loop on 'pidfile exists'.
        rm -f /run/docker.pid /var/run/docker.pid 2>/dev/null || true
        log "Inner dockerd       : starting (Sysbox-contained; log at /var/log/inner-dockerd.log)"
        dockerd >> /var/log/inner-dockerd.log 2>&1 &
        dwaited=0
        until docker info >/dev/null 2>&1; do
            if (( dwaited >= DOCKERD_WAIT )); then
                log "inner dockerd did not become ready within ${DOCKERD_WAIT}s: last log lines:"
                tail -n 20 /var/log/inner-dockerd.log 2>/dev/null | sed 's/^/    /' >&2 || true
                die "inner dockerd failed to start. The usual cause is a missing
       --runtime=sysbox-runc: without the user namespace Sysbox provides, an unprivileged
       container cannot run a Docker daemon. Check 'docker info | grep sysbox' on the HOST,
       and launch with --docker (claude-launch selects the runtime for you)."
            fi
            sleep 1; dwaited=$((dwaited + 1))
        done
        log "Inner dockerd       : ready after ${dwaited}s ($(docker --version 2>/dev/null))"
    fi
fi

# --- 6. Credentials reconcile (shared auth volume) ---------------------------
# Credentials are shared across all containers via the claude-auth volume; the
# rest of the config dir is per-container so sessions never collide. Claude
# rewrites .credentials.json on token refresh, so a small loop keeps the
# per-container file and the shared volume converged (newest wins).
if [[ ! -s "$AUTH_DIR/.credentials.json" ]]; then
    if [[ "${CLAUDE_SKIP_AUTH_CHECK:-0}" == "1" ]]; then
        log "WARNING: no credentials for the active account (auth check skipped)"
    elif [[ -n "${CLAUDE_ACCOUNTS:-}" ]]; then
        die "No credentials for account '$ACTIVE_ACCOUNT' (checked $AUTH_DIR/.credentials.json).
       Run 'claude-account-login $ACTIVE_ACCOUNT' once before launching containers."
    else
        die "No credentials in the claude-auth volume. Run 'make login' once
       before launching containers (see README Quick start)."
    fi
fi
if [[ -s "$AUTH_DIR/.credentials.json" && ! -s "$CLAUDE_CONFIG_DIR/.credentials.json" ]]; then
    install -o "$CLAUDE_UID" -g "$CLAUDE_GID" -m 600 \
        "$AUTH_DIR/.credentials.json" "$CLAUDE_CONFIG_DIR/.credentials.json"
fi
# Defense-in-depth: lock the SHARED fleet-wide credential master to root-only so
# a prompt-injected agent can't read or even list it. The agent keeps its OWN
# per-container session token ($CLAUDE_CONFIG_DIR/.credentials.json, claude:600,
# unavoidable: Claude Code authenticates with it), but cannot reach the master
# that backs every other container. `make login` (root-chowns /auth) is separate.
if [[ -n "${CLAUDE_ACCOUNTS:-}" ]]; then
    # Every account dir gets the same lockdown, not just the active one: the
    # agent must never read a not-currently-active account's credential either.
    for n in "${ACCOUNT_NAMES[@]}"; do
        d="/auth-accounts/$n"
        chown root:root "$d" 2>/dev/null || true
        chmod 700 "$d" 2>/dev/null || true
        [[ -e "$d/.credentials.json" ]] && { chown root:root "$d/.credentials.json" 2>/dev/null || true; chmod 600 "$d/.credentials.json" 2>/dev/null || true; }
    done
else
    chown root:root "$AUTH_DIR" 2>/dev/null || true
    chmod 700 "$AUTH_DIR" 2>/dev/null || true
    [[ -e "$AUTH_DIR/.credentials.json" ]] && { chown root:root "$AUTH_DIR/.credentials.json" 2>/dev/null || true; chmod 600 "$AUTH_DIR/.credentials.json" 2>/dev/null || true; }
fi

# A .credentials.json is USABLE only if it carries a non-empty OAuth access
# token. When a token refresh fails, Claude Code rewrites the file in place with
# EMPTY token fields (accessToken/refreshToken => ""): i.e. it logs the session
# out but leaves a well-formed, freshly-mtimed JSON behind. Without this guard
# the reconcile loop treated that tokenless file as the "newest wins" copy and
# published it to the shared /auth master and thence to every other container:
# turning one account's token expiry into a fleet-wide "Login expired" blackout
# (observed 2026-07-15). The guard makes the loop refuse to propagate a tokenless
# credential and instead REPAIR a tokenless/absent copy from whichever side still
# holds a real token, so a per-container logout self-heals from the good master
# and only a genuine refresh-token expiry (fixed by `make login`) can take auth
# down. See docs/troubleshooting.md.
creds_have_token() {  # creds_have_token <file>  -> 0 if it holds a non-empty access token
    [[ -s "$1" ]] && grep -q '"accessToken"[[:space:]]*:[[:space:]]*"[^"]' "$1"
}

# Publish SRC over DST atomically: a unique tmp in DST's own dir (so a shared
# /auth is never left with a half-written file, and no fixed tmp name can be
# picked up by a concurrent container), then rename. Ownership follows DST: the
# shared master stays root:600, the per-container copy claude:600.
publish_creds() {  # publish_creds <src> <dst>
    local src="$1" dst="$2" t
    t="$(mktemp "$dst.XXXXXX")" || return 1
    if [[ "$dst" == "$CLAUDE_CONFIG_DIR/.credentials.json" ]]; then
        { install -o "$CLAUDE_UID" -g "$CLAUDE_GID" -m 600 "$src" "$t" && mv -f "$t" "$dst"; } || { rm -f "$t"; return 1; }
    else
        { install -m 600 "$src" "$t" && mv -f "$t" "$dst"; } || { rm -f "$t"; return 1; }
    fi
}

reconcile_creds() {
    local b="$CLAUDE_CONFIG_DIR/.credentials.json"  # per-container copy (claude:600)
    while sleep 30; do
        # Re-derive the master path every tick (not just once) so a rotation
        # picked up mid-loop (bin/claude-usage-watchdog updates .active-account
        # via account_switch_listener below) keeps token-refresh write-back
        # flowing to whichever account is now active, not the one at boot.
        local a
        if [[ -n "${CLAUDE_ACCOUNTS:-}" ]]; then
            a="/auth-accounts/$(cat "$CLAUDE_CONFIG_DIR/.active-account" 2>/dev/null || echo "${ACCOUNT_NAMES[0]}")/.credentials.json"
        else
            a="$AUTH_DIR/.credentials.json"          # shared fleet master (root:600)
        fi
        if creds_have_token "$b" && ! creds_have_token "$a"; then
            # master absent/logged-out, local good -> seed or repair the master
            publish_creds "$b" "$a"
        elif creds_have_token "$a" && ! creds_have_token "$b"; then
            # local absent/logged-out, master good -> repair the local copy
            publish_creds "$a" "$b"
        elif creds_have_token "$b" && [[ "$b" -nt "$a" ]] && ! cmp -s "$b" "$a"; then
            # both good, local refreshed more recently -> push the refresh up
            publish_creds "$b" "$a"
        elif creds_have_token "$a" && [[ "$a" -nt "$b" ]] && ! cmp -s "$a" "$b"; then
            # both good, master refreshed more recently -> pull the refresh down
            publish_creds "$a" "$b"
        fi
        # both tokenless (a real refresh-token expiry): nothing to do, the loop
        # never invents a token; recovery is `make login` on the host.
    done
}
reconcile_creds &
RECONCILE_PID=$!

# --- 6a. Account-switch listener (multi-account mode only) -------------------
# bin/claude-usage-watchdog runs as the unprivileged `claude` user, so it
# cannot itself read a NON-active account's locked-down master (each
# /auth-accounts/<name> is root:700 / root:600, same lockdown as the
# single-account master above): it requests a swap here instead. Runs as
# root specifically so it CAN read every account, unlike the watchdog.
# Request/done files live inside $CLAUDE_CONFIG_DIR: root can read/write there
# regardless of its claude:700 ownership, so no separate shared directory or
# group permissions are needed.
account_switch_listener() {
    local req_file="$CLAUDE_CONFIG_DIR/.account-switch-request"
    local done_file="$CLAUDE_CONFIG_DIR/.account-switch-done"
    while sleep 2; do
        [[ -s "$req_file" ]] || continue
        local req; req="$(cat "$req_file" 2>/dev/null)"; rm -f "$req_file"
        # Validate against CLAUDE_ACCOUNTS before touching any path: an
        # unvalidated name interpolated into /auth-accounts/$req/... would be a
        # path-traversal risk if a request were ever forged.
        case ",${CLAUDE_ACCOUNTS}," in
            *",${req},"*) ;;
            *) echo "ERROR:unknown-account:$req" > "$done_file.tmp" && mv -f "$done_file.tmp" "$done_file"; continue ;;
        esac
        local src="/auth-accounts/$req/.credentials.json"
        if creds_have_token "$src"; then
            publish_creds "$src" "$CLAUDE_CONFIG_DIR/.credentials.json"
            echo "$req" > "$CLAUDE_CONFIG_DIR/.active-account.tmp" \
                && mv -f "$CLAUDE_CONFIG_DIR/.active-account.tmp" "$CLAUDE_CONFIG_DIR/.active-account"
            echo "$req" > "$done_file.tmp" && mv -f "$done_file.tmp" "$done_file"
        else
            echo "ERROR:no-token:$req" > "$done_file.tmp" && mv -f "$done_file.tmp" "$done_file"
        fi
    done
}
ACCT_SWITCH_PID=""
if [[ -n "${CLAUDE_ACCOUNTS:-}" ]]; then
    account_switch_listener &
    ACCT_SWITCH_PID=$!
fi

# --- 7. Seed .claude.json (onboarding + workspace trust) ---------------------
# With CLAUDE_CONFIG_DIR set, Claude stores .claude.json *inside* it. Pre-accept
# the workspace trust dialog and onboarding non-interactively, and lift the
# oauthAccount written by `make login` so the account shows correctly. Only
# fills missing keys, never clobbers existing per-container state.
CJSON="$CLAUDE_CONFIG_DIR/.claude.json"
[[ -s "$CJSON" ]] || echo '{}' > "$CJSON"
OAUTH_ACCOUNT='{}'
[[ -s "$AUTH_DIR/.claude.json" ]] && \
    OAUTH_ACCOUNT="$(jq -c '.oauthAccount // {}' "$AUTH_DIR/.claude.json" 2>/dev/null || echo '{}')"
jq --argjson oauth "$OAUTH_ACCOUNT" '
    .hasCompletedOnboarding = (.hasCompletedOnboarding // true)
  | .oauthAccount = (.oauthAccount // (if ($oauth|length>0) then $oauth else null end))
  | .projects = (.projects // {})
  | .projects["'"$WORKSPACE"'"] = ((.projects["'"$WORKSPACE"'"] // {}) + {
        hasTrustDialogAccepted: true,
        hasCompletedProjectOnboarding: true,
        hasClaudeMdExternalIncludesApproved: true,
        hasClaudeMdExternalIncludesWarningShown: true
    })
' "$CJSON" > "$CJSON.tmp" && mv -f "$CJSON.tmp" "$CJSON"
chown "$CLAUDE_UID:$CLAUDE_GID" "$CJSON"

# --- 7a. Managed settings: operator policy the session cannot rewrite --------
# WHY THIS EXISTS. Everything section 8b composes lands in
# $CLAUDE_CONFIG_DIR/settings.json, a file owned by the agent user on a
# per-project volume that outlives the container, merged so that the EXISTING
# file wins on conflict. The process being policed therefore owns the file the
# policy is written in, which for an image whose premise is an unattended agent
# running with --dangerously-skip-permissions is the wrong owner. Claude Code
# reads /etc/claude-code/managed-settings.json on Linux ABOVE every other
# settings level, including ~/.claude and a project's .claude/
# (https://code.claude.com/docs/en/managed-settings), and root owns /etc.
# Writing the policy there, as root, before the agent process starts, is what
# makes an operator's choice survive a session that rewrites its own settings.
#
# ADDITIVE, NEVER A REPLACEMENT. Section 8b still runs and still writes every one
# of these keys into settings.json, so a container whose managed file is missing
# or unparseable behaves exactly as it did before this block existed. Nothing
# here can subtract from that; the worst case is a boot log saying policy is NOT
# enforced and a container that behaves as it always has.
#
# WHAT IS POLICY AND WHAT IS A PREFERENCE. Only settings whose loss changes what
# the container IS are delivered here:
#   permissions.defaultMode            the containment posture the operator chose
#   skipDangerousModePermissionPrompt  meaningless apart from the mode above
#   env.DISABLE_AUTOUPDATER            a session that self-updates leaves the
#                                      pinned CLI this image verifies its flags
#                                      against, so the pin stops meaning anything
# includeCoAuthoredBy is deliberately NOT here. It is a commit-message
# preference: nothing about the container depends on it, and a session that
# wants it off should be free to turn it off. Section 8b still sets it.
# The telemetry kills stay out of BOTH files for the reason in 8b's own note.
#
# NOT SET, DELIBERATELY: permissions.disableBypassPermissionsMode. This path is
# where an operator turns --dangerously-skip-permissions off outright, and the
# vendor documents it as a managed-only key. Which posture a fleet runs is the
# operator's call, not this image's; see docs/managed-settings.md for how to make
# it from the host. This block only makes such a call enforceable.
#
# NEVER FATAL. Every failure below is a log line and a boot that carries on to
# the agent, because a container that refused to start over a policy file it
# could not write would be a worse regression than the gap it closes. The hard
# rule is that the log tells the truth in BOTH directions: a container that could
# not enforce policy must never print a line that reads as if it did, and a
# container where a managed file IS in force must never print a line denying it,
# whoever put that file there and whatever this image did or did not deliver.
MANAGED_DIR="/etc/claude-code"
MANAGED_STAMP="/etc/claude-code-image-policy.sha256"
MANAGED_FILE="$MANAGED_DIR/managed-settings.json"
MANAGED_PERM_MODE="${CLAUDE_PERMISSION_MODE:-bypassPermissions}"
managed_ok=0          # 1 only when a policy file is really in force
managed_why=""        # why it is not, when it is not
managed_est_why=""    # why THIS IMAGE delivered no policy set of its own, if it did not
managed_source=""     # image | operator
managed_names=""      # the dotted paths the file delivers
managed_mode=""       # the file's octal mode, as verified below
managed_dmode=""      # the directory's octal mode, as verified below
managed_owner_uid="$(id -u)"   # the uid this entrypoint runs as: root, in this image

# The image's own policy set. jq builds it because a printf template would emit
# invalid JSON for an exotic CLAUDE_PERMISSION_MODE and the CLI would then drop
# the whole file, silently, with no policy in force and a happy-looking log.
MANAGED_POLICY="$(jq -n --arg pm "$MANAGED_PERM_MODE" '{
    permissions: { defaultMode: $pm },
    skipDangerousModePermissionPrompt: true,
    env: { DISABLE_AUTOUPDATER: "1" }
}' 2>/dev/null)" || MANAGED_POLICY=""

# True when $MANAGED_FILE is byte-for-byte the file THIS image last wrote. The
# stamp is what separates "our file, refresh it so a changed
# CLAUDE_PERMISSION_MODE takes effect on the next boot" from "the operator put
# this here, never touch it". Without it the second boot of a container would
# keep the first boot's policy for ever, and a mounted host policy would be
# overwritten by the image on start, which is the opposite of the point.
managed_is_ours() {
    local now stamped
    [[ -s "$MANAGED_STAMP" && -f "$MANAGED_FILE" ]] || return 1
    now="$(sha256sum < "$MANAGED_FILE" 2>/dev/null | cut -d' ' -f1)" || return 1
    stamped="$(cat "$MANAGED_STAMP" 2>/dev/null)" || return 1
    [[ -n "$now" && "$now" == "$stamped" ]]
}

# The dotted path of every setting a managed file delivers. NAMES ONLY, never
# values: an operator's own managed file can legitimately carry a token under
# .env, and this line goes into a boot log that anyone who can run `claude-logs`
# can read.
managed_keys() {
    jq -r '[paths(scalars) | map(tostring) | join(".")] | join(", ")' "$1" 2>/dev/null
}

if [[ -n "${CLAUDE_MANAGED_POLICY:-}" ]] \
   && [[ ! "${CLAUDE_MANAGED_POLICY}" =~ ^(0|false|no|off|1|true|yes|on)$ ]]; then
    # A typo must never read as a deliberate off (the lesson §12a records). The
    # safe direction is taken automatically here, so this only reports it.
    log "Managed policy       : NOTE, CLAUDE_MANAGED_POLICY='${CLAUDE_MANAGED_POLICY}' is not a recognised value, so policy was left ON (recognised: 0/false/no/off = off, 1/true/yes/on = on)"
fi

# STAGE 1: DELIVERY. Whether this image writes its own policy set this boot.
# Every branch that writes nothing records WHY it wrote nothing and stops there,
# because "this image delivered no policy" is not the same statement as "no
# policy is in force": an operator's own file can already be sitting at the
# vendor path, where the CLI reads it regardless. Stage 2 has the last word on
# what is enforced, and it looks at the disk.
if [[ "${CLAUDE_MANAGED_POLICY:-1}" =~ ^(0|false|no|off)$ ]]; then
    # The operator's escape hatch, from the host, for the risk this block
    # introduces: a setting that is genuinely not overridable from inside is also
    # no longer loosenable by a session that needs it loosened. It stops this
    # image DELIVERING policy. It cannot unsay a file that is already at the
    # vendor path, so it must not suppress the verification below either.
    managed_est_why="CLAUDE_MANAGED_POLICY=${CLAUDE_MANAGED_POLICY} turned it off, so this image established no managed settings file"
elif [[ -z "$MANAGED_POLICY" ]]; then
    managed_est_why="the image's own policy set could not be composed (jq failed for CLAUDE_PERMISSION_MODE='$MANAGED_PERM_MODE')"
elif [[ -e "$MANAGED_FILE" ]] && ! managed_is_ours; then
    # An operator delivered this file from the host: a bind mount, a derived
    # image, a docker cp. It is theirs. Never overwritten, never chmod'd, never
    # merged into. The image's own defaults still reach the session through §8b.
    managed_source="operator"
else
    managed_source="image"
    if ! mkdir -p "$MANAGED_DIR" 2>/dev/null; then
        managed_est_why="the directory $MANAGED_DIR could not be created (a read-only filesystem?)"
    elif ! chmod 755 "$MANAGED_DIR" 2>/dev/null; then
        managed_est_why="the directory $MANAGED_DIR could not be set to mode 755, so it may be writable by a non-root process"
    elif ! printf '%s\n' "$MANAGED_POLICY" > "$MANAGED_FILE.tmp" 2>/dev/null; then
        managed_est_why="$MANAGED_FILE.tmp could not be written (is $MANAGED_DIR read-only?)"
        rm -f "$MANAGED_FILE.tmp" 2>/dev/null || true
    elif ! chmod 644 "$MANAGED_FILE.tmp" 2>/dev/null; then
        managed_est_why="the mode of the new policy file could not be set to 644"
        rm -f "$MANAGED_FILE.tmp" 2>/dev/null || true
    elif ! mv -f "$MANAGED_FILE.tmp" "$MANAGED_FILE" 2>/dev/null; then
        # Composed into a temp file and moved into place, so a failure anywhere
        # above leaves the previous file intact instead of a truncated one that
        # the next boot would report as unparseable.
        managed_est_why="$MANAGED_FILE could not be replaced (it may be mounted read-only from the host)"
        rm -f "$MANAGED_FILE.tmp" 2>/dev/null || true
    fi
fi

# Whose file is at the vendor path, when this image did not put one there this
# boot. The stamp is the only thing that can tell a file this image wrote from
# one the operator delivered, and the log names the source either way.
if [[ -z "$managed_source" && -e "$MANAGED_FILE" ]]; then
    if managed_is_ours; then managed_source="image"; else managed_source="operator"; fi
fi

# STAGE 2: VERIFICATION, and it runs on every boot. The claim the log makes is
# about the file Claude Code will actually read at the top of its hierarchy, not
# about the code path that produced it, so what is on disk is what gets checked
# even when stage 1 delivered nothing. An operator who mounts their own policy
# file and ALSO turns this image's delivery off still has that file in force, and
# a boot that skipped this pass would print a denial of an enforcement that is
# really there. `-O` is "owned by the effective uid", and this entrypoint is root
# here, so it is the root-owned test; the agent-uid and mode checks are what make
# "not writable from inside" more than a hope.
if [[ ! -e "$MANAGED_FILE" ]]; then
    # Nothing at the path at all: stage 1's own reason is the honest one, because
    # it says why this image put nothing there.
    managed_why="${managed_est_why:-no file is present at $MANAGED_FILE}"
elif [[ ! -f "$MANAGED_FILE" ]]; then
    managed_why="$MANAGED_FILE is not a regular file, so nothing there can be read as policy"
elif ! jq -e . "$MANAGED_FILE" >/dev/null 2>&1; then
    managed_why="the file at $MANAGED_FILE is UNREADABLE as policy: it is not parseable as JSON, so it was left exactly as it is and none of its settings are enforced"
elif [[ ! -O "$MANAGED_FILE" ]]; then
    managed_why="$MANAGED_FILE is not owned by this container's root (uid $managed_owner_uid), so root does not control it"
elif [[ "$(stat -c %u "$MANAGED_FILE" 2>/dev/null)" == "$CLAUDE_UID" ]]; then
    managed_why="$MANAGED_FILE is owned by the agent user $CLAUDE_USER (uid $CLAUDE_UID), which could then rewrite it"
else
    managed_mode="$(stat -c %a "$MANAGED_FILE" 2>/dev/null || true)"
    managed_dmode="$(stat -c %a "$MANAGED_DIR" 2>/dev/null || true)"
    if [[ -z "$managed_mode" || -z "$managed_dmode" ]]; then
        managed_why="the mode of $MANAGED_FILE or of $MANAGED_DIR could not be read"
    elif (( (8#$managed_mode & 8#22) != 0 )); then
        managed_why="$MANAGED_FILE is mode $managed_mode, which grants write to group or other, so a non-root process could rewrite it"
    elif (( (8#$managed_dmode & 8#22) != 0 )); then
        # A 644 root-owned file inside a group-writable directory is not
        # protected: the agent cannot write the file, it just unlinks it and
        # puts its own there instead.
        managed_why="$MANAGED_DIR is mode $managed_dmode, which grants write to group or other, so a non-root process could unlink the policy file and put its own in its place"
    elif [[ ! -O "$MANAGED_DIR" ]]; then
        managed_why="$MANAGED_DIR is not owned by this container's root (uid $managed_owner_uid), so a non-root process could replace the policy file"
    else
        managed_names="$(managed_keys "$MANAGED_FILE")" || managed_names=""
        if [[ -z "$managed_names" ]]; then
            managed_why="$MANAGED_FILE carries no settings at all, so there is no policy in force"
        else
            managed_ok=1
        fi
    fi
fi

# Stamp only what this image itself wrote: a file it merely found is the
# operator's, and stamping it would make the next boot overwrite their policy.
if (( managed_ok == 1 )) && [[ "$managed_source" == "image" && -z "$managed_est_why" ]]; then
    managed_sha="$(sha256sum < "$MANAGED_FILE" 2>/dev/null | cut -d' ' -f1 || true)"
    if [[ -n "$managed_sha" ]] && printf '%s\n' "$managed_sha" > "$MANAGED_STAMP" 2>/dev/null; then
        chmod 600 "$MANAGED_STAMP" 2>/dev/null || true
    else
        log "Managed policy       : NOTE, the stamp $MANAGED_STAMP could not be written, so a later boot will read this file as operator-supplied and leave it alone (a changed CLAUDE_PERMISSION_MODE would not take effect until the file is removed)"
    fi
fi

if (( managed_ok == 1 )); then
    # "owned by uid N", not "owned by root": N is what the -O test above actually
    # compared against, and it is 0 in this image.
    log "Managed policy       : ENFORCED from $MANAGED_FILE ($managed_source-supplied, owned by uid $managed_owner_uid and not by the agent user $CLAUDE_USER (uid $CLAUDE_UID), file mode $managed_mode in a mode-$managed_dmode directory, not writable by $CLAUDE_USER). Managed settings, NOT overridable from inside the container: $managed_names"
    if [[ -n "$managed_est_why" ]]; then
        # Policy is in force that this boot did not deliver. ENFORCED alone would
        # leave an operator who reached for the escape hatch wondering why their
        # settings are still managed; NOT ENFORCED alone would be exactly the
        # denial of a live enforcement this pairing exists to prevent.
        log "Managed policy       : NOTE, $managed_est_why, but a managed file was ALREADY at $MANAGED_FILE and Claude Code reads it above every other settings level, so the settings named above ARE in force and are not overridable from inside this container. Only the host can change that: remove or replace that file, drop the mount that supplies it, or start a fresh container from this image."
    fi
else
    log "Managed policy       : NOT ENFORCED ($managed_why). NO setting is managed: everything stays overridable from inside the container, exactly as it was before this image delivered any policy."
fi
if [[ "${CLAUDE_DOCKER:-0}" =~ ^(1|true|yes|on)$ ]]; then
    # Same caveat CLAUDE_BROKER_GIT_KEY and CLAUDE_EGRESS_LOCKDOWN carry: an inner
    # daemon hands the session a route to root inside its own container.
    log "Managed policy       : NOTE, this container runs an inner Docker daemon (CLAUDE_DOCKER), which gives the session a route to root inside the container. A session that takes it CAN rewrite $MANAGED_FILE, so read the line above as advisory here, not as containment."
fi

# --- 8. Merge baked-in config ------------------------------------------------
# Everything baked into the image is overridable at runtime by mounting onto
# the target path (we only fill what's absent).

# 8a. Global CLAUDE.md
if [[ -f "$BAKE_DIR/CLAUDE.md" && ! -e "$CLAUDE_CONFIG_DIR/CLAUDE.md" ]]; then
    install -o "$CLAUDE_UID" -g "$CLAUDE_GID" -m 644 \
        "$BAKE_DIR/CLAUDE.md" "$CLAUDE_CONFIG_DIR/CLAUDE.md"
    log "Installed global CLAUDE.md"
fi

# 8b. settings.json: baked file is the base, existing user settings win on
#     conflict (recursive merge). Also injects unattended-operation defaults.
#     NOTE: env intentionally does NOT include DISABLE_TELEMETRY/DO_NOT_TRACK.
#     Those (and CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC) make Claude Code skip
#     the GrowthBook fetch, so the `tengu_ccr_bridge` gate defaults false and
#     Remote Control reports "not yet enabled for your account". RC is the point
#     of this image, so they must never be set. See docs/troubleshooting.md.
PERM_MODE="${CLAUDE_PERMISSION_MODE:-bypassPermissions}"
BASE_SETTINGS="$(jq -n --arg pm "$PERM_MODE" '{
    permissions: { defaultMode: $pm },
    skipDangerousModePermissionPrompt: true,
    includeCoAuthoredBy: true,
    env: { DISABLE_AUTOUPDATER: "1" }
}')"
[[ -f "$BAKE_DIR/settings.json" ]] && \
    BASE_SETTINGS="$(jq -s '.[0] * .[1]' <(echo "$BASE_SETTINGS") "$BAKE_DIR/settings.json")"
EXISTING_SETTINGS='{}'
[[ -s "$CLAUDE_CONFIG_DIR/settings.json" ]] && \
    EXISTING_SETTINGS="$(cat "$CLAUDE_CONFIG_DIR/settings.json")"
# Self-heal 1: strip the Remote-Control-breaking telemetry kills from the final
# settings (covers per-container volumes created by an older image). If any
# were present, drop the cached GrowthBook flags + statsig cache so the next
# Claude run re-fetches them and RC eligibility resolves correctly.
#
# Self-heal 2: drop the stale `claude-md-fragments` SessionStart hook.
# Older images baked a settings.json whose only content was a
# SessionStart hook invoking /usr/local/bin/claude-md-fragments (the CLAUDE.d
# per-mode fragment loader). That binary was deleted, but the hook was already
# persisted into every per-project config VOLUME, and this merge lets existing
# user settings win, so it would survive forever and fire an ENOENT at every
# session start. Same class of residue, same fix, as the telemetry strip above.
STALE_HOOK_CMD="/usr/local/bin/claude-md-fragments"
jq -s '.[0] * .[1]' <(echo "$BASE_SETTINGS") <(echo "$EXISTING_SETTINGS") \
    | jq 'if .env then .env |= (del(.DISABLE_TELEMETRY,.DO_NOT_TRACK,.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC)) else . end' \
    | jq --arg stale "$STALE_HOOK_CMD" '
        # Type-guard every level: a hand-corrupted settings.json (.hooks a string,
        # a SessionStart group that is not an object, ...) must pass through untouched
        # rather than error: a jq failure here would leave the `>` redirect below
        # having truncated settings.json to 0 bytes.
        (if (.hooks | type) == "object" and (.hooks.SessionStart | type) == "array" then
             .hooks.SessionStart |= (
                 map(if type == "object" and ((.hooks | type) == "array")
                     then .hooks |= map(select((.command? // "") != $stale))
                     else . end)
                 | map(select((type != "object")
                              or ((.hooks | type) != "array")
                              or ((.hooks | length) > 0)))
             )
         else . end)
        | (if (.hooks | type) == "object" and (.hooks.SessionStart | type) == "array"
              and ((.hooks.SessionStart | length) == 0)
           then del(.hooks.SessionStart) else . end)
        | (if (.hooks | type) == "object" and ((.hooks | length) == 0)
           then del(.hooks) else . end)' \
    > "$CLAUDE_CONFIG_DIR/settings.json"
if echo "$EXISTING_SETTINGS" \
    | jq -e --arg stale "$STALE_HOOK_CMD" \
        '[.hooks.SessionStart // [] | .[] | .hooks // [] | .[] | select((.command // "") == $stale)] | length > 0' \
        >/dev/null 2>&1; then
    log "Migrated settings.json: removed the stale '$STALE_HOOK_CMD' SessionStart hook (CLAUDE.d fragment loader, since removed)"
fi
chown "$CLAUDE_UID:$CLAUDE_GID" "$CLAUDE_CONFIG_DIR/settings.json"
if echo "$EXISTING_SETTINGS" | jq -e '.env // {} | (.DISABLE_TELEMETRY // .DO_NOT_TRACK // .CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC) != null' >/dev/null 2>&1; then
    log "Migrated settings.json: removed telemetry kills that block Remote Control; clearing stale feature-flag cache"
    [[ -s "$CJSON" ]] && jq 'del(.cachedGrowthBookFeatures,.cachedExperimentFeatures)' "$CJSON" > "$CJSON.tmp" \
        && mv -f "$CJSON.tmp" "$CJSON" && chown "$CLAUDE_UID:$CLAUDE_GID" "$CJSON"
    rm -rf "$CLAUDE_CONFIG_DIR/statsig" 2>/dev/null || true
fi

# 8c. Plugins: declarative. Claude Code installs/syncs the marketplaces and
#     enabled plugins from settings.json on startup (idempotent). We union the
#     two plugin keys into existing settings; existing entries win on conflict.
if [[ -f "$BAKE_DIR/plugins/plugins.json" ]]; then
    jq -s '
        .[0] as $cur | .[1] as $plug |
        $cur
        | .extraKnownMarketplaces = (($plug.extraKnownMarketplaces // {}) + ($cur.extraKnownMarketplaces // {}))
        | .enabledPlugins         = (($plug.enabledPlugins // {})         + ($cur.enabledPlugins // {}))
    ' "$CLAUDE_CONFIG_DIR/settings.json" "$BAKE_DIR/plugins/plugins.json" \
        > "$CLAUDE_CONFIG_DIR/settings.json.tmp" \
        && mv -f "$CLAUDE_CONFIG_DIR/settings.json.tmp" "$CLAUDE_CONFIG_DIR/settings.json"
    chown "$CLAUDE_UID:$CLAUDE_GID" "$CLAUDE_CONFIG_DIR/settings.json"
    log "Merged baked-in plugin marketplaces/plugins into settings.json"
fi

# 8c-bis. Runtime plugin injection: no rebuild required.
# CLAUDE_EXTRA_MARKETPLACES: "name=url[,name=url,...]"  (git source, autoUpdate=true)
# CLAUDE_EXTRA_PLUGINS:      "plugin@marketplace[,...]"
# Existing settings.json entries always win (same semantics as the baked merge above).
if [[ -n "${CLAUDE_EXTRA_MARKETPLACES:-}" ]] || [[ -n "${CLAUDE_EXTRA_PLUGINS:-}" ]]; then
    MKT_JSON="{}"
    if [[ -n "${CLAUDE_EXTRA_MARKETPLACES:-}" ]]; then
        IFS=',' read -ra _MKT_ENTRIES <<< "$CLAUDE_EXTRA_MARKETPLACES"
        for _entry in "${_MKT_ENTRIES[@]}"; do
            _name="${_entry%%=*}"; _url="${_entry#*=}"
            [[ -n "$_name" && -n "$_url" && "$_name" != "$_url" ]] || continue
            MKT_JSON="$(jq --arg n "$_name" --arg u "$_url" \
                '. + {($n): {"source": {"source": "git", "url": $u}, "autoUpdate": true}}' \
                <<< "$MKT_JSON")"
        done
    fi
    PLG_JSON="{}"
    if [[ -n "${CLAUDE_EXTRA_PLUGINS:-}" ]]; then
        IFS=',' read -ra _PLG_ENTRIES <<< "$CLAUDE_EXTRA_PLUGINS"
        for _entry in "${_PLG_ENTRIES[@]}"; do
            [[ -n "$_entry" ]] || continue
            PLG_JSON="$(jq --arg p "$_entry" '. + {($p): true}' <<< "$PLG_JSON")"
        done
    fi
    jq --argjson mkt "$MKT_JSON" --argjson plg "$PLG_JSON" '
        .extraKnownMarketplaces = ($mkt + (.extraKnownMarketplaces // {}))
        | .enabledPlugins       = ($plg + (.enabledPlugins // {}))
    ' "$CLAUDE_CONFIG_DIR/settings.json" \
        > "$CLAUDE_CONFIG_DIR/settings.json.tmp" \
        && mv -f "$CLAUDE_CONFIG_DIR/settings.json.tmp" "$CLAUDE_CONFIG_DIR/settings.json"
    chown "$CLAUDE_UID:$CLAUDE_GID" "$CLAUDE_CONFIG_DIR/settings.json"
    log "Merged runtime plugin marketplaces/plugins into settings.json"
fi

# 8d. Custom slash commands
if compgen -G "$BAKE_DIR/commands/*.md" > /dev/null; then
    install -d -o "$CLAUDE_UID" -g "$CLAUDE_GID" "$CLAUDE_CONFIG_DIR/commands"
    for f in "$BAKE_DIR"/commands/*.md; do
        t="$CLAUDE_CONFIG_DIR/commands/$(basename "$f")"
        [[ -e "$t" ]] || install -o "$CLAUDE_UID" -g "$CLAUDE_GID" -m 644 "$f" "$t"
    done
    log "Installed baked-in slash commands"
fi

# 8e. Skills (one directory per skill, must contain SKILL.md)
if [[ -d "$BAKE_DIR/skills" ]]; then
    install -d -o "$CLAUDE_UID" -g "$CLAUDE_GID" "$CLAUDE_CONFIG_DIR/skills"
    for d in "$BAKE_DIR"/skills/*/; do
        [[ -f "$d/SKILL.md" ]] || continue
        name="$(basename "$d")"
        if [[ ! -d "$CLAUDE_CONFIG_DIR/skills/$name" ]]; then
            cp -a "$d" "$CLAUDE_CONFIG_DIR/skills/$name"
            chown -R "$CLAUDE_UID:$CLAUDE_GID" "$CLAUDE_CONFIG_DIR/skills/$name"
        fi
    done
    log "Installed baked-in skills"
fi

# --- 9. Workspace ------------------------------------------------------------
# A bind mount or pre-populated volume wins; otherwise clone GIT_REPO_URL.
shopt -s nullglob dotglob
ws_entries=("$WORKSPACE"/*)
shopt -u nullglob dotglob
ws_populated=0
if (( ${#ws_entries[@]} )); then
    for e in "${ws_entries[@]}"; do
        [[ "$(basename "$e")" == "lost+found" ]] && continue
        ws_populated=1; break
    done
fi

if [[ "$ws_populated" == "1" ]]; then
    log "Using existing workspace contents at $WORKSPACE"
elif [[ -n "${GIT_REPO_URL:-}" ]]; then
    log "Cloning $GIT_REPO_URL into $WORKSPACE"
    clone_args=()
    [[ -n "${GIT_REPO_BRANCH:-}" ]] && clone_args+=(--branch "$GIT_REPO_BRANCH")
    [[ -n "${GIT_REPO_DEPTH:-}"  ]] && clone_args+=(--depth "$GIT_REPO_DEPTH")
    asclaude git clone "${clone_args[@]}" "$GIT_REPO_URL" "$WORKSPACE" \
        || die "git clone failed (check GIT_REPO_URL / git SSH key / branch)"
else
    die "Empty workspace and no GIT_REPO_URL. Set GIT_REPO_URL or bind-mount a
       checkout onto $WORKSPACE (use 'claude-launch --repo' or --workspace)."
fi
chown -R "$CLAUDE_UID:$CLAUDE_GID" "$WORKSPACE" 2>/dev/null || true

# --- 10. Register baked-in MCP servers ---------------------------------------
# Done via the CLI so the on-disk schema is always correct for this Claude
# version. ${VARS} in the JSON are expanded from runtime env (secrets are
# never baked into the image). CLAUDE_MCP_ENABLED (csv) filters which to load.
if [[ -d "$BAKE_DIR/mcp" ]]; then
    for f in "$BAKE_DIR"/mcp/*.json; do
        [[ -e "$f" ]] || continue
        name="$(basename "$f" .json)"
        if [[ -n "${CLAUDE_MCP_ENABLED:-}" ]]; then
            case ",${CLAUDE_MCP_ENABLED}," in *",$name,"*) ;; *) continue ;; esac
        fi
        if asclaude claude mcp get "$name" >/dev/null 2>&1; then
            log "MCP '$name' already configured, skipping"
            continue
        fi
        json="$(envsubst < "$f")"
        if asclaude claude mcp add-json --scope user "$name" "$json" >/dev/null 2>&1; then
            log "Registered MCP server '$name'"
        else
            log "WARNING: failed to register MCP server '$name'"
        fi
    done
fi

# --- 10b. Register chrome-devtools-mcp (frontend debugging) ------------------
# Registers the Chrome DevTools MCP server so Claude can navigate, evaluate,
# inspect console/network, take screenshots, run Lighthouse, etc. against any
# frontend the agent spins up in /workspace.
#
# CLAUDE_BROWSER is TRI-STATE: the browser image is meant to "just work", so a
# baked variant auto-enables the MCP with no second flag:
#   • unset / empty / other  → AUTO: register iff the browser variant is baked
#     (both chrome-devtools-mcp AND chromium on PATH, the functional signal a
#     registration actually needs; the image also carries a `claude.browser`
#     LABEL the launcher pre-flight reads). A lean image stays silent.
#   • 1|true|yes|on          → FORCE ON: register; if the binaries are NOT baked,
#     fail LOUD + actionable (rebuild hint), never a silent no-op.
#   • 0|false|no|off         → OPT OUT: skip even on a browser image.
# Registration is idempotent (the `claude mcp get` guard below), so re-runs and
# a resumed session never double-register. Headless, isolated profile (clean per
# session); --no-sandbox is required in unprivileged Docker.
#
# The --chromeArg flags below need chrome-devtools-mcp >=1.0 (the Dockerfile pin
# asserts this at build time). On 0.x they were silently dropped by yargs, Chrome
# exited with "No usable sandbox!", and every tool call failed "Target closed".
# --no-usage-statistics opts out of the telemetry 1.x sends to Google by default.
_browser_baked() {
    command -v chrome-devtools-mcp >/dev/null 2>&1 && command -v chromium >/dev/null 2>&1
}
_register_chrome_devtools_mcp() {
    if asclaude claude mcp get chrome-devtools >/dev/null 2>&1; then
        log "MCP 'chrome-devtools' already configured, skipping"
        return 0
    fi
    # Resolve the SAME chromium the detection probe found, rather than hardcoding
    # /usr/bin/chromium, so a variant that installs chromium elsewhere (or as a
    # differently-named binary on PATH) can't auto-register a config that then
    # points at a missing executable. Fall back to /usr/bin/chromium if unresolved.
    local chromium_path cdt_json
    chromium_path="$(command -v chromium 2>/dev/null || echo /usr/bin/chromium)"
    cdt_json="$(jq -n --arg exe "$chromium_path" '{
        type: "stdio",
        command: "chrome-devtools-mcp",
        args: [
            "--executablePath", $exe,
            "--headless",
            "--isolated",
            "--chromeArg=--no-sandbox",
            "--chromeArg=--disable-dev-shm-usage",
            "--chromeArg=--disable-gpu",
            "--no-usage-statistics"
        ],
        env: { CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS: "1" }
    }')"
    if asclaude claude mcp add-json --scope user chrome-devtools "$cdt_json" >/dev/null 2>&1; then
        log "Registered MCP server 'chrome-devtools' (headless Chromium)"
    else
        log "WARNING: failed to register chrome-devtools MCP"
    fi
}
# Normalize: strip surrounding whitespace / a trailing CR (a CRLF-authored .env
# yields `1\r`, which must still match "1", not silently fall through to auto)
# and lowercase, so the tri-state match is robust to how the value was set.
_cb="$(printf '%s' "${CLAUDE_BROWSER:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
case "$_cb" in
    1|true|yes|on)
        # Explicit request: must be satisfiable, else fail loud (never silent).
        if _browser_baked; then
            _register_chrome_devtools_mcp
        else
            log "ERROR: CLAUDE_BROWSER=1 (or --browser) requested, but this image has no"
            log "       chrome-devtools-mcp / chromium baked in: the MCP cannot be enabled."
            log "       Rebuild the browser variant:  make build-browser"
            log "       (or:  make build WITH_BROWSER=1 CLAUDE_IMAGE=<tag>)."
            log "       Frontend debugging is UNAVAILABLE in this container until you do."
        fi
        ;;
    0|false|no|off)
        # Explicit opt-out: honored even on a browser image.
        _browser_baked && log "chrome-devtools MCP disabled (CLAUDE_BROWSER=off); skipping"
        ;;
    *)
        # Auto: a browser image enables the MCP by itself; a lean image is silent.
        if _browser_baked; then
            log "Browser image detected (chromium + chrome-devtools-mcp present): auto-registering chrome-devtools MCP"
            _register_chrome_devtools_mcp
        fi
        ;;
esac

# --- 11. Start sshd ----------------------------------------------------------
/usr/sbin/sshd -e
log "sshd listening on container port 22"

# --- 12. Launch Claude Code in a persistent tmux session --------------------
CLAUDE_PROJECT_NAME="${CLAUDE_PROJECT_NAME:-claude}"
# RC debug log path: claude-session writes Remote Control events here; the
# watchdog and the Docker healthcheck read it. Exported so the tmux server (and
# anything respawned in it) inherits it; CLAUDE_RC_DEBUG_LOG is also a baked ENV
# so the healthcheck, a separate process spawned by dockerd, sees it too.
export CLAUDE_RC_DEBUG_LOG="${CLAUDE_RC_DEBUG_LOG-/tmp/claude-rc-debug.log}"
export CLAUDE_PROJECT_NAME CLAUDE_EXTRA_ARGS="${CLAUDE_EXTRA_ARGS:-}" \
       CLAUDE_DEV_CMD="${CLAUDE_DEV_CMD:-}"

# Model selection: default to the best available model. The `opus` alias always
# resolves to the latest Opus, so the fleet tracks the strongest model without a
# code change when a newer one ships. Override per-container with CLAUDE_MODEL:
# any Claude Code alias (opus, sonnet, haiku, opusplan, default) or a full model
# id (e.g. claude-opus-4-8). Both the interactive session and the autopilot loop
# read it and pass `--model`. To defer to Claude Code's own default, set
# CLAUDE_MODEL=default (empty/unset falls back to opus, the best available).
export CLAUDE_MODEL="${CLAUDE_MODEL:-opus}"
log "Model               : $CLAUDE_MODEL (override with CLAUDE_MODEL; 'default' = Claude Code's pick)"

# Two modes:
#   interactive (default): main pane is claude-session (Remote Control + SSH).
#   autopilot (CLAUDE_AUTOPILOT=1): main pane is claude-autopilot, a headless Claude
#                           loop running CLAUDE_AUTOPILOT_CMD for unattended build-out;
#                           there is no Remote Control link, so the RC watchdog is
#                           skipped.
# Either way SSH attaches to the live tmux pane. The third mode, CLAUDE_CONTROLLER, was
# removed and is refused up in §0b: long before we get here.
case "${CLAUDE_AUTOPILOT:-0}" in
    1|true|yes|on) CLAUDE_MODE=autopilot;   MAIN_PANE_CMD=/usr/local/bin/claude-autopilot ;;
    *)             CLAUDE_MODE=interactive; MAIN_PANE_CMD=/usr/local/bin/claude-session ;;
esac
export CLAUDE_MODE \
       CLAUDE_AUTOPILOT_CMD="${CLAUDE_AUTOPILOT_CMD:-}" \
       CLAUDE_AUTOPILOT_INTERVAL="${CLAUDE_AUTOPILOT_INTERVAL:-}" \
       CLAUDE_AUTOPILOT_MAX_RUNS="${CLAUDE_AUTOPILOT_MAX_RUNS:-}" \
       CLAUDE_AUTOPILOT_BACKOFF_MAX="${CLAUDE_AUTOPILOT_BACKOFF_MAX:-}" \
       CLAUDE_AUTOPILOT_LOG_DIR="${CLAUDE_AUTOPILOT_LOG_DIR:-}" \
       CLAUDE_AUTOPILOT_RESUME="${CLAUDE_AUTOPILOT_RESUME:-}" \
       CLAUDE_AUTOPILOT_QUEUE="${CLAUDE_AUTOPILOT_QUEUE:-}" \
       CLAUDE_AUTOPILOT_QUEUE_DIR="${CLAUDE_AUTOPILOT_QUEUE_DIR:-}" \
       CLAUDE_AUTOPILOT_QUEUE_DELAY="${CLAUDE_AUTOPILOT_QUEUE_DELAY:-}" \
       CLAUDE_SCM_OBSERVER="${CLAUDE_SCM_OBSERVER:-}" \
       CLAUDE_SCM_INTERVAL="${CLAUDE_SCM_INTERVAL:-}" \
       CLAUDE_SCM_EVENTS="${CLAUDE_SCM_EVENTS:-}" \
       CLAUDE_SCM_PR_FILTER="${CLAUDE_SCM_PR_FILTER:-}" \
       CLAUDE_SCM_PR_LIMIT="${CLAUDE_SCM_PR_LIMIT:-}" \
       CLAUDE_SCM_PRIORITY="${CLAUDE_SCM_PRIORITY:-}" \
       CLAUDE_PERMISSION_MODE="${CLAUDE_PERMISSION_MODE:-bypassPermissions}"

# OpenTelemetry: opt-in fleet observability. Claude Code reads OTEL_* + the
# enable flag straight from the process environment (env > settings.json), and
# the tmux panes inherit this exported env, so we just compose sane defaults and
# a per-container resource tag: no settings.json surgery, and the auth header (a
# secret) stays in process env, never persisted to the config volume. Enabled by
# CLAUDE_OTEL_ENABLED=1 or simply by supplying an OTLP endpoint. Orthogonal to
# the Remote-Control telemetry concern above (that's nonessential-traffic, not
# this). Ref: code.claude.com/docs/en/monitoring-usage
if [[ "${CLAUDE_OTEL_ENABLED:-0}" =~ ^(1|true|yes|on)$ || -n "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" ]]; then
    export CLAUDE_CODE_ENABLE_TELEMETRY=1
    export OTEL_METRICS_EXPORTER="${OTEL_METRICS_EXPORTER:-otlp}"
    export OTEL_LOGS_EXPORTER="${OTEL_LOGS_EXPORTER:-otlp}"
    export OTEL_EXPORTER_OTLP_PROTOCOL="${OTEL_EXPORTER_OTLP_PROTOCOL:-http/protobuf}"
    # Traces are a Claude Code beta (needed for trace backends like Langfuse).
    if [[ "${CLAUDE_OTEL_TRACES:-0}" =~ ^(1|true|yes|on)$ ]]; then
        export CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1
        export OTEL_TRACES_EXPORTER="${OTEL_TRACES_EXPORTER:-otlp}"
    fi
    # service.name is fixed to "claude-code" upstream, so distinguish containers
    # with a custom tag (+ any operator-supplied attributes).
    _ra="service.instance.id=${CLAUDE_PROJECT_NAME},claude.project=${CLAUDE_PROJECT_NAME}"
    [[ -n "${OTEL_RESOURCE_ATTRIBUTES:-}" ]] && _ra="${_ra},${OTEL_RESOURCE_ATTRIBUTES}"
    export OTEL_RESOURCE_ATTRIBUTES="$_ra"
    # OTEL_EXPORTER_OTLP_ENDPOINT / _HEADERS arrive via env (-e/.env) and are
    # already exported into this environment, so the panes inherit them as-is.
    log "OpenTelemetry        : on → ${OTEL_EXPORTER_OTLP_ENDPOINT:-<no endpoint set!>} (${OTEL_EXPORTER_OTLP_PROTOCOL})$([[ -n "${OTEL_EXPORTER_OTLP_HEADERS:-}" ]] && echo ' +auth')"
    [[ -z "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" ]] && \
        log "OpenTelemetry        : WARNING, enabled but OTEL_EXPORTER_OTLP_ENDPOINT is empty; nothing will be exported"
fi

# Native Claude Code CLI tuning knobs (real upstream env vars the `claude`
# binary reads directly, see .env.example). Nothing to translate here, just
# surface non-default values in the boot log for operator visibility; a
# default fleet (all unset) stays quiet.
for _v in CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION BASH_DEFAULT_TIMEOUT_MS BASH_MAX_TIMEOUT_MS API_TIMEOUT_MS; do
    [[ -n "${!_v:-}" ]] && log "CLI tuning           : ${_v}=${!_v}"
done

# --- 12a. Egress lockdown (opt-in) -------------------------------------------
# Apply a default-deny firewall NOW, after the entrypoint's own setup (clone,
# plugin install) has finished with open egress, and as root (we still hold
# NET_ADMIN) before the unprivileged agent starts, so the agent runs sealed and
# cannot alter its own rules.
#
# TWO POSTURES, CHOSEN BY SPELLING. Fail-open stays the default and is what
# 1|true|yes|on have always meant: a firewall that could not be applied is a loud
# log line and the agent starts anyway, because a container that bricks a
# homelab's connectivity on a bad allowlist is the worse regression. `strict` is
# the fail-CLOSED spelling for an operator running an agent on untrusted input:
# same firewall, same ruleset, same log lines, but a run that leaves BOTH families
# unrestricted REFUSES TO START THE AGENT instead of proceeding. Lockdown stops
# being a request and becomes a requirement, and the operator escapes a refusing
# container by changing this one variable back.
#
# PER FAMILY, ALWAYS. A container can route IPv4 and IPv6, and the firewall can
# succeed on one and fail on the other, so there is no honest single-sentence
# answer to "is lockdown active". This block therefore never emits an unqualified
# "active": every line below names BOTH families and says, for each, whether it
# is default-deny or UNRESTRICTED. An operator reading `claude-logs` sees the
# unprotected family by name, which is the whole point of the line.
#
# The firewall's exit status IS the per-family verdict (see bin/claude-egress-firewall):
#   0 both default-deny · 2 IPv4 default-deny + IPv6 open · anything else both open.
# Note `set -e` is on, so the status is captured with `|| rc=$?`, never bare.
EGRESS_FIREWALL_BIN="/usr/local/bin/claude-egress-firewall"
if [[ "${CLAUDE_EGRESS_LOCKDOWN:-0}" =~ ^(1|true|yes|on|strict)$ ]]; then
    egress_strict=0
    if [[ "${CLAUDE_EGRESS_LOCKDOWN:-0}" == "strict" ]]; then egress_strict=1; fi
    egress_rc=0
    "$EGRESS_FIREWALL_BIN" || egress_rc=$?
    case "$egress_rc" in
        0) log "Egress lockdown      : IPv4 default-deny, IPv6 default-deny (allowlist + CLAUDE_EGRESS_EXTRA_HOSTS)" ;;
        2) log "Egress lockdown      : IPv4 default-deny, IPv6 UNRESTRICTED (the IPv6 ruleset could not be applied, see [egress] lines above)" ;;
        # Every OTHER status means the firewall applied NOTHING (fail_open() exits 1
        # on all five of its reasons, and a status this entrypoint cannot interpret
        # is read the same way: claim nothing). The log line is identical either way;
        # what strict adds is that the entrypoint stops here instead of falling
        # through to the tmux launch on the next statement.
        *) log "Egress lockdown      : IPv4 UNRESTRICTED, IPv6 UNRESTRICTED (FAILED to apply, egress left OPEN, see [egress] lines above)"
           if (( egress_strict == 1 )); then
               die "Egress lockdown was requested STRICTLY (CLAUDE_EGRESS_LOCKDOWN=strict) and the
       ruleset could NOT be applied: claude-egress-firewall exited $egress_rc, so this
       container has UNRESTRICTED egress on both address families. Starting the agent
       now is the exact outcome strict exists to prevent, so it is not started.
       The [egress] lines above name the cause (no NET_ADMIN capability, no iptables
       in the image, or an allowlist that resolved to nothing). Fix that, or set
       CLAUDE_EGRESS_LOCKDOWN=1 for the fail-open posture that logs and boots anyway."
           fi ;;
    esac
    # PERIODIC RE-RESOLVE. The allowlist above is a snapshot of DNS at boot, and this
    # container is meant to run for weeks: a CDN that rotates addresses turns the
    # snapshot into a set of rules pointing at hosts nobody serves any more, and the
    # agent's tooling starts failing at a moment nobody is watching. So a container
    # under lockdown can re-resolve on an interval, committing each refreshed ruleset
    # through the same atomic restore the boot pass used.
    #
    # IT RUNS HERE, AS ROOT, and it is started BEFORE the privilege drop for the same
    # reason the boot pass is: the agent has no NET_ADMIN and cannot signal a root
    # process, so it can neither alter what the refresh commits nor stop it happening.
    #
    # THE POSTURE IS ALWAYS STATED. Absent, malformed and non-positive intervals are
    # one case (no refresh), and silence about it would leave an operator who typed
    # `CLAUDE_EGRESS_REFRESH_INTERVAL=15m` believing their allowlist was being kept
    # current when it never will be. Only the "Egress lockdown" lines above are the
    # per-family posture contract; this is a separate line and does not touch it.
    egress_refresh="${CLAUDE_EGRESS_REFRESH_INTERVAL:-}"
    if [[ -z "$egress_refresh" ]]; then
        log "Egress refresh       : OFF (CLAUDE_EGRESS_REFRESH_INTERVAL is not set; the allowlist is resolved once, at boot, and pinned addresses go stale as CDNs rotate)"
    elif [[ ! "$egress_refresh" =~ ^[0-9]+$ ]] || (( 10#$egress_refresh <= 0 )); then
        log "Egress refresh       : OFF (CLAUDE_EGRESS_REFRESH_INTERVAL='${egress_refresh}' is not a positive whole number of seconds, so it cannot be an interval; the allowlist is resolved once, at boot)"
    elif [[ "$egress_rc" != 0 && "$egress_rc" != 2 ]]; then
        log "Egress refresh       : OFF (the boot pass committed no ruleset, so there is nothing to refresh; re-committing later would seal a container this log has already reported as UNRESTRICTED)"
    else
        "$EGRESS_FIREWALL_BIN" --refresh-daemon &
        log "Egress refresh       : every ${egress_refresh}s, as root (re-resolves the same allowlist and re-commits it atomically; a lookup that comes back empty RETAINS the ruleset in force and is logged by name, never narrowed)"
    fi
elif [[ -n "${CLAUDE_EGRESS_LOCKDOWN:-}" ]] && [[ ! "${CLAUDE_EGRESS_LOCKDOWN}" =~ ^(0|false|no|off)$ ]]; then
    # An unrecognised value: neither an off value nor an on/strict spelling. Silence
    # here is the failure mode strict exists to end, because a mistyped `stict` (or a
    # trailing space) would otherwise read as a deliberate "off" and the operator
    # would believe they were contained. WARN, never die: refusing to boot on a
    # stale or fat-fingered .env line would be a worse regression than the one being
    # reported, which is the same trade section 0 makes for the retired vars.
    log "Egress lockdown      : IPv4 UNRESTRICTED, IPv6 UNRESTRICTED (CLAUDE_EGRESS_LOCKDOWN='${CLAUDE_EGRESS_LOCKDOWN}' is not a recognised value, so NO firewall was applied; recognised: 0/false/no/off = off, 1/true/yes/on = lockdown that fails OPEN, strict = lockdown that refuses to start the agent when it cannot be applied)"
fi

# tmux server runs as the claude user; the main pane command falls back to an
# interactive shell if it exits, so SSH stays usable. The pane lives in window
# 'main' (the RC watchdog respawns it by name in interactive mode).
asclaude tmux new-session -d -s claude -n main -x 220 -y 50 "$MAIN_PANE_CMD"
log "Claude Code session 'claude' started in tmux (mode: $CLAUDE_MODE)"

# Optional dev server: runs $CLAUDE_DEV_CMD in its own 'dev' tmux window so it
# auto-starts on boot, is observable (tmux select-window -t claude:dev), and
# survives independently of the Claude pane.
if [[ -n "${CLAUDE_DEV_CMD:-}" ]]; then
    asclaude tmux new-window -t claude -n dev /usr/local/bin/claude-dev
    log "Dev server started in tmux window 'dev': $CLAUDE_DEV_CMD"
fi

# Optional SCM observer: polls the workspace repo's PRs and routes CI failures /
# change requests / merge conflicts into the autopilot task queue. Runs in its
# own 'scm' tmux window. Pair with CLAUDE_AUTOPILOT=1 + CLAUDE_AUTOPILOT_QUEUE=1
# so the same container consumes what it observes.
if [[ "${CLAUDE_SCM_OBSERVER:-0}" =~ ^(1|true|yes|on)$ ]]; then
    asclaude tmux new-window -t claude -n scm /usr/local/bin/claude-scm-observer
    log "SCM observer         : routing repo events into the queue (tmux window 'scm')"
    [[ "${CLAUDE_AUTOPILOT_QUEUE:-0}" =~ ^(1|true|yes|on)$ ]] || \
        log "SCM observer         : NOTE, enqueues tasks, but nothing consumes them without CLAUDE_AUTOPILOT=1 + CLAUDE_AUTOPILOT_QUEUE=1"
fi

# --- 12b. Remote Control watchdog -------------------------------------------
# Claude Code's RC bridge retries reconnection on its own: a transient network
# drop self-heals, but it can also fail terminally (logs a give-up and stops):
# the link then dies silently with no recovery while the `claude` process stays
# alive and the phone session goes dark (see docs/troubleshooting.md). The
# watchdog detects that terminal state from the RC debug log and respawns the
# session with --continue once the pane is idle.
RC_WATCHDOG_PID=""
if [[ "$CLAUDE_MODE" == "autopilot" ]]; then
    log "Remote Control watchdog skipped ($CLAUDE_MODE mode, no Remote Control session)"
elif [[ "${CLAUDE_RC_WATCHDOG:-1}" != "0" ]]; then
    asclaude /usr/local/bin/claude-rc-watchdog &
    RC_WATCHDOG_PID=$!
    log "Remote Control watchdog started (disable with CLAUDE_RC_WATCHDOG=0)"
else
    log "Remote Control watchdog disabled (CLAUDE_RC_WATCHDOG=0)"
fi

# --- 12c. Usage-limit account-rotation watchdog (multi-account mode only) ----
# Rotates to a different pre-authenticated account when the active one hits
# its usage limit, resuming the same conversation. Only meaningful with
# CLAUDE_ACCOUNTS set (nothing to rotate to otherwise) and in interactive
# mode (autopilot has its own reset-time backoff, bin/claude-autopilot).
USAGE_WATCHDOG_PID=""
if [[ "$CLAUDE_MODE" == "autopilot" || -z "${CLAUDE_ACCOUNTS:-}" ]]; then
    : # nothing to watch
elif [[ "${CLAUDE_USAGE_WATCHDOG:-1}" != "0" ]]; then
    asclaude /usr/local/bin/claude-usage-watchdog &
    USAGE_WATCHDOG_PID=$!
    log "Usage-limit watchdog started (accounts: $CLAUDE_ACCOUNTS; disable with CLAUDE_USAGE_WATCHDOG=0)"
else
    log "Usage-limit watchdog disabled (CLAUDE_USAGE_WATCHDOG=0)"
fi

echo
if [[ "$CLAUDE_MODE" == "autopilot" ]]; then
    if [[ -n "${CLAUDE_AUTOPILOT_CMD:-}" ]]; then
        log "Autopilot           : headless loop running '${CLAUDE_AUTOPILOT_CMD}' in tmux window 'main'"
    else
        log "Autopilot           : queue consumer in tmux window 'main' (no CLAUDE_AUTOPILOT_CMD, idles when the queue is empty)"
    fi
else
    log "Remote Control name : $CLAUDE_PROJECT_NAME  (look for it in the Claude app Code tab)"
fi
log "SSH                 : connect, you'll attach to the live tmux session"
[[ -n "${CLAUDE_DEV_CMD:-}" ]] && \
    log "Dev window          : tmux select-window -t claude:dev  (after SSH attach)"
echo

# --- 13. Stay alive + graceful shutdown --------------------------------------
shutdown() {
    log "Shutting down"
    asclaude tmux kill-server >/dev/null 2>&1 || true
    pkill -x sshd >/dev/null 2>&1 || true
    kill "$RECONCILE_PID" >/dev/null 2>&1 || true
    [[ -n "${ACCT_SWITCH_PID:-}" ]] && kill "$ACCT_SWITCH_PID" >/dev/null 2>&1 || true
    [[ -n "${RC_WATCHDOG_PID:-}" ]] && kill "$RC_WATCHDOG_PID" >/dev/null 2>&1 || true
    [[ -n "${USAGE_WATCHDOG_PID:-}" ]] && kill "$USAGE_WATCHDOG_PID" >/dev/null 2>&1 || true
    # Tear the inner Docker down BEFORE PID 1 exits (docker mode only). Without this, the
    # inner containers and their containerd-shims are still alive when the container dies;
    # the runtime then SIGKILLs the tree and the exit event can arrive after Docker has
    # stopped waiting for it: surfacing on the host as
    #   "could not kill container: tried to kill container, but did not receive an exit event"
    # which aborts `docker rm -f` (observed: claude-rm --purge died mid-way, leaking volumes).
    # Stopping the children first makes the teardown orderly and the exit event prompt.
    # Best-effort throughout: a shutdown path must never be the reason a container won't die.
    if [[ "${CLAUDE_DOCKER:-0}" =~ ^(1|true|yes|on)$ ]] && command -v docker >/dev/null 2>&1; then
        log "Inner dockerd       : stopping inner containers, then the daemon"
        # Bound this hard. The whole trap must finish inside the OUTER stop timeout
        # (CLAUDE_STOP_TIMEOUT, default 20s): overrun it and Docker SIGKILLs PID 1, which is
        # the very failure this trap exists to prevent. `-t 5` caps each inner container
        # (Docker's default is 10s, and a process that ignores SIGTERM burns all of it), and
        # `timeout 15` caps the batch.
        # shellcheck disable=SC2046
        timeout 15 docker stop -t 5 $(docker ps -q 2>/dev/null) >/dev/null 2>&1 || true
        pkill -TERM -x dockerd >/dev/null 2>&1 || true
        for _ in $(seq 10); do pgrep -x dockerd >/dev/null 2>&1 || break; sleep 1; done
        pkill -KILL -x dockerd >/dev/null 2>&1 || true
    fi
    exit 0
}
trap shutdown TERM INT

# Keep PID 1 alive while the container should run. If the tmux server dies
# entirely (rare), exit so Docker's restart policy can recover it.
#
# Require several CONSECUTIVE failures, not one. This probe is not a pure read:
# `asclaude` is gosu + env + tmux, so every check costs three forks. When the container
# is out of PIDs: the cgroup pids.max counts THREADS, so a browser or inner-dockerd
# session reaches it long before the process count suggests: fork returns EAGAIN and
# the probe fails against a tmux that is perfectly alive. Treating that one failure as
# "tmux died" tore a healthy container down, and the restart policy then brought it back
# with an empty session, losing the user's work. Observed twice in 16h on a real host:
# the entrypoint logged `fork: retry: Resource temporarily unavailable` four seconds
# after it reported "tmux session ended". Retrying costs a few extra seconds when tmux is genuinely gone;
# not retrying costs a live session on any transient resource blip.
LIVENESS_MAX_FAILURES="${CLAUDE_LIVENESS_MAX_FAILURES:-3}"
liveness_failures=0
while :; do
    if asclaude tmux has-session -t claude >/dev/null 2>&1; then
        liveness_failures=0
    else
        liveness_failures=$(( liveness_failures + 1 ))
        if (( liveness_failures >= LIVENESS_MAX_FAILURES )); then
            break
        fi
        log "tmux liveness probe failed (${liveness_failures}/${LIVENESS_MAX_FAILURES}): retrying in 5s"
    fi
    sleep 5 & wait $!
done
log "tmux session ended (liveness probe failed ${LIVENESS_MAX_FAILURES}x consecutively)"
shutdown
