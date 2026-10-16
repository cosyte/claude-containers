# shellcheck shell=bash
# --- 8d. Custom slash commands ---------------------------------------------------
if compgen -G "$BAKE_DIR/commands/*.md" > /dev/null; then
    install -d -o "$CLAUDE_UID" -g "$CLAUDE_GID" "$CLAUDE_CONFIG_DIR/commands"
    for f in "$BAKE_DIR"/commands/*.md; do
        t="$CLAUDE_CONFIG_DIR/commands/$(basename "$f")"
        [[ -e "$t" ]] || install -o "$CLAUDE_UID" -g "$CLAUDE_GID" -m 644 "$f" "$t"
    done
    log "Installed baked-in slash commands"
fi
