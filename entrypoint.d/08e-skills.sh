# shellcheck shell=bash
# --- 8e. Skills ---------------------------------------------------------------
# One directory per skill, each with a SKILL.md. A skill is installed only
# when what it needs is in this container (_skill_usable). One that is not is skipped,
# and an unmodified copy a past start installed is removed; an edited one is kept.
_skill_usable() {  # _skill_usable <name>
    case "$1" in
        frontend-debugging) [[ "$BROWSER_MCP" == on ]] ;;  # chromium + the DevTools MCP (§7b)
        *) return 0 ;;
    esac
}
if [[ -d "$BAKE_DIR/skills" ]]; then
    # The config dir is the agent's: a symlink where the skills dir goes is replaced, and a
    # skill name that is a symlink is left alone, never copied into or removed through.
    [[ -L "$CLAUDE_CONFIG_DIR/skills" ]] && rm -f "$CLAUDE_CONFIG_DIR/skills"
    install -d -o "$CLAUDE_UID" -g "$CLAUDE_GID" "$CLAUDE_CONFIG_DIR/skills"
    for d in "$BAKE_DIR"/skills/*/; do
        [[ -f "$d/SKILL.md" ]] || continue
        name="$(basename "$d")"
        t="$CLAUDE_CONFIG_DIR/skills/$name"
        [[ -L "$t" ]] && continue
        if ! _skill_usable "$name"; then
            if [[ -d "$t" ]] && diff -rq "$d" "$t" >/dev/null 2>&1; then
                rm -rf "$t"
                log "Skill $name: removed, this container lacks what it needs"
            fi
            continue
        fi
        if [[ ! -d "$t" ]]; then
            cp -a "$d" "$t"
            chown -R "$CLAUDE_UID:$CLAUDE_GID" "$t"
        fi
    done
    log "Installed baked-in skills"
fi
