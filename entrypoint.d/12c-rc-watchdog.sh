# shellcheck shell=bash
# --- 12c. Remote Control watchdog -------------------------------------------
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
    # shellcheck disable=SC2034  # stopped by shutdown() (§13)
    RC_WATCHDOG_PID=$!
    log "Remote Control watchdog started (disable with CLAUDE_RC_WATCHDOG=0)"
else
    log "Remote Control watchdog disabled (CLAUDE_RC_WATCHDOG=0)"
fi
