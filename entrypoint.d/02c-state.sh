# shellcheck shell=bash
# --- 2c. Private state (/state) ----------------------------------------------
# /cache is ONE volume shared by every container on the host, and every container runs as the
# same UID, so whatever one container keeps there every other can read: right for tool caches,
# wrong for a database, a key or a token. /state is this container's own volume
# (claude-state-<name>, which claude-launch and claude-compose-gen mount here and in no other
# container): apps keep private state under $CLAUDE_STATE_DIR/<app>. Owned by the agent user,
# mode 700. Without the volume (an older compose file, a plain `docker run`) /state is the
# image's directory: it works, but it is lost when the container is recreated, so say so.
# STATE_DIR / STATE_MOUNTINFO / STATE_SHARED_CACHE are named on their own lines so
# test/state-unit.sh can run this exact block unprivileged against a sandbox.
STATE_DIR=/state
STATE_MOUNTINFO=/proc/self/mountinfo
STATE_SHARED_CACHE=/cache
export CLAUDE_STATE_DIR="$STATE_DIR"
# The isolation is the volume itself (no other container mounts it), so a directory that
# cannot be prepared degrades loudly instead of stopping the boot.
# Only the root and its top level here, as §9 does for the workspace: worktrees and working
# folders live under /state (/state/wt, /state/tmp), and even a pass that changes nothing
# reads every inode, minutes on a spinning disk before sshd or any session. The rest of the
# tree is checked in the background once the sessions are up (§12g).
if ! { mkdir -p "$STATE_DIR" && own_tree "$STATE_DIR" -maxdepth 1 && chmod 700 "$STATE_DIR"; } 2>/dev/null; then
    log "WARNING: could not prepare $STATE_DIR (owner $CLAUDE_USER, mode 700): apps cannot keep private state there."
elif awk -v d="$STATE_DIR" '$5 == d { found = 1 } END { exit !found }' "$STATE_MOUNTINFO" 2>/dev/null; then
    log "Private state       : $STATE_DIR (this container's own volume; CLAUDE_STATE_DIR)"
else
    log "WARNING: $STATE_DIR is not a volume: private state kept there is lost when the container is"
    log "WARNING: recreated. Regenerate the stack (claude-compose-gen) or relaunch (claude-launch)."
fi
# Private state an app still keeps in the shared cache under this container's name
# (/cache/<app>/<name>/, the layout apps used before /state existed) is readable from every
# other container. Name it at every boot until it is moved. Never move it here: the app would
# not know the new place and would start an empty one at the old path. Bounded: one glob over
# the cache's top level, then at most two levels under each match.
state_name="${CLAUDE_PROJECT_NAME:-$(hostname 2>/dev/null || true)}"
state_legacy=()
if [[ -n "$state_name" && "$state_name" != "." && "$state_name" != ".." && "$state_name" != */* ]]; then
    for state_d in "$STATE_SHARED_CACHE"/*/"$state_name"; do
        [[ -d "$state_d" && ! -L "$state_d" ]] || continue
        while IFS= read -r -d '' state_f; do state_legacy+=("$state_f"); done < <(
            timeout 10 find "$state_d" -maxdepth 2 -type f \( -name '*.db' -o -name '*.sqlite' \
                -o -name '*.sqlite3' -o -name '*.key' -o -name '*.pem' -o -name '*token*' \
                -o -name '*credential*' \) -print0 2>/dev/null || true)
    done
fi
if (( ${#state_legacy[@]} )); then
    log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    log "PRIVATE STATE IN THE SHARED CACHE: ${#state_legacy[@]} file(s) under $STATE_SHARED_CACHE/*/$state_name look like a"
    log "database or a key, and every container that mounts $STATE_SHARED_CACHE can read them:"
    for state_f in "${state_legacy[@]:0:5}"; do log "  $state_f"; done
    (( ${#state_legacy[@]} <= 5 )) || log "  ... and $(( ${#state_legacy[@]} - 5 )) more"
    log "Move them into $STATE_DIR (this container's own volume) and point the app there."
    log "How: docs/volume-reference.md, Private state."
    log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
fi
unset state_name state_legacy state_d state_f
