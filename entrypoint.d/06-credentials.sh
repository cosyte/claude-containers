# shellcheck shell=bash
# --- 6. Credentials reconcile (shared auth volume) ---------------------------
# Credentials are shared across all containers via the claude-auth volume; the
# rest of the config dir is per-container so sessions never collide. Claude
# rewrites .credentials.json on token refresh, so a small loop keeps the
# per-container file and the shared volume converged (newest wins).
if [[ ! -s "$AUTH_DIR/.credentials.json" ]]; then
    if [[ "${CLAUDE_SKIP_AUTH_CHECK:-0}" == "1" ]]; then
        log "WARNING: no credentials for the active account (auth check skipped)"
    elif [[ -n "${CLAUDE_ACCOUNTS:-}" ]]; then
        die "No credentials for account '$ACTIVE_ACCOUNT' (checked $AUTH_DIR/.credentials.json).
       Run 'claude-account-login $ACTIVE_ACCOUNT' once before launching containers."
    else
        die "No credentials in the claude-auth volume. Run 'make login' once
       before launching containers (see README Quick start)."
    fi
fi
if [[ -s "$AUTH_DIR/.credentials.json" && ! -s "$CLAUDE_CONFIG_DIR/.credentials.json" ]]; then
    # The config dir is the agent's: never install through a symlink at that name.
    [[ -L "$CLAUDE_CONFIG_DIR/.credentials.json" ]] && rm -f "$CLAUDE_CONFIG_DIR/.credentials.json"
    install -o "$CLAUDE_UID" -g "$CLAUDE_GID" -m 600 \
        "$AUTH_DIR/.credentials.json" "$CLAUDE_CONFIG_DIR/.credentials.json"
fi
# Defense-in-depth: lock the SHARED fleet-wide credential master to root-only so
# a prompt-injected agent can't read or even list it. The agent keeps its OWN
# per-container session token ($CLAUDE_CONFIG_DIR/.credentials.json, claude:600,
# unavoidable: Claude Code authenticates with it), but cannot reach the master
# that backs every other container. `make login` (root-chowns /auth) is separate.
# In multi-account mode every account dir gets the same lockdown, not just the active one:
# the agent must never read a not-currently-active account's credential either.
masters=("$AUTH_DIR")
[[ -z "${CLAUDE_ACCOUNTS:-}" ]] || masters=("${ACCOUNT_NAMES[@]/#//auth-accounts/}")
for d in "${masters[@]}"; do
    chown root:root "$d" 2>/dev/null || true
    chmod 700 "$d" 2>/dev/null || true
    [[ -e "$d/.credentials.json" ]] && { chown root:root "$d/.credentials.json" 2>/dev/null || true; chmod 600 "$d/.credentials.json" 2>/dev/null || true; }
done
unset masters d

# >>> credential sync (test/sessions-unit.sh runs this block against a sandbox)
# A .credentials.json is USABLE only if it carries a non-empty OAuth access
# token. When a token refresh fails, Claude Code rewrites the file in place with
# EMPTY token fields (accessToken/refreshToken => ""): i.e. it logs the session
# out but leaves a well-formed, freshly-mtimed JSON behind. Without this guard
# the reconcile loop treated that tokenless file as the "newest wins" copy and
# published it to the shared /auth master and thence to every other container:
# turning one account's token expiry into a fleet-wide "Login expired" blackout
# (observed 2026-07-15). The guard makes the loop refuse to propagate a tokenless
# credential and instead REPAIR a tokenless/absent copy from whichever side still
# holds a real token, so a per-container logout self-heals from the good master
# and only a genuine refresh-token expiry (fixed by `make login`) can take auth
# down. See docs/troubleshooting.md.
creds_have_token() {  # creds_have_token <file>  -> 0 if it holds a non-empty access token
    [[ -s "$1" ]] && grep -q '"accessToken"[[:space:]]*:[[:space:]]*"[^"]' "$1"
}

# Publish SRC over DST atomically: a unique tmp in DST's own dir (so a shared
# /auth is never left with a half-written file, and no fixed tmp name can be
# picked up by a concurrent container), then rename. Ownership follows DST: the
# shared master stays root:600, the per-container copy claude:600.
publish_creds() {  # publish_creds <src> <dst>
    local src="$1" dst="$2" t
    t="$(mktemp "$dst.XXXXXX")" || return 1
    # mv -T: rename onto DST's own name, never into a directory or symlink found there.
    if [[ "$dst" == "$CLAUDE_CONFIG_DIR/.credentials.json" ]]; then
        { install -o "$CLAUDE_UID" -g "$CLAUDE_GID" -m 600 "$src" "$t" && mv -fT "$t" "$dst"; } || { rm -f "$t"; return 1; }
    else
        { install -m 600 "$src" "$t" && mv -fT "$t" "$dst"; } || { rm -f "$t"; return 1; }
    fi
}

# Which ACCOUNT each credential belongs to. The shared master's account is in the .claude.json
# that `make login` / claude-account-login write beside it (oauthAccount.accountUuid). The
# container records the account its OWN credential came from in ACCT_FILE whenever it takes the
# master's. When the two differ, the operator logged a different account into the shared volume,
# and the container follows with no restart: it takes the new credential, updates its cached
# identity, and writes SWITCH_FILE, from which `claude-sessions supervise` restarts each session
# onto the new account at its next idle moment (resuming its conversation; Remote Control mints
# a fresh link under the new account). Until every Claude process has restarted, the loop NEVER
# pushes the container's own credential up: a session still running on the old account
# refreshes the OLD account's token into it, and pushing that would undo the operator's login.
ACCT_FILE="${ACCT_FILE:-$CLAUDE_CONFIG_DIR/.credentials-account}"
SWITCH_FILE="${SWITCH_FILE:-$CLAUDE_CONFIG_DIR/.account-changed}"
CLAUDE_BIN_RE="${CLAUDE_BIN_RE:-^/opt/claude-code/bin/claude$}"
SWITCH_AT=0
master_dir() {
    if [[ -n "${CLAUDE_ACCOUNTS:-}" ]]; then
        # .active-account sits in the agent's config dir: use it only when it names a configured
        # account, as the account-switch listener (§6a) requires of a request.
        local a; a="$(cat "$CLAUDE_CONFIG_DIR/.active-account" 2>/dev/null || true)"
        case "$a" in
            ""|*,*) a="${ACCOUNT_NAMES[0]}" ;;
            *) case ",${CLAUDE_ACCOUNTS}," in *",${a},"*) ;; *) a="${ACCOUNT_NAMES[0]}" ;; esac ;;
        esac
        echo "/auth-accounts/$a"
    else
        echo "$AUTH_DIR"
    fi
}
account_of() { jq -r '.oauthAccount.accountUuid // empty' "$1/.claude.json" 2>/dev/null || true; }
email_of()   { jq -r '.oauthAccount.emailAddress // empty' "$1/.claude.json" 2>/dev/null || true; }
local_account() {  # the account the container's own credential came from
    local a=""; [[ -L "$ACCT_FILE" ]] || a="$(cat "$ACCT_FILE" 2>/dev/null || true)"
    [[ -n "$a" ]] || a="$(account_of "$CLAUDE_CONFIG_DIR")"
    printf '%s' "$a"
}
# These write into the agent's config dir while sessions run, so each goes through a fresh
# temp file (mktemp: a new name, never an existing one) renamed onto the target's own name
# (mv -T); a fixed or guessable temp name, or a bare `>`, could be a symlink there.
set_local_account() {
    local t; t="$(mktemp "$ACCT_FILE.XXXXXX" 2>/dev/null)" || return 0
    printf '%s\n' "$1" > "$t" || { rm -f "$t"; return 0; }
    chown "$CLAUDE_UID:$CLAUDE_GID" "$t" 2>/dev/null || true
    chmod 644 "$t" 2>/dev/null || true
    mv -fT "$t" "$ACCT_FILE" || rm -f "$t"
}
refresh_cached_account() {  # the container's .claude.json oauthAccount := the master's
    local cj="$CLAUDE_CONFIG_DIR/.claude.json" acct t
    acct="$(jq -c '.oauthAccount // empty' "$1/.claude.json" 2>/dev/null)" || return 0
    [[ -n "$acct" && -s "$cj" && ! -L "$cj" ]] || return 0
    t="$(mktemp "$cj.acct.XXXXXX" 2>/dev/null)" || return 0
    if jq --argjson a "$acct" '.oauthAccount = $a' "$cj" > "$t" 2>/dev/null && [[ -s "$t" ]]; then
        chown "$CLAUDE_UID:$CLAUDE_GID" "$t" 2>/dev/null || true
        mv -fT "$t" "$cj" || rm -f "$t"
    else
        rm -f "$t"
    fi
    return 0
}
write_switch_file() {  # write_switch_file <epoch> <account>: the request claude-sessions acts on
    local t; t="$(mktemp "$SWITCH_FILE.XXXXXX" 2>/dev/null)" || return 0
    printf '%s %s\n' "$1" "$2" > "$t" || { rm -f "$t"; return 0; }
    chown "$CLAUDE_UID:$CLAUDE_GID" "$t" 2>/dev/null || true
    mv -fT "$t" "$SWITCH_FILE" || rm -f "$t"
}
# A Claude process that started before the switch (so it still runs the previous account).
# Exact, not `ps` elapsed seconds: each process's start comes from /proc (boot time + starttime
# in clock ticks) and is compared in milliseconds. A whole-second comparison misjudged a process
# started in the second before the switch as new, and its old-account refresh was pushed up.
now_ms() { date +%s%3N; }
old_claude_running() {  # old_claude_running <switch time, ms since the epoch>
    local btime hz pid args st
    btime="$(awk '/^btime /{print $2}' /proc/stat 2>/dev/null)"; hz="$(getconf CLK_TCK 2>/dev/null || echo 100)"
    [[ "$btime" =~ ^[0-9]+$ ]] || return 0      # cannot tell: assume old, never push
    while read -r pid args; do
        [[ "${args%% *}" =~ $CLAUDE_BIN_RE ]] || continue
        st="$(sed -E 's/^[0-9]+ \(.*\) //' "/proc/$pid/stat" 2>/dev/null | awk '{print $20}')"
        [[ "$st" =~ ^[0-9]+$ ]] || continue
        (( btime * 1000 + st * 1000 / hz < $1 )) && return 0
    done < <(ps -eo pid=,args= 2>/dev/null)
    return 1
}

reconcile_once() {
    local b="$CLAUDE_CONFIG_DIR/.credentials.json"  # per-container copy (claude:600)
    # Re-derive the master every tick (not just once) so a rotation picked up mid-loop
    # (bin/claude-usage-watchdog updates .active-account via account_switch_listener below)
    # keeps token-refresh write-back flowing to whichever account is now active.
    local md a m l
    md="$(master_dir)"; a="$md/.credentials.json"          # the shared master (root:600)
    m="$(account_of "$md")"; l="$(local_account)"
    # CLAUDE_AUTH_FOLLOW=0: no account logic at all, the pre-existing newest-wins sync.
    [[ "${CLAUDE_AUTH_FOLLOW:-1}" =~ ^(0|false|no|off)$ ]] && m=""
    if [[ -n "$m" && "$m" != "$l" ]] && creds_have_token "$a"; then
        # A different account was logged into the shared volume: follow it.
        publish_creds "$a" "$b" || return 0
        set_local_account "$m"
        refresh_cached_account "$md"
        SWITCH_AT="$(now_ms)"
        write_switch_file "$(( SWITCH_AT / 1000 ))" "$m"
        log "Auth account        : the shared credential is now $(email_of "$md") (${m:0:8}…, was ${l:0:8}…); taken over, and each session restarts onto it at its next idle moment"
        return 0
    fi
    if (( SWITCH_AT > 0 )); then
        if old_claude_running "$SWITCH_AT"; then
            # Sessions still on the old account: the master wins, nothing is ever pushed up.
            creds_have_token "$a" && ! cmp -s "$a" "$b" && publish_creds "$a" "$b"
            return 0
        fi
        SWITCH_AT=0
        refresh_cached_account "$md"
        log "Auth account        : every Claude process now runs on $(email_of "$md")"
    fi
    if creds_have_token "$b" && ! creds_have_token "$a"; then
        # master absent/logged-out, local good -> seed or repair the master, but only with a
        # credential of the master's own account (or when the master names none)
        [[ -z "$m" || "$m" == "$l" ]] && publish_creds "$b" "$a"
    elif creds_have_token "$a" && ! creds_have_token "$b"; then
        # local absent/logged-out, master good -> repair the local copy
        publish_creds "$a" "$b"
    elif creds_have_token "$b" && [[ "$b" -nt "$a" ]] && ! cmp -s "$b" "$a"; then
        # both good, local refreshed more recently -> push the refresh up (same account only)
        [[ -z "$m" || "$m" == "$l" ]] && publish_creds "$b" "$a"
    elif creds_have_token "$a" && [[ "$a" -nt "$b" ]] && ! cmp -s "$a" "$b"; then
        # both good, master refreshed more recently -> pull the refresh down
        publish_creds "$a" "$b"
    fi
    # both tokenless (a real refresh-token expiry): nothing to do, the loop
    # never invents a token; recovery is `make login` on the host.
    return 0
}

# At boot, before any Claude starts: a container whose own credential is another account's
# (a dormant service, or one stopped across an account change) takes the master's now, so no
# session ever starts on, or refreshes, the old account.
_md="$(master_dir)"; _m="$(account_of "$_md")"
if [[ "${CLAUDE_AUTH_FOLLOW:-1}" =~ ^(0|false|no|off)$ ]]; then
    log "Auth account        : account changes are NOT followed (CLAUDE_AUTH_FOLLOW=${CLAUDE_AUTH_FOLLOW}); a new login needs a container restart"
elif [[ -n "$_m" ]] && creds_have_token "$_md/.credentials.json"; then
    _l="$(local_account)"
    if [[ "$_l" != "$_m" ]]; then
        publish_creds "$_md/.credentials.json" "$CLAUDE_CONFIG_DIR/.credentials.json"
        [[ -n "$_l" ]] && log "Auth account        : this container's own credential was another account's (${_l:0:8}…); replaced with the shared one before any session started"
    fi
    set_local_account "$_m"
    log "Auth account        : $(email_of "$_md") (${_m:0:8}…); account changes in the shared credential are followed without a restart"
fi
unset _md _m _l
# <<< credential sync

# `|| true`: errexit is off inside, so one failed pass can never end the loop for good.
reconcile_creds() { while sleep 30; do reconcile_once || true; done; }
reconcile_creds &
# shellcheck disable=SC2034  # stopped by shutdown() (§13)
RECONCILE_PID=$!
