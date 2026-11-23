# shellcheck shell=bash
# --- 6a. Account-switch listener (multi-account mode only) -------------------
# bin/claude-usage-watchdog runs as the unprivileged `claude` user, so it
# cannot itself read a NON-active account's locked-down master (each
# /auth-accounts/<name> is root:700 / root:600, same lockdown as the
# single-account master in §6): it requests a swap here instead. Runs as
# root specifically so it CAN read every account, unlike the watchdog.
# Request/done files live inside $CLAUDE_CONFIG_DIR: root can read/write there
# regardless of its claude:700 ownership, so no separate shared directory or
# group permissions are needed.
# Two requests, each through its own pair of files so neither answer meets the other's:
#   .account-switch-request  the usage watchdog's rotation: the credential is published here
#                            and the watchdog respawns its sessions itself.
#   .account-use-request     an operator's switch (claude-sessions account --use NAME): NAME
#                            becomes the active account, and §6's credential sync takes it over
#                            as it does a new login, moving each session at its next idle moment.
# It must outlive any one failed step. It runs in the background under the boot's
# `set -e`, so a failed write (a full config volume) used to end it with no word in
# the log, and every later rotation then timed out until the container restarted.
# So errexit is off in here (`local -` keeps that to this function), and each step
# that can fail is checked, logged, and answered with an error where it can be.
account_switch_listener() {
    local -
    set +e
    local req_file="$CLAUDE_CONFIG_DIR/.account-switch-request"
    local done_file="$CLAUDE_CONFIG_DIR/.account-switch-done"
    local use_req_file="$CLAUDE_CONFIG_DIR/.account-use-request"
    local use_done_file="$CLAUDE_CONFIG_DIR/.account-use-done"
    local names=() req uuid
    IFS=',' read -ra names <<< "$CLAUDE_ACCOUNTS"
    # Both files this writes sit in the agent's config dir, so each goes through a fresh temp
    # file renamed onto the target's own name (mv -T), never a fixed temp name and never into
    # whatever the target points at. 644: the watchdog reads them.
    _switch_write() {  # _switch_write <dst> <text>
        local t; t="$(mktemp "$1.XXXXXX" 2>/dev/null)" || return 1
        { printf '%s\n' "$2" > "$t" && chmod 644 "$t" && mv -fT "$t" "$1"; } 2>/dev/null && return 0
        rm -f "$t" 2>/dev/null
        return 1
    }
    _switch_answer() {  # _switch_answer <answer file> <text>
        _switch_write "$1" "$2" && return 0
        log "WARNING: account switch: could not write the answer '$2' to $1 (is the config volume full?): the request will time out"
        return 0
    }
    # A request is a file the agent wrote, so it may be anything: a symlink to a root-only file,
    # a FIFO, a huge file. Root reads only a regular file, at most 64 bytes, its first line, and
    # an answer never repeats what it read unless it names a configured account.
    _switch_read() {  # _switch_read <request file>: prints the name asked for; the file is removed
        local r=""
        if [[ -f "$1" && ! -L "$1" ]]; then r="$(timeout 2 head -c 64 -- "$1" 2>/dev/null | head -n 1)"; fi
        rm -f "$1"
        printf '%s' "$r"
    }
    # Validate against CLAUDE_ACCOUNTS before touching any path: an unvalidated name
    # interpolated into /auth-accounts/$req/... would be a path-traversal risk.
    _is_account() {  # _is_account <name>: exactly one of CLAUDE_ACCOUNTS' names
        local n
        for n in "${names[@]}"; do [[ -n "$1" && "$1" == "$n" ]] && return 0; done
        return 1
    }
    while sleep 2; do
        if [[ -s "$req_file" ]]; then
            req="$(_switch_read "$req_file")"
            if ! _is_account "$req"; then
                _switch_answer "$done_file" "ERROR:unknown-account"
            elif ! creds_have_token "/auth-accounts/$req/.credentials.json"; then
                _switch_answer "$done_file" "ERROR:no-token:$req"
            elif ! publish_creds "/auth-accounts/$req/.credentials.json" "$CLAUDE_CONFIG_DIR/.credentials.json"; then
                log "WARNING: account switch to '$req': could not publish its credentials (is the config volume full?)"
                _switch_answer "$done_file" "ERROR:publish-failed:$req"
            else
                # The watchdog respawns what it rotates; this is not an operator's account change.
                set_local_account "$(account_of "/auth-accounts/$req")"
                _switch_write "$CLAUDE_CONFIG_DIR/.active-account" "$req" \
                    || log "WARNING: account switch to '$req': could not record it in .active-account"
                _switch_answer "$done_file" "$req"
            fi
        fi
        if [[ -s "$use_req_file" ]]; then
            # An operator's switch: only validated and recorded here. §6's credential sync sees the
            # new active account on its next pass and follows it as it follows a new login (the
            # credential, the cached identity, then each session at its next idle moment, its old
            # account's refreshes never pushed up meanwhile). So it is refused wherever that sync
            # would not follow: CLAUDE_AUTH_FOLLOW off, or no account recorded beside the credential.
            req="$(_switch_read "$use_req_file")"
            uuid=""
            if ! _is_account "$req"; then
                _switch_answer "$use_done_file" "ERROR:unknown-account"
            elif ! creds_have_token "/auth-accounts/$req/.credentials.json"; then
                _switch_answer "$use_done_file" "ERROR:no-token:$req"
            elif [[ "${CLAUDE_AUTH_FOLLOW:-1}" =~ ^(0|false|no|off)$ ]]; then
                _switch_answer "$use_done_file" "ERROR:follow-off:$req"
            elif uuid="$(account_of "/auth-accounts/$req")"; [[ -z "$uuid" ]]; then
                _switch_answer "$use_done_file" "ERROR:no-identity:$req"
            elif ! _switch_write "$CLAUDE_CONFIG_DIR/.active-account" "$req"; then
                log "WARNING: account switch to '$req': could not record it in .active-account (is the config volume full?)"
                _switch_answer "$use_done_file" "ERROR:record-failed:$req"
            else
                log "Auth account        : '$req' is the active account now (claude-sessions account --use); the credential sync takes it over"
                _switch_answer "$use_done_file" "$req $uuid"
            fi
        fi
    done
}
ACCT_SWITCH_PID=""
if [[ -n "${CLAUDE_ACCOUNTS:-}" ]]; then
    account_switch_listener &
    # shellcheck disable=SC2034  # stopped by shutdown() (§13)
    ACCT_SWITCH_PID=$!
fi
