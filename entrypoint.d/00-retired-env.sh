# shellcheck shell=bash
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
# CLAUDE_DOCKER=1 asked for the per-session Docker engine, which was removed along with
# the host runtime it needed. A container created by an old launcher or compose file can
# still carry it: boot (it is a leftover, not an unsafe request) but say plainly that
# there is no engine, instead of letting the session discover it one failed build later.
if [[ "${CLAUDE_DOCKER:-0}" =~ ^(1|true|yes|on)$ ]]; then
    log "WARNING: CLAUDE_DOCKER=${CLAUDE_DOCKER} is IGNORED: the per-session Docker engine was removed."
    log "WARNING: This session has no Docker daemon. Recreate the container without it."
fi
unset _v _retired_set RETIRED_VARS
