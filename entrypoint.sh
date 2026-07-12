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

# --- 2. Fix ownership of mounted volumes -------------------------------------
mkdir -p "$CLAUDE_CONFIG_DIR" "$AUTH_DIR" "$HOSTKEY_DIR" "$CLAUDE_HOME/.ssh" "$WORKSPACE"
chown -R "$CLAUDE_UID:$CLAUDE_GID" "$CLAUDE_CONFIG_DIR" "$CLAUDE_HOME/.ssh"
chown "$CLAUDE_UID:$CLAUDE_GID" "$WORKSPACE" 2>/dev/null || true
chmod 700 "$CLAUDE_HOME/.ssh"

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
# CLAUDE_BROKER_GIT_KEY=1 loads the deploy key into a ROOT-owned ssh-agent and
# exposes only the agent socket to the claude user: git can sign/push with the
# key, but the unprivileged (prompt-injectable) agent can never read the private
# key bytes, so it can't be exfiltrated. Default off keeps the historical
# readable key file. Either way the key is never baked into the image.
git_brokered=0
if [[ -s "$GITKEY_SRC" ]]; then
    cat > "$CLAUDE_HOME/.ssh/config" <<EOF
Host *
    StrictHostKeyChecking accept-new
    UserKnownHostsFile ~/.ssh/known_hosts
EOF
    if [[ "${CLAUDE_BROKER_GIT_KEY:-0}" =~ ^(1|true|yes|on)$ ]]; then
        # Key lives only in a ROOT ssh-agent's memory (+ the root-only mounted
        # key file). ssh-agent rejects cross-uid peers, so a root socat relay
        # exposes a claude-usable socket and forwards to the root agent: claude
        # signs through it (git push works) but can neither extract the key
        # (agent protocol never returns private keys) nor read root's memory.
        mkdir -p /run/claude && chmod 711 /run/claude
        AGENT_SOCK="/run/claude/agent-root.sock"     # root-only
        CLAUDE_SOCK="/run/claude/agent.sock"         # claude-usable, via relay
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
            printf 'export SSH_AUTH_SOCK=%s\n' "$CLAUDE_SOCK" > /etc/profile.d/claude-ssh-agent.sh
            git_brokered=1
            log "Git SSH key broker  : key held in a root ssh-agent (claude signs via relay, cannot read it)"
        else
            log "Git SSH key broker  : WARNING — ssh-agent/relay setup failed; falling back to a readable key file"
        fi
    fi
    if [[ "$git_brokered" == 0 ]]; then
        install -o "$CLAUDE_UID" -g "$CLAUDE_GID" -m 600 \
            "$GITKEY_SRC" "$CLAUDE_HOME/.ssh/id_ed25519"
        printf 'Host *\n    IdentityFile ~/.ssh/id_ed25519\n' >> "$CLAUDE_HOME/.ssh/config"
        log "Installed git SSH key"
    fi
    chown "$CLAUDE_UID:$CLAUDE_GID" "$CLAUDE_HOME/.ssh/config"
    chmod 600 "$CLAUDE_HOME/.ssh/config"
else
    log "No git SSH key mounted at $GITKEY_SRC (https/public repos still work)"
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
# committing obvious secrets/credentials — important because the agent commits
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

# --- 5b. Worker broker (controller mode, CC-2) --------------------------------
# CLAUDE_WORKER_BROKER=1 starts the ROOT-owned worker broker: on a controller
# (a Sysbox container running an inner dockerd) it is the ONLY principal that
# may launch nested workers. Mirrors the git-key broker above — root owns the
# capability, the unprivileged agent gets a narrow request channel
# (claude-worker-request → spool dir), never the inner Docker socket. The broker
# FAILS CLOSED unless the substrate holds: userns containment readable from
# /proc/self/uid_map AND a host-attested, CVE-patched Sysbox version in
# CLAUDE_SYSBOX_ATTESTED_VERSION (the host launch path runs preflight_sysbox and
# passes SYSBOX_VERSION in). See bin/claude-worker-broker for the template.
#
# CLAUDE_CONTROLLER=1 (CC-6) NEEDS the broker — the controller dispatches workers
# via claude-worker-request, which talks to nothing without a live broker — so it
# implies CLAUDE_WORKER_BROKER=1 here rather than silently no-op'ing later. An
# operator who explicitly set CLAUDE_WORKER_BROKER=0 alongside CLAUDE_CONTROLLER=1
# gets a loud refusal instead of a controller that starts and can never dispatch.
if [[ "${CLAUDE_CONTROLLER:-0}" =~ ^(1|true|yes|on)$ ]]; then
    case "${CLAUDE_WORKER_BROKER:-}" in
        0|false|no|off)
            die "CLAUDE_CONTROLLER=1 requires the worker broker, but CLAUDE_WORKER_BROKER was explicitly set to '${CLAUDE_WORKER_BROKER}'. Unset it (or set CLAUDE_WORKER_BROKER=1) to run controller mode." ;;
        *) CLAUDE_WORKER_BROKER=1 ;;
    esac
    log "Controller mode      : CLAUDE_CONTROLLER=1 — implying CLAUDE_WORKER_BROKER=1 (the controller dispatches workers through the broker)"
fi

# --- 5a. Inner dockerd + worker broker (controller / --broker) ----------------
# The worker broker (CC-2) and the nested workers it launches (CC-4) run on an
# INNER dockerd that lives INSIDE this container — never the host daemon (a host
# socket mount or --privileged DinD are both FORBIDDEN: umbrella ADR 0011). Under
# Sysbox (--runtime=sysbox-runc) that inner daemon is contained by a user namespace
# (root here → an unprivileged host uid), so it needs no privilege. Order matters:
# start the inner dockerd FIRST (a missing/dead daemon must fail fast+clear here, not
# as an opaque downstream timeout), then the broker, then §5c blocks the agent until
# the broker is actually SERVING. Only the CONTROLLER image bakes dockerd
# (WITH_DOCKER=1); a plain session or a leaf worker never sets CLAUDE_WORKER_BROKER
# and so never reaches this block. (§5a + §5b share one guard on purpose.)
if [[ "${CLAUDE_WORKER_BROKER:-0}" =~ ^(1|true|yes|on)$ ]]; then
    # --- inner dockerd ---
    if docker info >/dev/null 2>&1; then
        log "Inner dockerd        : already reachable — reusing it (not starting a second daemon)"
    else
        command -v dockerd >/dev/null 2>&1 \
            || die "CLAUDE_WORKER_BROKER=1 needs an inner Docker daemon, but 'dockerd' is not in this image. Rebuild the CONTROLLER image (make build-controller, or --build-arg WITH_DOCKER=1) and run it under --runtime=sysbox-runc — see docs/substrate.md."
        DOCKERD_WAIT="${CLAUDE_INNER_DOCKERD_WAIT:-60}"
        # A POSITIVE integer with no leading zero: `(( … ))` parses a leading-zero value
        # as octal (090 → error, spins forever), and 0 would time out before dockerd can
        # even create its socket — both are refused up front (fail closed with a clear msg).
        [[ "$DOCKERD_WAIT" =~ ^[1-9][0-9]*$ ]] || die "CLAUDE_INNER_DOCKERD_WAIT '$DOCKERD_WAIT' is not a positive integer (no leading zero)"
        # Clear a stale pidfile a prior, ungracefully-killed daemon left behind, so a
        # container restart (--restart unless-stopped) doesn't boot-loop on 'pidfile exists'.
        rm -f /run/docker.pid /var/run/docker.pid 2>/dev/null || true
        log "Inner dockerd        : starting as root (Sysbox-contained; log at /var/log/inner-dockerd.log)"
        dockerd >> /var/log/inner-dockerd.log 2>&1 &
        dwaited=0
        until docker info >/dev/null 2>&1; do
            if (( dwaited >= DOCKERD_WAIT )); then
                log "inner dockerd did not become ready within ${DOCKERD_WAIT}s — last log lines:"
                tail -n 20 /var/log/inner-dockerd.log 2>/dev/null | sed 's/^/    /' >&2 || true
                die "inner dockerd failed to start. On Sysbox this is usually a missing --runtime=sysbox-runc (the daemon needs the user namespace the runtime provides). See docs/substrate.md."
            fi
            sleep 1; dwaited=$((dwaited + 1))
        done
        log "Inner dockerd        : ready after ${dwaited}s"
    fi

    # --- durable worker image (CC-INTERACTIVE-BROKER) ---
    # The broker launches workers from CLAUDE_WORKER_IMAGE, which must be ON the inner
    # daemon. That daemon starts EMPTY on every (re)create — so without this, the first
    # worker launch after a recreate has to pull/rebuild, and a locally-built (registry-
    # less) image can't be pulled at all. If a worker-image tarball is mounted
    # (CLAUDE_WORKER_IMAGE_TARBALL — a HOST file that survives container recreate), load it
    # into the inner daemon now, before the broker. Idempotent (skipped if the image is
    # already present, e.g. after a plain restart) and FAIL-SOFT (a load failure warns but
    # never blocks boot — the broker just refuses launches until the image is present).
    if [[ -n "${CLAUDE_WORKER_IMAGE_TARBALL:-}" ]]; then
        _wimg="${CLAUDE_WORKER_IMAGE:-claude-code-box:latest}"
        if ! [[ -f "$CLAUDE_WORKER_IMAGE_TARBALL" ]]; then
            log "Worker image        : WARNING — CLAUDE_WORKER_IMAGE_TARBALL '$CLAUDE_WORKER_IMAGE_TARBALL' not found (mount it read-only); broker will refuse launches until $_wimg is present"
        elif docker image inspect "$_wimg" >/dev/null 2>&1; then
            log "Worker image        : $_wimg already on the inner daemon — skipping tarball load"
        else
            log "Worker image        : loading $_wimg from $CLAUDE_WORKER_IMAGE_TARBALL (durable across recreate; first load may take ~1m)"
            if docker load -i "$CLAUDE_WORKER_IMAGE_TARBALL" >>/var/log/inner-dockerd.log 2>&1; then
                log "Worker image        : loaded"
            else
                log "Worker image        : WARNING — failed to load $CLAUDE_WORKER_IMAGE_TARBALL (see /var/log/inner-dockerd.log); broker will refuse launches until $_wimg is present"
            fi
        fi
    fi

    # --- worker broker (CC-2) ---
    # Best-effort early lock: keep the agent off an already-present inner socket
    # even before the broker's own lockdown (the broker re-asserts at startup).
    if [[ -S /var/run/docker.sock ]]; then
        chown root:root /var/run/docker.sock 2>/dev/null || true
        chmod 600 /var/run/docker.sock 2>/dev/null || true
    fi
    CLAUDE_BROKER_CLIENT_USER="${CLAUDE_BROKER_CLIENT_USER:-$CLAUDE_USER}" \
        /usr/local/bin/claude-worker-broker >> /var/log/claude-worker-broker.log 2>&1 &
    BROKER_PID=$!   # §5c watches this to fail FAST if the broker dies at startup
    log "Worker broker       : starting as root (agent requests via claude-worker-request; refuses if the substrate checks fail — see /var/log/claude-worker-broker.log)"

    # Worker lifecycle reaper (CC-4): removes exited/dead/created claude.worker=1
    # containers a `--rm` worker's unclean exit missed (freeing the name for a
    # re-request) and prunes aged broker-spool files. Worker-broker mode only
    # (controller mode implies it), alongside the broker above.
    /usr/local/bin/claude-reaper --loop >> /var/log/claude-reaper.log 2>&1 &
    log "Worker reaper       : starting as root, looping every ${CLAUDE_REAPER_INTERVAL:-300}s (removes dead worker residue + prunes the spool — see /var/log/claude-reaper.log)"

    # Disk GC timer (CC-5): scheduled `docker system prune -f` + `docker builder
    # prune -f` on the inner daemon so nested-worker layers + build cache don't
    # fill the host. Runs alongside the broker's per-launch free-space floor
    # (bin/claude-worker-broker, broker_check_disk) — the floor refuses a launch
    # under pressure, this reclaims space so future launches don't have to.
    /usr/local/bin/claude-disk-gc --loop >> /var/log/claude-disk-gc.log 2>&1 &
    log "Disk GC             : starting as root, looping every ${CLAUDE_DISK_GC_INTERVAL:-3600}s (docker system + builder prune -f — see /var/log/claude-disk-gc.log)"
fi

# --- 5c. Worker-broker mode: the broker MUST be SERVING before the agent starts ---
# CC-2-discovered gap: the broker above is BACKGROUNDED, so §12 below would otherwise start
# the unprivileged agent tmux session with no dependency on the broker's progress — and a
# compromised/injected agent could reach the inner daemon directly during the boot window,
# bypassing the broker's request/lease discipline entirely (the exact hole this closes).
#
# Block HERE — authoritatively, before §12 launches the agent — until the broker is up and
# serving. Note we wait for the broker to be *serving*, not merely for the socket perms:
# §5a guarantees the socket exists and the best-effort pre-lock already sets it root:root
# 600 the instant it does, so socket perms alone no longer prove the broker came up. The
# broker creates its request SPOOL only after passing every fail-closed startup check
# (userns + attestation + capacity + disk + socket-lock; see broker_serve's order), so the
# spool dir is the authoritative "broker is alive and serving" signal.
#
# Gate this on CLAUDE_WORKER_BROKER (what actually backgrounds the broker), NOT on
# CLAUDE_CONTROLLER: an interactive (or autopilot) session with CLAUDE_WORKER_BROKER=1 —
# e.g. `claude-launch --broker`, a conversational lead that spawns nested workers via
# claude-worker-request — shares the exact same boot race but is not a controller. Since
# controller mode IMPLIES CLAUDE_WORKER_BROKER=1 (§5a), this still covers controller mode; it
# just no longer LEAVES OUT the broker-only interactive path.
if [[ "${CLAUDE_WORKER_BROKER:-0}" =~ ^(1|true|yes|on)$ ]]; then
    SOCK=/var/run/docker.sock
    BROKER_SPOOL="${CLAUDE_BROKER_DIR:-/run/claude/broker}/requests"
    # CLAUDE_BROKER_SOCKET_LOCKDOWN_WAIT is the mode-neutral knob; the legacy
    # CLAUDE_CONTROLLER_SOCKET_WAIT name is still honored for back-compat. Positive integer,
    # no leading zero (octal-safe in the `(( … ))` compare below).
    SOCK_WAIT="${CLAUDE_BROKER_SOCKET_LOCKDOWN_WAIT:-${CLAUDE_CONTROLLER_SOCKET_WAIT:-90}}"
    [[ "$SOCK_WAIT" =~ ^[1-9][0-9]*$ ]] || die "CLAUDE_BROKER_SOCKET_LOCKDOWN_WAIT '$SOCK_WAIT' is not a positive integer (no leading zero)"
    waited=0
    sock_locked() {
        [[ -S "$SOCK" ]] || return 1
        local owner group perm
        owner="$(stat -c '%U' "$SOCK" 2>/dev/null || true)"
        group="$(stat -c '%G' "$SOCK" 2>/dev/null || true)"
        perm="$(stat -c '%a' "$SOCK" 2>/dev/null || true)"
        [[ "$owner" == root && "$group" == root && "$perm" == 600 ]]
    }
    # Broker is serving iff it locked the socket AND created its spool (post-checks).
    broker_serving() { sock_locked && [[ -d "$BROKER_SPOOL" ]]; }
    until broker_serving; do
        # Fail FAST if the backgrounded broker already exited (a failed startup check) —
        # don't make the operator wait out the full timeout for a diagnosis.
        if [[ -n "${BROKER_PID:-}" ]] && ! kill -0 "$BROKER_PID" 2>/dev/null; then
            log "worker broker exited during startup — last log lines:"
            tail -n 20 /var/log/claude-worker-broker.log 2>/dev/null | sed 's/^/    /' >&2 || true
            die "worker broker failed to start (see /var/log/claude-worker-broker.log) — refusing to start the agent session over an unbrokered inner socket."
        fi
        if (( waited >= SOCK_WAIT )); then
            die "worker-broker mode: the broker did not lock $SOCK to root:root 600 and begin serving within ${SOCK_WAIT}s — refusing to start the agent session (check /var/log/claude-worker-broker.log)."
        fi
        sleep 1; waited=$((waited + 1))
    done
    log "Worker broker       : inner socket root:root 600 and broker serving before the agent session starts (waited ${waited}s)"
fi

# --- 5d. Cache proxy: START it on the controller (PKG-6) ---------------------
# CLAUDE_CACHE_PROXY=1 on a controller/broker host starts the ROOT-owned pull-through
# cache on the inner dockerd (the SINGLE audited registry egress for every worker) and
# BLOCKS until it is ready before the agent/controller loop starts dispatching workers —
# a worker launched before the proxy answers would (correctly) fail its own fail-closed
# client-apply. Gated on the broker being present (controller mode implies it, §5b): the
# proxy needs the inner dockerd, which only a controller/broker host runs. A plain WORKER
# with the same flag instead CONSUMES the proxy (§10c below). FAIL CLOSED: if the proxy
# cannot start or become ready within CLAUDE_CACHE_PROXY_READY_TIMEOUT, refuse to start —
# never run a proxy-mode fleet whose choke point is absent.
if [[ "${CLAUDE_CACHE_PROXY:-0}" =~ ^(1|true|yes|on)$ ]] \
   && [[ "${CLAUDE_WORKER_BROKER:-0}" =~ ^(1|true|yes|on)$ ]]; then
    if /usr/local/bin/claude-cache-proxy start; then
        log "Cache proxy          : controller-side pull-through cache starting (single audited egress choke point)"
        if /usr/local/bin/claude-cache-proxy ready; then
            log "Cache proxy          : ready — workers will fetch packages through it (egress narrowed to the proxy)"
        else
            die "Cache proxy          : started but not ready within the timeout — refusing controller startup (fail closed; dispatched workers would fail their own proxy gate). Tune CLAUDE_CACHE_PROXY_READY_TIMEOUT; see /var/log or docs/caching-proxy.md."
        fi
    else
        die "Cache proxy          : CLAUDE_CACHE_PROXY=1 but the proxy could not be started on the inner dockerd — refusing controller startup (fail closed)."
    fi
fi

# --- 6. Credentials reconcile (shared auth volume) ---------------------------
# Credentials are shared across all containers via the claude-auth volume; the
# rest of the config dir is per-container so sessions never collide. Claude
# rewrites .credentials.json on token refresh, so a small loop keeps the
# per-container file and the shared volume converged (newest wins).
if [[ ! -s "$AUTH_DIR/.credentials.json" ]]; then
    if [[ "${CLAUDE_SKIP_AUTH_CHECK:-0}" == "1" ]]; then
        log "WARNING: no credentials in claude-auth volume (auth check skipped)"
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
# unavoidable — Claude Code authenticates with it), but cannot reach the master
# that backs every other container. `make login` (root-chowns /auth) is separate.
chown root:root "$AUTH_DIR" 2>/dev/null || true
chmod 700 "$AUTH_DIR" 2>/dev/null || true
[[ -e "$AUTH_DIR/.credentials.json" ]] && { chown root:root "$AUTH_DIR/.credentials.json" 2>/dev/null || true; chmod 600 "$AUTH_DIR/.credentials.json" 2>/dev/null || true; }

reconcile_creds() {
    local a="$AUTH_DIR/.credentials.json"
    local b="$CLAUDE_CONFIG_DIR/.credentials.json"
    local t
    while sleep 30; do
        [[ -s "$a" || -s "$b" ]] || continue
        # Stage into a unique tmp file in the *target* dir, then atomic-rename.
        # /auth is shared by every container, so a fixed tmp name would let one
        # container's mv pick up another container's half-written file and
        # publish a partial/corrupt .credentials.json fleet-wide.
        if [[ -s "$b" && ( ! -s "$a" || "$b" -nt "$a" ) ]] && ! cmp -s "$b" "$a"; then
            t="$(mktemp "$a.XXXXXX")" || continue
            { install -m 600 "$b" "$t" && mv -f "$t" "$a"; } || rm -f "$t"
        elif [[ -s "$a" && "$a" -nt "$b" ]] && ! cmp -s "$a" "$b"; then
            t="$(mktemp "$b.XXXXXX")" || continue
            { install -o "$CLAUDE_UID" -g "$CLAUDE_GID" -m 600 "$a" "$t" \
                && mv -f "$t" "$b"; } || rm -f "$t"
        fi
    done
}
reconcile_creds &
RECONCILE_PID=$!

# --- 7. Seed .claude.json (onboarding + workspace trust) ---------------------
# With CLAUDE_CONFIG_DIR set, Claude stores .claude.json *inside* it. Pre-accept
# the workspace trust dialog and onboarding non-interactively, and lift the
# oauthAccount written by `make login` so the account shows correctly. Only
# fills missing keys — never clobbers existing per-container state.
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

# --- 8. Merge baked-in config ------------------------------------------------
# Everything baked into the image is overridable at runtime by mounting onto
# the target path (we only fill what's absent).

# 8a. Global CLAUDE.md
if [[ -f "$BAKE_DIR/CLAUDE.md" && ! -e "$CLAUDE_CONFIG_DIR/CLAUDE.md" ]]; then
    install -o "$CLAUDE_UID" -g "$CLAUDE_GID" -m 644 \
        "$BAKE_DIR/CLAUDE.md" "$CLAUDE_CONFIG_DIR/CLAUDE.md"
    log "Installed global CLAUDE.md"
fi

# 8a-bis. Per-mode CLAUDE.md fragments (CLAUDE.d/) — CC-BROKER-CLAUDE-D.
# Modular addenda that Claude Code surfaces via the /usr/local/bin/claude-md-fragments
# SessionStart hook (baked in settings.json §8b). Each mode-specific fragment is
# installed here only when its guard clause holds AND the target file is absent;
# non-matching modes leave the CLAUDE.d/ directory empty (or absent) and the hook
# is a silent no-op. Honors §8's overall contract: "we only fill what's absent"
# — a user-mounted CLAUDE.d/broker.md always wins over the baked one.
#
# broker.md — teaches an interactive/controller session that the ONLY channel for
# spawning nested workers is `claude-worker-request`. Installed only when:
#   1. the broker is configured (CLAUDE_WORKER_BROKER=1);
#   2. the broker's spool directory is present (§5c already blocked on
#      "${CLAUDE_BROKER_DIR:-/run/claude/broker}/requests" being created by the
#      broker's post-checks, so on this path that dir exists — the check here is
#      a redundancy check on the same signal, not a race);
#   3. the baked fragment exists in the image; and
#   4. the target has not already been provided by a mount (no clobber, §8's rule).
# A guard-mismatch is a no-op, never a silent partial: either every condition
# holds and we install, or the fragment stays as-mounted (or absent).
if [[ "${CLAUDE_WORKER_BROKER:-0}" =~ ^(1|true|yes|on)$ ]] \
   && [[ -d "${CLAUDE_BROKER_DIR:-/run/claude/broker}/requests" ]] \
   && [[ -f "$BAKE_DIR/CLAUDE.d/broker.md" ]] \
   && [[ ! -e "$CLAUDE_CONFIG_DIR/CLAUDE.d/broker.md" ]]; then
    install -d -o "$CLAUDE_UID" -g "$CLAUDE_GID" -m 755 "$CLAUDE_CONFIG_DIR/CLAUDE.d"
    install -o "$CLAUDE_UID" -g "$CLAUDE_GID" -m 644 \
        "$BAKE_DIR/CLAUDE.d/broker.md" "$CLAUDE_CONFIG_DIR/CLAUDE.d/broker.md"
    log "Installed broker-mode CLAUDE.md addendum (CLAUDE.d/broker.md)"
fi

# 8b. settings.json — baked file is the base, existing user settings win on
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
# Self-heal: strip the Remote-Control-breaking telemetry kills from the final
# settings (covers per-container volumes created by an older image). If any
# were present, drop the cached GrowthBook flags + statsig cache so the next
# Claude run re-fetches them and RC eligibility resolves correctly.
jq -s '.[0] * .[1]' <(echo "$BASE_SETTINGS") <(echo "$EXISTING_SETTINGS") \
    | jq 'if .env then .env |= (del(.DISABLE_TELEMETRY,.DO_NOT_TRACK,.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC)) else . end' \
    > "$CLAUDE_CONFIG_DIR/settings.json"
chown "$CLAUDE_UID:$CLAUDE_GID" "$CLAUDE_CONFIG_DIR/settings.json"
if echo "$EXISTING_SETTINGS" | jq -e '.env // {} | (.DISABLE_TELEMETRY // .DO_NOT_TRACK // .CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC) != null' >/dev/null 2>&1; then
    log "Migrated settings.json: removed telemetry kills that block Remote Control; clearing stale feature-flag cache"
    [[ -s "$CJSON" ]] && jq 'del(.cachedGrowthBookFeatures,.cachedExperimentFeatures)' "$CJSON" > "$CJSON.tmp" \
        && mv -f "$CJSON.tmp" "$CJSON" && chown "$CLAUDE_UID:$CLAUDE_GID" "$CJSON"
    rm -rf "$CLAUDE_CONFIG_DIR/statsig" 2>/dev/null || true
fi

# 8c. Plugins — declarative. Claude Code installs/syncs the marketplaces and
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

# 8c-bis. Runtime plugin injection — no rebuild required.
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
# CLAUDE_BROWSER is TRI-STATE — the browser image is meant to "just work", so a
# baked variant auto-enables the MCP with no second flag:
#   • unset / empty / other  → AUTO: register iff the browser variant is baked
#     (both chrome-devtools-mcp AND chromium on PATH — the functional signal a
#     registration actually needs; the image also carries a `claude.browser`
#     LABEL the launcher pre-flight reads). A lean image stays silent.
#   • 1|true|yes|on          → FORCE ON: register; if the binaries are NOT baked,
#     fail LOUD + actionable (rebuild hint) — never a silent no-op.
#   • 0|false|no|off         → OPT OUT: skip even on a browser image.
# Registration is idempotent (the `claude mcp get` guard below), so re-runs and
# a resumed session never double-register. Headless, isolated profile (clean per
# session); --no-sandbox is required in unprivileged Docker.
_browser_baked() {
    command -v chrome-devtools-mcp >/dev/null 2>&1 && command -v chromium >/dev/null 2>&1
}
_register_chrome_devtools_mcp() {
    if asclaude claude mcp get chrome-devtools >/dev/null 2>&1; then
        log "MCP 'chrome-devtools' already configured, skipping"
        return 0
    fi
    # Resolve the SAME chromium the detection probe found, rather than hardcoding
    # /usr/bin/chromium — so a variant that installs chromium elsewhere (or as a
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
            "--chromeArg=--disable-gpu"
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
# yields `1\r`, which must still match "1" — not silently fall through to auto)
# and lowercase, so the tri-state match is robust to how the value was set.
_cb="$(printf '%s' "${CLAUDE_BROWSER:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
case "$_cb" in
    1|true|yes|on)
        # Explicit request — must be satisfiable, else fail loud (never silent).
        if _browser_baked; then
            _register_chrome_devtools_mcp
        else
            log "ERROR: CLAUDE_BROWSER=1 (or --browser) requested, but this image has no"
            log "       chrome-devtools-mcp / chromium baked in — the MCP cannot be enabled."
            log "       Rebuild the browser variant:  make build-browser"
            log "       (or:  make build WITH_BROWSER=1 CLAUDE_IMAGE=<tag>)."
            log "       Frontend debugging is UNAVAILABLE in this container until you do."
        fi
        ;;
    0|false|no|off)
        # Explicit opt-out — honored even on a browser image.
        _browser_baked && log "chrome-devtools MCP disabled (CLAUDE_BROWSER=off); skipping"
        ;;
    *)
        # Auto: a browser image enables the MCP by itself; a lean image is silent.
        if _browser_baked; then
            log "Browser image detected (chromium + chrome-devtools-mcp present) — auto-registering chrome-devtools MCP"
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
# so the healthcheck — a separate process spawned by dockerd — sees it too.
export CLAUDE_RC_DEBUG_LOG="${CLAUDE_RC_DEBUG_LOG-/tmp/claude-rc-debug.log}"
export CLAUDE_PROJECT_NAME CLAUDE_EXTRA_ARGS="${CLAUDE_EXTRA_ARGS:-}" \
       CLAUDE_DEV_CMD="${CLAUDE_DEV_CMD:-}"

# Model selection: default to the best available model. The `opus` alias always
# resolves to the latest Opus, so the fleet tracks the strongest model without a
# code change when a newer one ships. Override per-container with CLAUDE_MODEL —
# any Claude Code alias (opus, sonnet, haiku, opusplan, default) or a full model
# id (e.g. claude-opus-4-8). Both the interactive session and the autopilot loop
# read it and pass `--model`. To defer to Claude Code's own default, set
# CLAUDE_MODEL=default (empty/unset falls back to opus, the best available).
export CLAUDE_MODEL="${CLAUDE_MODEL:-opus}"
log "Model               : $CLAUDE_MODEL (override with CLAUDE_MODEL; 'default' = Claude Code's pick)"

# Three modes:
#   interactive (default)      — main pane is claude-session (Remote Control + SSH).
#   autopilot (CLAUDE_AUTOPILOT=1) — main pane is claude-autopilot, a headless Claude
#                           loop (default `/next`) for unattended continuous build-out;
#                           there is no Remote Control link, so the RC watchdog is
#                           skipped.
#   controller (CLAUDE_CONTROLLER=1, CC-6) — main pane is claude-controller, which wires
#                           this substrate to the umbrella PAR-* lease/scheduler/
#                           bump-worker. With effective worker-slots==1 (the operative
#                           default — see bin/claude-controller) it COLLAPSES to exactly
#                           the autopilot launch above, byte-identical; slots>1 is the
#                           built-but-gated K>1 loop. CLAUDE_CONTROLLER takes priority
#                           over CLAUDE_AUTOPILOT if both are set. No Remote Control
#                           link, same as autopilot (the RC watchdog is skipped).
# Either way SSH attaches to the live tmux pane.
case "${CLAUDE_CONTROLLER:-0}" in
    1|true|yes|on) CLAUDE_MODE=controller;  MAIN_PANE_CMD=/usr/local/bin/claude-controller ;;
    *)
        case "${CLAUDE_AUTOPILOT:-0}" in
            1|true|yes|on) CLAUDE_MODE=autopilot;   MAIN_PANE_CMD=/usr/local/bin/claude-autopilot ;;
            *)             CLAUDE_MODE=interactive; MAIN_PANE_CMD=/usr/local/bin/claude-session ;;
        esac
        ;;
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
# a per-container resource tag — no settings.json surgery, and the auth header (a
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
        log "OpenTelemetry        : WARNING — enabled but OTEL_EXPORTER_OTLP_ENDPOINT is empty; nothing will be exported"
fi

# Curated apt provisioning (PKG-4): in a Sysbox WORKER, install the declarative,
# curated apt manifest as root BEFORE dropping to the agent — the syslib gap `mise`
# can't fill. claude-apt-provision self-gates: it refuses unless we are root mapped
# to a non-root host uid (the worker userns), so setting this flag on a leaf is a
# logged no-op, never a partial. It opens the deb.debian.org window then RE-LOCKS
# it; the general egress lockdown just below is the authoritative final seal, so the
# worker is sealed even if the relock could not confirm. All-or-refuse, fail-safe.
if [[ "${CLAUDE_APT_PROVISION:-0}" =~ ^(1|true|yes|on)$ ]]; then
    if [[ ! "${CLAUDE_EGRESS_LOCKDOWN:-0}" =~ ^(1|true|yes|on)$ ]]; then
        log "Apt provisioning     : WARNING — CLAUDE_APT_PROVISION=1 without CLAUDE_EGRESS_LOCKDOWN=1: apt runs over OPEN egress with no scoped deb.debian.org window and no relock. Set CLAUDE_EGRESS_LOCKDOWN=1 for the contained install window."
    fi
    apt_rc=0; /usr/local/bin/claude-apt-provision || apt_rc=$?
    # Distinguish the outcomes: a leaf no-op (rc 3) is EXPECTED and benign; a real
    # install/egress failure (rc >=4) is NOT — surface it loudly so an operator
    # never reads a syslib that silently didn't install as a clean boot.
    if (( apt_rc == 0 )); then
        if [[ "${CLAUDE_EGRESS_LOCKDOWN:-0}" =~ ^(1|true|yes|on)$ ]]; then
            log "Apt provisioning     : curated manifest applied (worker tier); egress re-locked"
        else
            log "Apt provisioning     : curated manifest applied (worker tier); egress NOT re-locked (lockdown off)"
        fi
    elif (( apt_rc == 3 )); then
        log "Apt provisioning     : not a worker (leaf / no host-safe root) — nothing installed (expected on a leaf container)"
    else
        log "Apt provisioning     : FAILED (rc=$apt_rc) — a REAL install/egress error, not a benign leaf no-op; the worker may be missing a requested syslib (see [apt-provision] lines)"
    fi
fi

# Cache-proxy client provisioning (PKG-6): a WORKER in single-choke-point mode points its
# package managers at the controller-side pull-through cache, BEFORE the egress lockdown below
# narrows its egress to just the proxy (the firewall's CLAUDE_CACHE_PROXY_HOST profile). This
# runs while egress is still open, so the health-check + config write can reach the proxy.
# FAIL CLOSED: if the proxy is unreachable, REFUSE to start the agent — a proxy-mode worker
# never falls back to open/public-registry egress (roadmap PART II §II.8). Gated so ONLY a
# worker consumes it: a controller/broker host STARTS the proxy instead (§5d) and does not
# point its own managers at it.
if [[ "${CLAUDE_CACHE_PROXY:-0}" =~ ^(1|true|yes|on)$ ]] \
   && [[ ! "${CLAUDE_WORKER_BROKER:-0}" =~ ^(1|true|yes|on)$ ]] \
   && [[ ! "${CLAUDE_CONTROLLER:-0}" =~ ^(1|true|yes|on)$ ]]; then
    if [[ ! "${CLAUDE_EGRESS_LOCKDOWN:-0}" =~ ^(1|true|yes|on)$ ]]; then
        log "Cache proxy          : WARNING — CLAUDE_CACHE_PROXY=1 without CLAUDE_EGRESS_LOCKDOWN=1: package managers point at the proxy, but egress is NOT narrowed to it (the worker can still reach public registries directly). Set CLAUDE_EGRESS_LOCKDOWN=1 for the single-choke-point guarantee."
    fi
    if /usr/local/bin/claude-cache-proxy client-apply; then
        log "Cache proxy          : package managers pointed at the pull-through cache (worker; egress narrows to the proxy below)"
    else
        die "Cache proxy          : CLAUDE_CACHE_PROXY=1 but the proxy is unreachable — REFUSING to start the agent (fail closed; a proxy-mode worker never falls back to open egress). Check the controller's claude-cache-proxy + the shared '${CLAUDE_CACHE_PROXY_NET:-claude-cache-net}' network."
    fi
fi

# Egress lockdown (opt-in): apply a default-deny firewall NOW — after the
# entrypoint's own setup (clone, plugin install) has finished with open egress,
# and as root (we still hold NET_ADMIN) before the unprivileged agent starts, so
# the agent runs sealed and cannot alter its own rules. Fail-open by design.
if [[ "${CLAUDE_EGRESS_LOCKDOWN:-0}" =~ ^(1|true|yes|on)$ ]]; then
    if /usr/local/bin/claude-egress-firewall; then
        log "Egress lockdown      : default-deny active (allowlist + CLAUDE_EGRESS_EXTRA_HOSTS)"
    else
        log "Egress lockdown      : FAILED to apply — egress left OPEN (see [egress] lines above)"
    fi
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
        log "SCM observer         : NOTE — enqueues tasks, but nothing consumes them without CLAUDE_AUTOPILOT=1 + CLAUDE_AUTOPILOT_QUEUE=1"
fi

# --- 12b. Remote Control watchdog -------------------------------------------
# Claude Code's RC bridge retries reconnection on its own — a transient network
# drop self-heals — but it can also fail terminally (logs a give-up and stops):
# the link then dies silently with no recovery while the `claude` process stays
# alive and the phone session goes dark (see docs/troubleshooting.md). The
# watchdog detects that terminal state from the RC debug log and respawns the
# session with --continue once the pane is idle.
RC_WATCHDOG_PID=""
if [[ "$CLAUDE_MODE" == "autopilot" || "$CLAUDE_MODE" == "controller" ]]; then
    log "Remote Control watchdog skipped ($CLAUDE_MODE mode — no Remote Control session)"
elif [[ "${CLAUDE_RC_WATCHDOG:-1}" != "0" ]]; then
    asclaude /usr/local/bin/claude-rc-watchdog &
    RC_WATCHDOG_PID=$!
    log "Remote Control watchdog started (disable with CLAUDE_RC_WATCHDOG=0)"
else
    log "Remote Control watchdog disabled (CLAUDE_RC_WATCHDOG=0)"
fi

echo
if [[ "$CLAUDE_MODE" == "controller" ]]; then
    log "Controller          : wired to the umbrella PAR-* lease/scheduler/bump-worker in tmux window 'main' (see docs/substrate.md 'Controller mode (CC-6)')"
elif [[ "$CLAUDE_MODE" == "autopilot" ]]; then
    log "Autopilot           : headless loop running '${CLAUDE_AUTOPILOT_CMD:-/next}' in tmux window 'main'"
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
    [[ -n "${RC_WATCHDOG_PID:-}" ]] && kill "$RC_WATCHDOG_PID" >/dev/null 2>&1 || true
    exit 0
}
trap shutdown TERM INT

# Keep PID 1 alive while the container should run. If the tmux server dies
# entirely (rare), exit so Docker's restart policy can recover it.
while asclaude tmux has-session -t claude >/dev/null 2>&1; do
    sleep 5 & wait $!
done
log "tmux session ended"
shutdown
