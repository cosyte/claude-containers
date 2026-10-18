# shellcheck shell=bash
# --- 8a. Global CLAUDE.md --------------------------------------------------
# Everything baked into the image (§8a to §8e) is overridable at runtime by mounting onto the
# target path: only what is absent is filled.
# The image's copy at EVERY start (not only the first), so a
# change to claude-config/CLAUDE.md reaches an existing container at its next start.
# The one exception is the override: a file the operator mounted over the path (a
# bind mount, so it has its own line in mountinfo) is left alone.
MOUNTINFO=/proc/self/mountinfo
if [[ -f "$BAKE_DIR/CLAUDE.md" ]]; then
    gmd="$CLAUDE_CONFIG_DIR/CLAUDE.md"
    if awk -v p="$gmd" '$5 == p { f = 1 } END { exit !f }' "$MOUNTINFO" 2>/dev/null; then
        log "Global CLAUDE.md    : left alone, $gmd is mounted (the operator's own)"
    elif [[ -L "$gmd" ]] || ! cmp -s "$BAKE_DIR/CLAUDE.md" "$gmd"; then
        # The config dir is the agent's: a symlink at the path is replaced, never installed through.
        [[ -L "$gmd" ]] && rm -f "$gmd"
        # Never fatal: a full volume (or a directory at the path) must not stop the boot.
        if install -o "$CLAUDE_UID" -g "$CLAUDE_GID" -m 644 "$BAKE_DIR/CLAUDE.md" "$gmd" 2>/dev/null; then
            log "Global CLAUDE.md    : installed the image's copy"
        else
            log "Global CLAUDE.md    : WARNING, could not install the image's copy at $gmd"
        fi
    fi
    unset gmd
fi
