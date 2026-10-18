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
# Auto-update is on by default (no DISABLE_AUTOUPDATER here, nor in §7a's managed
# policy above): see the AUTO-UPDATER NOW ON BY DEFAULT note in the Dockerfile above
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
[[ -s "$CLAUDE_CONFIG_DIR/settings.json" ]] && \
    EXISTING_SETTINGS="$(cat "$CLAUDE_CONFIG_DIR/settings.json")"
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
# settings.json sits in the agent-owned config dir, so a session can replace it with a symlink
# that survives a restart; a bare `> settings.json` as root would then truncate and write the
# link's target. Build into a fresh temp in the same directory (mktemp makes it O_EXCL, so it
# cannot be a planted symlink) and rename over settings.json, which replaces a symlink at that
# name without ever following it. Same 0-byte-on-jq-failure behaviour as the old `>` (the type
# guards below keep jq from failing), but never writing outside the config dir.
SETTINGS_DST="$CLAUDE_CONFIG_DIR/settings.json"
SETTINGS_TMP="$(mktemp "$CLAUDE_CONFIG_DIR/.settings.json.XXXXXX")"
jq -s '.[0] * .[1]' <(echo "$BASE_SETTINGS") <(echo "$EXISTING_SETTINGS") \
    | jq 'if .env then .env |= (del(.DISABLE_TELEMETRY,.DO_NOT_TRACK,.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC)) else . end' \
    | jq --arg stale "$STALE_HOOK_CMD" '
        # Type-guard every level: a hand-corrupted settings.json (.hooks a string,
        # a SessionStart group that is not an object, ...) must pass through untouched
        # rather than error: a jq failure here would leave the `>` redirect below
        # having truncated settings.json to 0 bytes.
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
           then del(.hooks) else . end)' \
    > "$SETTINGS_TMP"
mv -f "$SETTINGS_TMP" "$SETTINGS_DST"
if echo "$EXISTING_SETTINGS" \
    | jq -e --arg stale "$STALE_HOOK_CMD" \
        '[.hooks.SessionStart // [] | .[] | .hooks // [] | .[] | select((.command // "") == $stale)] | length > 0' \
        >/dev/null 2>&1; then
    log "Migrated settings.json: removed the stale '$STALE_HOOK_CMD' SessionStart hook (CLAUDE.d fragment loader, since removed)"
fi
chown "$CLAUDE_UID:$CLAUDE_GID" "$CLAUDE_CONFIG_DIR/settings.json"
if echo "$EXISTING_SETTINGS" | jq -e '.env // {} | (.DISABLE_TELEMETRY // .DO_NOT_TRACK // .CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC) != null' >/dev/null 2>&1; then
    log "Migrated settings.json: removed telemetry kills that block Remote Control; clearing stale feature-flag cache"
    [[ -s "$CJSON" ]] && jq 'del(.cachedGrowthBookFeatures,.cachedExperimentFeatures)' "$CJSON" > "$CJSON.tmp" \
        && mv -f "$CJSON.tmp" "$CJSON" && chown "$CLAUDE_UID:$CLAUDE_GID" "$CJSON"
    rm -rf "$CLAUDE_CONFIG_DIR/statsig" 2>/dev/null || true
fi
