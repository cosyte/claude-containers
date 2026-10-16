# shellcheck shell=bash
# --- 7c. Session memory: what this container has (+ the GPU and containers notes) ---
# Every session reads Claude Code's MANAGED memory file (root-owned, read above the
# user's own CLAUDE.md). At every boot it gets a "This container" section that
# claude-container-facts writes from probes run now (browser, chrome-devtools MCP, GPU,
# toolchains, /cache and /scratch, how to install more), then the GPU note on a --gpu
# session and the containers note on a --containers one. It lives in the container layer
# and is rewritten on every boot, but never over a file an operator put there: ours
# carries one of the two markers.
# The paths are named on their own lines so test/container-facts-unit.sh can run this
# exact block unprivileged against a sandbox.
SESSION_MD=/etc/claude-code/CLAUDE.md
SESSION_MD_OWNER=root:root
FACTS_CMD=/usr/local/bin/claude-container-facts
GPU_NOTE_SRC=/opt/claude-config/CLAUDE.gpu.md
CONTAINERS_NOTE_SRC=/opt/claude-config/CLAUDE.containers.md
FACTS_MARK="claude-containers: container facts"
GPU_NOTE_MARK="claude-containers: GPU session note"
if [[ -e "$SESSION_MD" ]] && ! grep -qF -e "$FACTS_MARK" -e "$GPU_NOTE_MARK" "$SESSION_MD" 2>/dev/null; then
    log "Session memory      : NOT written, $SESSION_MD is an operator's own file"
else
    smd_tmp="$(mktemp)"
    # Bounded: each probe has its own 5s limit, this caps the whole run.
    if ! CLAUDE_FACTS_BROWSER_MCP="$BROWSER_MCP" CLAUDE_FACTS_GPU_STATE="$GPU_STATE_FILE" \
            timeout 60 "$FACTS_CMD" > "$smd_tmp" 2>/dev/null; then
        printf '<!-- %s -->\n## This container\n\n- The probe (claude-container-facts) failed at this start: nothing is known about this container.\n' \
            "$FACTS_MARK" > "$smd_tmp"
    fi
    smd_what="container facts"
    if [[ "${CLAUDE_GPU:-0}" =~ ^(1|true|yes|on)$ && -f "$GPU_NOTE_SRC" ]]; then
        { echo; cat "$GPU_NOTE_SRC"; } >> "$smd_tmp"
        smd_what="container facts + GPU note"
    fi
    if [[ "${CLAUDE_CONTAINERS:-0}" =~ ^(1|true|yes|on)$ && -f "$CONTAINERS_NOTE_SRC" ]]; then
        { echo; cat "$CONTAINERS_NOTE_SRC"; } >> "$smd_tmp"
        smd_what="$smd_what + containers note"
    fi
    if mkdir -p "${SESSION_MD%/*}" && chmod 755 "${SESSION_MD%/*}" \
            && install -m 644 "$smd_tmp" "$SESSION_MD" && chown "$SESSION_MD_OWNER" "$SESSION_MD"; then
        log "Session memory      : $SESSION_MD ($smd_what)"
    else
        log "Session memory      : WARNING, could not write $SESSION_MD"
    fi
    rm -f "$smd_tmp"
    unset smd_tmp smd_what
fi
