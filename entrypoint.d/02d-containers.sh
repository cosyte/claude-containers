# shellcheck shell=bash
# --- 2d. Containers in sessions (CLAUDE_CONTAINERS=1, a --containers session) --------------
# The agent runs rootless podman, and docker / docker compose drive it through podman's API
# (docs/containers-in-sessions.md, the "helper" mode). The launcher gave this container
# podman's seccomp profile, apparmor and systempaths unconfined, /dev/net/tun and an image-store
# volume; every capability and no-new-privileges are as in any session. What is left is root's
# share, done here:
#   - one subordinate id range for the agent (/etc/subuid, /etc/subgid), so images that own
#     files as other uids (postgres 999, nginx 101, apt's _apt) work;
#   - the uid-map helper: under no-new-privileges a setuid newuidmap gains nothing, so this
#     root daemon writes the map instead, for the caller's own ids only;
#   - the agent's runtime dir, cleared like the tmpfs it stands in for, and `podman system
#     service` on a socket in it, which DOCKER_HOST names for every pane and SSH login.
# Any other container: none of this runs, and the profile.d file is removed.
CONTAINERS_RUNTIME_DIR="/run/user/$CLAUDE_UID"
CONTAINERS_SOCK="$CONTAINERS_RUNTIME_DIR/podman/podman.sock"
CONTAINERS_STORE_DIR="$CLAUDE_HOME/.local/share/containers"
CONTAINERS_SUBIDS="$CLAUDE_USER:100000:65536"
CONTAINERS_LOG_DIR=/var/log/claude-containers
CONTAINERS_PROFILE_D=/etc/profile.d/claude-containers.sh
UIDMAP_HELPER=/usr/local/lib/claude/containers/uidmap-helper
UIDMAP_SOCK=/run/claude-containers/uidmap.sock
if [[ "${CLAUDE_CONTAINERS:-0}" =~ ^(1|true|yes|on)$ ]]; then
    for _f in /etc/subuid /etc/subgid; do
        { grep -v "^$CLAUDE_USER:" "$_f" 2>/dev/null || true; echo "$CONTAINERS_SUBIDS"; } > "$_f.tmp"
        chmod 644 "$_f.tmp" && mv -f "$_f.tmp" "$_f"
    done
    unset _f
    # The store's top directory only: what is inside belongs to the mapped ids.
    install -d -o "$CLAUDE_UID" -g "$CLAUDE_GID" "$CLAUDE_HOME/.local" "$CLAUDE_HOME/.local/share"
    install -d -o "$CLAUDE_UID" -g "$CLAUDE_GID" -m 700 "$CONTAINERS_STORE_DIR"
    # /run/user is in the container layer here, not a tmpfs, so it survives a restart: clear it,
    # or podman reads the last boot's state as live.
    rm -rf "$CONTAINERS_RUNTIME_DIR"
    install -d -o "$CLAUDE_UID" -g "$CLAUDE_GID" -m 700 "$CONTAINERS_RUNTIME_DIR" "$CONTAINERS_RUNTIME_DIR/podman"
    install -d -m 755 "${UIDMAP_SOCK%/*}" "$CONTAINERS_LOG_DIR"
    # Both restart when they exit; their output stays out of the boot log.
    ( while :; do "$UIDMAP_HELPER" "$UIDMAP_SOCK"; echo "uid-map helper exited ($?), restarting"; sleep 1; done ) \
        >> "$CONTAINERS_LOG_DIR/uidmap-helper.log" 2>&1 &
    ( while :; do
          asclaude env XDG_RUNTIME_DIR="$CONTAINERS_RUNTIME_DIR" \
              podman system service --time=0 "unix://$CONTAINERS_SOCK"
          echo "podman system service exited ($?), restarting"; sleep 2
      done ) >> "$CONTAINERS_LOG_DIR/podman-service.log" 2>&1 &
    export XDG_RUNTIME_DIR="$CONTAINERS_RUNTIME_DIR" DOCKER_HOST="unix://$CONTAINERS_SOCK"
    # An SSH login gets a fresh environment: the same two, from /etc/profile.
    printf 'export XDG_RUNTIME_DIR=%s\nexport DOCKER_HOST=%s\n' "$XDG_RUNTIME_DIR" "$DOCKER_HOST" \
        > "$CONTAINERS_PROFILE_D.tmp" && chmod 644 "$CONTAINERS_PROFILE_D.tmp" \
        && mv -f "$CONTAINERS_PROFILE_D.tmp" "$CONTAINERS_PROFILE_D"
    # Bounded: a helper or service that never comes up is reported, never waited on.
    for _ in $(seq 20); do [[ -S "$UIDMAP_SOCK" && -S "$CONTAINERS_SOCK" ]] && break; sleep 0.5; done
    if [[ -S "$UIDMAP_SOCK" && -S "$CONTAINERS_SOCK" ]]; then
        log "Containers          : rootless podman, DOCKER_HOST=$DOCKER_HOST (ids $CONTAINERS_SUBIDS)"
    else
        log "Containers          : WARNING, $([[ -S "$UIDMAP_SOCK" ]] || echo "no uid-map helper socket ")$([[ -S "$CONTAINERS_SOCK" ]] || echo "no podman socket ")after 10s; see $CONTAINERS_LOG_DIR/"
    fi
else
    rm -f "$CONTAINERS_PROFILE_D"
fi
