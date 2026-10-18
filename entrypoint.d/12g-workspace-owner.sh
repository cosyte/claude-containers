# shellcheck shell=bash
# --- 12g. Workspace and /state ownership, the deep passes (background) --------
# §9 owned the workspace root and its top level, and §2c the same of /state; the rest of both
# is checked here, after sshd and the sessions are up. Even a pass that changes nothing reads
# every inode, and on one spinning disk a monorepo with per-project node_modules held the boot
# for over 25 minutes with no sshd and no session (a real host, 2026-10-07); /state holds
# worktrees and working folders, so it can be as deep. One after the other, not at once, so
# the two never compete for the disk. Until a pass reaches it, a deeper file with a foreign
# owner (a bind mount from another uid) is read-only to the agent.
(
    own_start=$SECONDS
    own_tree "$WORKSPACE" 2>/dev/null || true
    log "Workspace ownership : checked in $(( SECONDS - own_start ))s (background)"
    own_start=$SECONDS
    own_tree "$STATE_DIR" 2>/dev/null || true
    log "State ownership     : checked in $(( SECONDS - own_start ))s (background)"
) &
