# shellcheck shell=bash
# --- 7. Seed .claude.json (onboarding + workspace trust) ---------------------
# With CLAUDE_CONFIG_DIR set, Claude stores .claude.json *inside* it. Pre-accept
# the workspace trust dialog and onboarding non-interactively, and lift the
# oauthAccount written by `make login` so the account shows correctly. Only
# fills missing keys, never clobbers existing per-container state.
#
# Self-heal 3: refresh a STALE cached oauthAccount when the mounted auth source
# has since moved to a different account. Without this, a container created
# against one AUTH_VOLUME and later switched to another (a named account via
# claude-account-login, or --accounts) keeps showing the OLD account in the
# Claude app and to `claude doctor`/`/status` forever: the actual bearer token
# in .credentials.json is correctly the new account (that file gets reconciled
# fresh from $AUTH_DIR every boot, see §6), but this
# $CLAUDE_CONFIG_DIR/.claude.json lives on the PERSISTENT per-container config
# volume, and the plain "fill only if missing" rule below would leave whatever
# account was cached here on the container's FIRST boot in place indefinitely.
# Comparing accountUuid (not the whole object: hasExtraUsageEnabled and similar
# fields legitimately change over an account's lifetime and must not force a
# refresh) is what tells "the operator switched accounts" apart from "nothing
# to do here".
CJSON="$CLAUDE_CONFIG_DIR/.claude.json"
# The config dir is the agent's: a symlink at .claude.json is not one of its files, so it is
# replaced, and the merge below goes through a fresh temp file renamed onto the name (mv -T).
[[ -L "$CJSON" ]] && rm -f "$CJSON"
if [[ ! -s "$CJSON" ]]; then
    CJSON_TMP="$(mktemp "$CJSON.XXXXXX")"
    echo '{}' > "$CJSON_TMP" && mv -fT "$CJSON_TMP" "$CJSON"
fi
OAUTH_ACCOUNT='{}'
[[ -s "$AUTH_DIR/.claude.json" ]] && \
    OAUTH_ACCOUNT="$(jq -c '.oauthAccount // {}' "$AUTH_DIR/.claude.json" 2>/dev/null || echo '{}')"
CACHED_UUID="$(jq -r '.oauthAccount.accountUuid // empty' "$CJSON" 2>/dev/null || true)"
FRESH_UUID="$(jq -r '.accountUuid // empty' <<<"$OAUTH_ACCOUNT" 2>/dev/null || true)"
if [[ -n "$FRESH_UUID" && -n "$CACHED_UUID" && "$FRESH_UUID" != "$CACHED_UUID" ]]; then
    log "Cached account       : SELF-HEALED (was accountUuid ${CACHED_UUID:0:8}…, mounted auth is now ${FRESH_UUID:0:8}…): refreshing the cached identity to match"
fi
CJSON_TMP="$(mktemp "$CJSON.XXXXXX")"
jq --argjson oauth "$OAUTH_ACCOUNT" \
   --arg cached_uuid "$CACHED_UUID" --arg fresh_uuid "$FRESH_UUID" '
    .hasCompletedOnboarding = (.hasCompletedOnboarding // true)
  | .oauthAccount = (
        if ($fresh_uuid != "" and $cached_uuid != "" and $fresh_uuid != $cached_uuid) then $oauth
        else (.oauthAccount // (if ($oauth|length>0) then $oauth else null end))
        end
    )
  | .projects = (.projects // {})
  | .projects["'"$WORKSPACE"'"] = ((.projects["'"$WORKSPACE"'"] // {}) + {
        hasTrustDialogAccepted: true,
        hasCompletedProjectOnboarding: true,
        hasClaudeMdExternalIncludesApproved: true,
        hasClaudeMdExternalIncludesWarningShown: true
    })
' "$CJSON" > "$CJSON_TMP" && mv -fT "$CJSON_TMP" "$CJSON" || rm -f "$CJSON_TMP"
unset CJSON_TMP
chown -h "$CLAUDE_UID:$CLAUDE_GID" "$CJSON"
