# shellcheck shell=bash
# --- 13. Boot summary, stay alive, graceful shutdown -----------------------------
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
_named="$(asclaude /usr/local/bin/claude-sessions names 2>/dev/null | grep -vx main | tr '\n' ' ' || true)"
[[ -n "${_named// }" ]] && \
    log "Named sessions      : ${_named% }  (claude-sessions ls; Remote Control ${CLAUDE_PROJECT_NAME}-<name>)"
unset _named
[[ -n "${CLAUDE_DEV_CMD:-}" ]] && \
    log "Dev window          : tmux select-window -t claude:dev  (after SSH attach)"
echo

shutdown() {
    log "Shutting down"
    # Note every window's current conversation first, so the next boot resumes exactly it
    # (the supervisor only records every 15s). Bounded: a stop must never hang on this.
    timeout 5 gosu "$CLAUDE_USER" env CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" HOME="$CLAUDE_HOME" \
        /usr/local/bin/claude-sessions record >/dev/null 2>&1 || true
    asclaude tmux kill-server >/dev/null 2>&1 || true
    pkill -x sshd >/dev/null 2>&1 || true
    kill "$RECONCILE_PID" >/dev/null 2>&1 || true
    [[ -n "${ACCT_SWITCH_PID:-}" ]] && kill "$ACCT_SWITCH_PID" >/dev/null 2>&1 || true
    [[ -n "${RC_WATCHDOG_PID:-}" ]] && kill "$RC_WATCHDOG_PID" >/dev/null 2>&1 || true
    [[ -n "${USAGE_WATCHDOG_PID:-}" ]] && kill "$USAGE_WATCHDOG_PID" >/dev/null 2>&1 || true
    [[ -n "${SESSIONS_PID:-}" ]] && kill "$SESSIONS_PID" >/dev/null 2>&1 || true
    exit 0
}
trap shutdown TERM INT

# Keep PID 1 alive while the container should run. If the tmux server dies
# entirely (rare), exit so Docker's restart policy can recover it.
#
# Require several CONSECUTIVE failures, not one. This probe is not a pure read:
# `asclaude` is gosu + env + tmux, so every check costs three forks. When the container
# is out of PIDs: the cgroup pids.max counts THREADS, so a browser session reaches it long before the process count suggests: fork returns EAGAIN and
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
