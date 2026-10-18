# shellcheck shell=bash
# --- 1. Refuse API-key auth --------------------------------------------------
# This image is OAuth-subscription only. An API key would silently override the
# subscription and bill per-token, so fail fast and loud.
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    die "ANTHROPIC_API_KEY is set. This image uses OAuth subscription auth only.
       Unset ANTHROPIC_API_KEY (it is not needed and would override your
       Claude subscription with per-token API billing)."
fi

# --- Login mode --------------------------------------------------------------
# `make login` runs the image with CLAUDE_LOGIN_MODE=1 to perform the one-time
# OAuth flow and write credentials to the shared claude-auth volume.
if [[ "${CLAUDE_LOGIN_MODE:-0}" == "1" ]]; then
    mkdir -p "$AUTH_DIR"
    chown -R "$CLAUDE_UID:$CLAUDE_GID" "$AUTH_DIR"
    log "Starting OAuth login. Open the printed URL in a browser, then paste"
    log "the code back here. Credentials persist to the claude-auth volume."
    exec gosu "$CLAUDE_USER" env PATH="$CLAUDE_AGENT_PATH" CLAUDE_CONFIG_DIR="$AUTH_DIR" HOME="$CLAUDE_HOME" \
        claude auth login --claudeai
fi
