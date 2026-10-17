# shellcheck shell=bash
# --- 12h. Orphan reaper ---------------------------------------------------------
# A Bash tool call that times out leaves its children re-parented to PID 1; a whole-disk
# `find /` left that way ran for 10 h and kept the host's disk busy. claude-orphan-reaper ends
# the agent's PID-1 children older than CLAUDE_ORPHAN_MAX_AGE (default 2h) every 5 minutes,
# sparing tmux, the sessions and the names in CLAUDE_ORPHAN_KEEP. Its kills go to this log.
ORPHAN_REAPER_PID=""
if [[ "${CLAUDE_ORPHAN_MAX_AGE:-2h}" =~ ^0+[smhd]?$ ]]; then
    log "Orphan reaper disabled (CLAUDE_ORPHAN_MAX_AGE=0)"
else
    asclaude /usr/local/bin/claude-orphan-reaper &
    # shellcheck disable=SC2034  # stopped by shutdown() (§13)
    ORPHAN_REAPER_PID=$!
    log "Orphan reaper started (agent processes orphaned over ${CLAUDE_ORPHAN_MAX_AGE:-2h}; off with CLAUDE_ORPHAN_MAX_AGE=0)"
fi
