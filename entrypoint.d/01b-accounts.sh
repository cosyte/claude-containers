# shellcheck shell=bash
# --- 1b. Multi-account mode (opt-in) ------------------------------------------
# CLAUDE_ACCOUNTS (comma-separated names) redirects AUTH_DIR from the single
# shared /auth volume to one of several named /auth-accounts/<name> volumes
# mounted by `claude-launch --accounts`: each created by `claude-account-login
# <name>`. Works with any account count >= 1: a single account still benefits
# (bin/claude-usage-watchdog auto-resumes it once its usage window resets), and
# unset (the default) leaves AUTH_DIR="/auth" with every line below unchanged.
# The "active" account persists in a state file so a rotation survives a plain
# `docker start` (which reuses creation-time env/mounts, not a fresh launch).
ACCOUNT_NAMES=()
if [[ -n "${CLAUDE_ACCOUNTS:-}" ]]; then
    IFS=',' read -ra ACCOUNT_NAMES <<< "$CLAUDE_ACCOUNTS"
    (( ${#ACCOUNT_NAMES[@]} > 0 )) || die "CLAUDE_ACCOUNTS is set but empty"
    for n in "${ACCOUNT_NAMES[@]}"; do
        [[ -d "/auth-accounts/$n" ]] || die "account '$n' listed in CLAUDE_ACCOUNTS has no volume mounted at /auth-accounts/$n: check claude-launch --accounts wiring"
    done
    # This runs before §2 hands the config dir over, and the agent writes in it below: its top
    # first. The agent makes it when it is missing (a root mkdir by a name in its home would act
    # on whatever the agent put there).
    # (An operator's CLAUDE_CONFIG_DIR outside the agent's home, where it cannot, root makes.)
    if ! as_agent mkdir -p "$CLAUDE_CONFIG_DIR" 2>/dev/null; then
        [[ "$CLAUDE_CONFIG_DIR/" != "$CLAUDE_HOME/"* ]] && mkdir -p "$CLAUDE_CONFIG_DIR" \
            || die "could not make the config dir $CLAUDE_CONFIG_DIR"
    fi
    own_tree "$CLAUDE_CONFIG_DIR" -maxdepth 0
    ACTIVE_FILE="$CLAUDE_CONFIG_DIR/.active-account"
    # The config dir is the agent's, so the agent reads and writes the file (agent_put, agent_cat,
    # §0a's), never root by name. 644: the usage watchdog reads it.
    _write_active() { printf '%s\n' "$1" | agent_put "$ACTIVE_FILE" 644; }
    [[ -s "$ACTIVE_FILE" && ! -L "$ACTIVE_FILE" ]] || _write_active "${ACCOUNT_NAMES[0]}"
    ACTIVE_ACCOUNT="$(agent_cat "$ACTIVE_FILE")"
    case ",${CLAUDE_ACCOUNTS}," in
        *",${ACTIVE_ACCOUNT},"*) ;;
        *) log "WARNING: previously-active account '$ACTIVE_ACCOUNT' is no longer in CLAUDE_ACCOUNTS: falling back to '${ACCOUNT_NAMES[0]}'"
           ACTIVE_ACCOUNT="${ACCOUNT_NAMES[0]}"
           _write_active "$ACTIVE_ACCOUNT" ;;
    esac
    unset -f _write_active
    # shellcheck disable=SC2034  # read by §2 and §6
    AUTH_DIR="/auth-accounts/$ACTIVE_ACCOUNT"
    log "Multi-account mode  : ${#ACCOUNT_NAMES[@]} account(s) (${CLAUDE_ACCOUNTS}); active=$ACTIVE_ACCOUNT"
fi
