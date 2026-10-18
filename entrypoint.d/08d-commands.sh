# shellcheck shell=bash
# --- 8d. Custom slash commands ---------------------------------------------------
if compgen -G "$BAKE_DIR/commands/*.md" > /dev/null; then
    # The config dir is the agent's: a symlink where the commands dir goes is replaced, and a
    # name already present (a symlink included, even a dangling one) is never installed over.
    [[ -L "$CLAUDE_CONFIG_DIR/commands" ]] && rm -f "$CLAUDE_CONFIG_DIR/commands"
    install -d -o "$CLAUDE_UID" -g "$CLAUDE_GID" "$CLAUDE_CONFIG_DIR/commands"
    for f in "$BAKE_DIR"/commands/*.md; do
        t="$CLAUDE_CONFIG_DIR/commands/$(basename "$f")"
        [[ -e "$t" || -L "$t" ]] || install -o "$CLAUDE_UID" -g "$CLAUDE_GID" -m 644 "$f" "$t"
    done
    log "Installed baked-in slash commands"
fi
