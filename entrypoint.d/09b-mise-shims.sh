# shellcheck shell=bash
# --- 9b. This container's mise shims ----------------------------------------------
# The shared /cache/mise/shims holds a shim for every tool any container installed, and a shim
# with no version set here answers `command -v` and then fails. PATH holds a per-container
# view instead ($CLAUDE_STATE_DIR/mise-shims) linking only the tools that resolve here: the
# global config and the workspace's configs, so after §9. The shared dir is never changed.
MISE_SHIMS_CMD=/usr/local/bin/claude-mise-shims
if mise_shims_out="$(asclaude timeout 120 "$MISE_SHIMS_CMD" 2>&1)"; then
    log "mise shims          : ${mise_shims_out#claude-mise-shims: }"
else
    log "WARNING: mise shims: $MISE_SHIMS_CMD failed (${mise_shims_out:-no output}); tools mise"
    log "WARNING: provides read as \"command not found\" until it is run again."
fi
unset mise_shims_out
