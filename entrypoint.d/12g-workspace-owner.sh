# shellcheck shell=bash
# --- 12g. Workspace ownership, the deep pass (background) ---------------------
# §9 owned the workspace root and its top level; the rest is checked here, after sshd and the
# sessions are up. Even a pass that changes nothing reads every inode, and on one spinning disk
# a monorepo with per-project node_modules held the boot for over 25 minutes with no sshd and
# no session (a real host, 2026-10-07). Until the pass reaches it, a deeper file with a foreign
# owner (a bind mount from another uid) is read-only to the agent.
(
    ws_own_start=$SECONDS
    own_tree "$WORKSPACE" 2>/dev/null || true
    log "Workspace ownership : checked in $(( SECONDS - ws_own_start ))s (background)"
) &
