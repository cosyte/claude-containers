# shellcheck shell=bash
# --- 8c. Plugins, baked and from the runtime kit ---------------------------------
# Declarative. Claude Code registers the marketplaces from settings.json on
# startup; a baked plugin from a git source may still need `claude plugin install` once
# (the runtime kit below installs what IT declares). We union the
# two plugin keys into existing settings; existing entries win on conflict.
if [[ -f "$BAKE_DIR/plugins/plugins.json" ]]; then
    jq -s '
        .[0] as $cur | .[1] as $plug |
        $cur
        | .extraKnownMarketplaces = (($plug.extraKnownMarketplaces // {}) + ($cur.extraKnownMarketplaces // {}))
        | .enabledPlugins         = (($plug.enabledPlugins // {})         + ($cur.enabledPlugins // {}))
    ' "$CLAUDE_CONFIG_DIR/settings.json" "$BAKE_DIR/plugins/plugins.json" \
        > "$CLAUDE_CONFIG_DIR/settings.json.tmp" \
        && mv -f "$CLAUDE_CONFIG_DIR/settings.json.tmp" "$CLAUDE_CONFIG_DIR/settings.json"
    chown "$CLAUDE_UID:$CLAUDE_GID" "$CLAUDE_CONFIG_DIR/settings.json"
    log "Merged baked-in plugin marketplaces/plugins into settings.json"
fi

# The runtime kit: no rebuild required (bin/claude-kit).
# CLAUDE_EXTRA_MARKETPLACES: "name=url[#ref][,...]"  git source; "#ref" pins a branch or tag
#                            and turns autoUpdate off (a pin and auto-update contradict).
# CLAUDE_EXTRA_PLUGINS:      "plugin@marketplace[,...]"
# A declared marketplace replaces the settings.json entry of that name (adding, moving or
# dropping #ref takes effect at the next start); for enabledPlugins an existing value wins.
# The plugins are installed by the CLI, as the agent user, in §12b before any session starts.
kit_declared() { [[ -n "${CLAUDE_EXTRA_MARKETPLACES:-}" || -n "${CLAUDE_EXTRA_PLUGINS:-}" ]]; }
if kit_declared; then
    if /usr/local/bin/claude-kit settings "$CLAUDE_CONFIG_DIR/settings.json"; then
        log "Merged runtime plugin marketplaces/plugins into settings.json"
    else
        log "WARNING: claude-kit could not merge CLAUDE_EXTRA_MARKETPLACES / CLAUDE_EXTRA_PLUGINS into settings.json"
    fi
    chown "$CLAUDE_UID:$CLAUDE_GID" "$CLAUDE_CONFIG_DIR/settings.json"
fi
