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
account_switch_listener() {
    local req_file="$CLAUDE_CONFIG_DIR/.account-switch-request"
    local done_file="$CLAUDE_CONFIG_DIR/.account-switch-done"
    _switch_answer() { echo "$1" > "$done_file.tmp" && mv -f "$done_file.tmp" "$done_file"; }
    while sleep 2; do
        [[ -s "$req_file" ]] || continue
        local req; req="$(cat "$req_file" 2>/dev/null)"; rm -f "$req_file"
        # Validate against CLAUDE_ACCOUNTS before touching any path: an
        # unvalidated name interpolated into /auth-accounts/$req/... would be a
        # path-traversal risk if a request were ever forged.
        case ",${CLAUDE_ACCOUNTS}," in
            *",${req},"*) ;;
            *) _switch_answer "ERROR:unknown-account:$req"; continue ;;
        esac
        local src="/auth-accounts/$req/.credentials.json"
        if creds_have_token "$src"; then
            publish_creds "$src" "$CLAUDE_CONFIG_DIR/.credentials.json"
            # The watchdog respawns what it rotates; this is not an operator's account change.
            set_local_account "$(account_of "/auth-accounts/$req")"
            echo "$req" > "$CLAUDE_CONFIG_DIR/.active-account.tmp" \
                && mv -f "$CLAUDE_CONFIG_DIR/.active-account.tmp" "$CLAUDE_CONFIG_DIR/.active-account"
            _switch_answer "$req"
        else
            _switch_answer "ERROR:no-token:$req"
        fi
    done
}
ACCT_SWITCH_PID=""
if [[ -n "${CLAUDE_ACCOUNTS:-}" ]]; then
    account_switch_listener &
    # shellcheck disable=SC2034  # stopped by shutdown() (§13)
    ACCT_SWITCH_PID=$!
fi
