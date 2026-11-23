# shellcheck shell=bash
# --- 8d. Custom slash commands ---------------------------------------------------
if compgen -G "$BAKE_DIR/commands/*.md" > /dev/null; then
    # The config dir is the agent's: a symlink where the commands dir goes is replaced, and a
    # name already present (a symlink included, even a dangling one) is never installed over.
    # The agent makes the directory and writes each file (as_agent, agent_put, §0a's): a root
    # `install -d -o` follows a symlink put at the name after the check, and chowns its target.
    [[ -L "$CLAUDE_CONFIG_DIR/commands" ]] && rm -f "$CLAUDE_CONFIG_DIR/commands"
    as_agent mkdir -p "$CLAUDE_CONFIG_DIR/commands"
    for f in "$BAKE_DIR"/commands/*.md; do
        t="$CLAUDE_CONFIG_DIR/commands/$(basename "$f")"
        [[ -e "$t" || -L "$t" ]] || agent_put "$t" 644 < "$f"
    done
    log "Installed baked-in slash commands"
fi
