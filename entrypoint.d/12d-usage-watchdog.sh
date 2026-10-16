# shellcheck shell=bash
# --- 12d. Usage-limit account-rotation watchdog (multi-account mode only) ----
# Rotates to a different pre-authenticated account when the active one hits
# its usage limit, resuming the same conversation. Only meaningful with
# CLAUDE_ACCOUNTS set (nothing to rotate to otherwise) and in interactive
# mode (autopilot has its own reset-time backoff, bin/claude-autopilot).
USAGE_WATCHDOG_PID=""
if [[ "$CLAUDE_MODE" == "autopilot" || -z "${CLAUDE_ACCOUNTS:-}" ]]; then
    : # nothing to watch
elif [[ "${CLAUDE_USAGE_WATCHDOG:-1}" != "0" ]]; then
    asclaude /usr/local/bin/claude-usage-watchdog &
    # shellcheck disable=SC2034  # stopped by shutdown() (§13)
    USAGE_WATCHDOG_PID=$!
    log "Usage-limit watchdog started (accounts: $CLAUDE_ACCOUNTS; disable with CLAUDE_USAGE_WATCHDOG=0)"
else
    log "Usage-limit watchdog disabled (CLAUDE_USAGE_WATCHDOG=0)"
fi
