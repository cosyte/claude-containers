# shellcheck shell=bash
# --- 10. Register baked-in MCP servers ---------------------------------------
# Done via the CLI so the on-disk schema is always correct for this Claude
# version. ${VARS} in the JSON are expanded from runtime env (secrets are
# never baked into the image). CLAUDE_MCP_ENABLED (csv) filters which to load.
if [[ -d "$BAKE_DIR/mcp" ]]; then
    for f in "$BAKE_DIR"/mcp/*.json; do
        [[ -e "$f" ]] || continue
        name="$(basename "$f" .json)"
        if [[ -n "${CLAUDE_MCP_ENABLED:-}" ]]; then
            case ",${CLAUDE_MCP_ENABLED}," in *",$name,"*) ;; *) continue ;; esac
        fi
        if asclaude claude mcp get "$name" >/dev/null 2>&1; then
            log "MCP '$name' already configured, skipping"
            continue
        fi
        json="$(envsubst < "$f")"
        if asclaude claude mcp add-json --scope user "$name" "$json" >/dev/null 2>&1; then
            log "Registered MCP server '$name'"
        else
            log "WARNING: failed to register MCP server '$name'"
        fi
    done
fi
