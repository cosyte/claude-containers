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
# `make login`, `claude-account-login` and a stack's own login (`docker compose run ... -e
# CLAUDE_LOGIN_MODE=1 -v <auth volume>:/auth <service>`) run the image this way to perform the
# one-time OAuth flow and write the credential to an auth volume. The volume is root's, mode 700,
# before, during and after: running containers mount the same volume, and their agents must never
# reach the master in it. So the volume is locked first (which also repairs one an older login
# left to the agent), the login runs as the agent in a private directory of its own, and root
# takes the result over: read by the agent (agent_cat), checked in root's own file, written into
# the volume as root's, mode 600 (root_put). The private directory is under /tmp, never TMPDIR:
# a stack's TMPDIR is a /scratch volume its running containers share. The CLI is the image's
# launcher on root's system PATH, never one from a directory a running agent can write.
# LOGIN_CLI and LOGIN_TMP are named on their own lines so test/agent-paths-unit.sh can run this
# exact block against a sandbox.
LOGIN_CLI=/usr/local/bin/claude
LOGIN_TMP=/tmp
if [[ "${CLAUDE_LOGIN_MODE:-0}" == "1" ]]; then
    mkdir -p "$AUTH_DIR"
    lock_master "$AUTH_DIR"
    [[ "$(stat -c '%u %a' "$AUTH_DIR")" == "$EUID 700" ]] \
        || die "could not make the auth volume at $AUTH_DIR root's (mode 700): no login"
    chown -hR root:root "$AUTH_DIR" 2>/dev/null || true
    _ld="$(mktemp -d "$LOGIN_TMP/claude-login.XXXXXX")" && chown "$CLAUDE_UID:$CLAUDE_GID" "$_ld" \
        || die "could not make a private directory for the login under $LOGIN_TMP"
    _lr="$(mktemp -d "$LOGIN_TMP/claude-login-root.XXXXXX")" || die "could not make root's directory under $LOGIN_TMP"
    log "Starting OAuth login. Open the printed URL in a browser, then paste"
    log "the code back here. The credential is kept in the auth volume (root's, mode 600)."
    if ! as_agent env CLAUDE_CONFIG_DIR="$_ld" HOME="$CLAUDE_HOME" "$LOGIN_CLI" auth login --claudeai; then
        as_agent rm -rf "$_ld"; rm -rf "$_lr"
        die "the login did not complete: the auth volume is unchanged"
    fi
    agent_cat "$_ld/.credentials.json" > "$_lr/credentials" 2>/dev/null || : > "$_lr/credentials"
    if ! grep -q '"accessToken"[[:space:]]*:[[:space:]]*"[^"]' "$_lr/credentials"; then
        as_agent rm -rf "$_ld"; rm -rf "$_lr"
        die "the login left no credential with a token: the auth volume is unchanged"
    fi
    agent_cat "$_ld/.claude.json" > "$_lr/claude.json" 2>/dev/null || : > "$_lr/claude.json"
    root_put "$AUTH_DIR/.credentials.json" < "$_lr/credentials" \
        || { as_agent rm -rf "$_ld"; rm -rf "$_lr"; die "could not write the credential into $AUTH_DIR"; }
    # The account the credential belongs to (oauthAccount), which a running container follows.
    if jq -e '.oauthAccount.accountUuid' "$_lr/claude.json" >/dev/null 2>&1; then
        root_put "$AUTH_DIR/.claude.json" < "$_lr/claude.json" \
            || log "WARNING: could not write the account's .claude.json into $AUTH_DIR"
    else
        log "WARNING: the login left no account identity (.claude.json): containers follow this credential only after a restart"
    fi
    as_agent rm -rf "$_ld"; rm -rf "$_lr"
    log "Login complete: the credential is in the auth volume, root's, mode 600."
    exit 0
fi
