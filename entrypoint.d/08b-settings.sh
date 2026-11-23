# shellcheck shell=bash
# --- 8b. settings.json --------------------------------------------------------
# The baked file is the base, existing user settings win on
# conflict (recursive merge). Also injects unattended-operation defaults.
# NOTE: env intentionally does NOT include DISABLE_TELEMETRY/DO_NOT_TRACK.
# Those (and CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC) make Claude Code skip
# the GrowthBook fetch, so the `tengu_ccr_bridge` gate defaults false and
# Remote Control reports "not yet enabled for your account". RC is the point
# of this image, so they must never be set. See docs/troubleshooting.md.
PERM_MODE="${CLAUDE_PERMISSION_MODE:-bypassPermissions}"
# Auto-update is on by default, and §7d updates at every start (no DISABLE_AUTOUPDATER
# here, nor in §7a's managed policy above): see the notes in the Dockerfile above
# ARG CLAUDE_CODE_VERSION. An operator who wants a container to stay pinned to the
# baked CLAUDE_CODE_VERSION should set DISABLE_AUTOUPDATER=1 themselves (env, their
# own mounted settings.json, or, to make it non-overridable, their own file at
# §7a's $MANAGED_FILE).
BASE_SETTINGS="$(jq -n --arg pm "$PERM_MODE" '{
    permissions: { defaultMode: $pm },
    skipDangerousModePermissionPrompt: true,
    includeCoAuthoredBy: true
}')"
[[ -f "$BAKE_DIR/settings.json" ]] && \
    BASE_SETTINGS="$(jq -s '.[0] * .[1]' <(echo "$BASE_SETTINGS") "$BAKE_DIR/settings.json")"
EXISTING_SETTINGS='{}'
# A symlink at settings.json is not the agent's settings: start from {}. The agent reads the
# file (agent_cat, §0a's): a root read by that name would follow a symlink swapped in
# after this check and merge a root-only file into the agent's settings.
[[ -s "$CLAUDE_CONFIG_DIR/settings.json" && ! -L "$CLAUDE_CONFIG_DIR/settings.json" ]] && \
    EXISTING_SETTINGS="$(agent_cat "$CLAUDE_CONFIG_DIR/settings.json")"
# Self-heal 1: strip the Remote-Control-breaking telemetry kills from the final
# settings (covers per-container volumes created by an older image). If any
# were present, drop the cached GrowthBook flags + statsig cache so the next
# Claude run re-fetches them and RC eligibility resolves correctly.
#
# Self-heal 2: drop the stale `claude-md-fragments` SessionStart hook.
# Older images baked a settings.json whose only content was a
# SessionStart hook invoking /usr/local/bin/claude-md-fragments (the CLAUDE.d
# per-mode fragment loader). That binary was deleted, but the hook was already
# persisted into every per-project config VOLUME, and this merge lets existing
# user settings win, so it would survive forever and fire an ENOENT at every
# session start. Same class of residue, same fix, as the telemetry strip above.
STALE_HOOK_CMD="/usr/local/bin/claude-md-fragments"
# settings.json sits in the agent-owned config dir, so a session can replace it with a symlink,
# or swap one in while root works there. Root only computes the merge; the agent writes the
# result (agent_put: a fresh temp file renamed onto the name, which replaces a symlink there
# without following it). The type guards below keep jq from failing; if it fails anyway, the
# boot stops before anything is written, as it did.
SETTINGS_DST="$CLAUDE_CONFIG_DIR/settings.json"
SETTINGS_NEW="$(jq -s '.[0] * .[1]' <(echo "$BASE_SETTINGS") <(echo "$EXISTING_SETTINGS") \
    | jq 'if .env then .env |= (del(.DISABLE_TELEMETRY,.DO_NOT_TRACK,.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC)) else . end' \
    | jq --arg stale "$STALE_HOOK_CMD" '
        # Type-guard every level: a hand-corrupted settings.json (.hooks a string,
        # a SessionStart group that is not an object, ...) must pass through untouched
        # rather than error: a jq failure here would stop the boot.
        (if (.hooks | type) == "object" and (.hooks.SessionStart | type) == "array" then
             .hooks.SessionStart |= (
                 map(if type == "object" and ((.hooks | type) == "array")
                     then .hooks |= map(select((.command? // "") != $stale))
                     else . end)
                 | map(select((type != "object")
                              or ((.hooks | type) != "array")
                              or ((.hooks | length) > 0)))
             )
         else . end)
        | (if (.hooks | type) == "object" and (.hooks.SessionStart | type) == "array"
              and ((.hooks.SessionStart | length) == 0)
           then del(.hooks.SessionStart) else . end)
        | (if (.hooks | type) == "object" and ((.hooks | length) == 0)
           then del(.hooks) else . end)')"
printf '%s\n' "$SETTINGS_NEW" | agent_put "$SETTINGS_DST" 600
unset SETTINGS_NEW
if echo "$EXISTING_SETTINGS" \
    | jq -e --arg stale "$STALE_HOOK_CMD" \
        '[.hooks.SessionStart // [] | .[] | .hooks // [] | .[] | select((.command // "") == $stale)] | length > 0' \
        >/dev/null 2>&1; then
    log "Migrated settings.json: removed the stale '$STALE_HOOK_CMD' SessionStart hook (CLAUDE.d fragment loader, since removed)"
fi
if echo "$EXISTING_SETTINGS" | jq -e '.env // {} | (.DISABLE_TELEMETRY // .DO_NOT_TRACK // .CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC) != null' >/dev/null 2>&1; then
    log "Migrated settings.json: removed telemetry kills that block Remote Control; clearing stale feature-flag cache"
    # .claude.json is in the same agent-owned dir: the agent reads and writes it, root only
    # computes the change.
    if [[ -s "$CJSON" && ! -L "$CJSON" ]] \
       && CJSON_NEW="$(agent_cat "$CJSON" | jq 'del(.cachedGrowthBookFeatures,.cachedExperimentFeatures)')" \
       && [[ -n "$CJSON_NEW" ]]; then
        printf '%s\n' "$CJSON_NEW" | agent_put "$CJSON" 600 || true
    fi
    unset CJSON_NEW
    as_agent rm -rf "$CLAUDE_CONFIG_DIR/statsig" 2>/dev/null || true
fi
