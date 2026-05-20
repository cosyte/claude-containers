#!/usr/bin/env bash
# Claude Code container entrypoint.
# Starts as root: sets up sshd, fixes volume ownership, merges baked-in config,
# prepares the workspace, then drops to the unprivileged `claude` user to run
# Claude Code inside a persistent tmux session.
set -euo pipefail

CLAUDE_USER="${CLAUDE_USER:-claude}"
CLAUDE_HOME="$(getent passwd "$CLAUDE_USER" | cut -d: -f6)"
CLAUDE_UID="$(id -u "$CLAUDE_USER")"
CLAUDE_GID="$(id -g "$CLAUDE_USER")"
export CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$CLAUDE_HOME/.claude}"

AUTH_DIR="/auth"                              # shared credentials volume
HOSTKEY_DIR="/etc/ssh/host-keys"              # shared host-key volume
BAKE_DIR="/opt/claude-config"                 # image-baked config source
AUTHKEYS_SRC="/etc/claude/authorized_keys"    # host-mounted, read-only
GITKEY_SRC="/etc/claude/git-key"              # host-mounted, read-only
WORKSPACE="/workspace"

log()  { echo "[entrypoint] $*"; }
die()  { echo "[entrypoint] ERROR: $*" >&2; exit 1; }
asclaude() { gosu "$CLAUDE_USER" env CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" HOME="$CLAUDE_HOME" "$@"; }

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
    exec gosu "$CLAUDE_USER" env CLAUDE_CONFIG_DIR="$AUTH_DIR" HOME="$CLAUDE_HOME" \
        claude auth login --claudeai
fi

# --- 2. Fix ownership of mounted volumes -------------------------------------
mkdir -p "$CLAUDE_CONFIG_DIR" "$AUTH_DIR" "$HOSTKEY_DIR" "$CLAUDE_HOME/.ssh" "$WORKSPACE"
chown -R "$CLAUDE_UID:$CLAUDE_GID" "$CLAUDE_CONFIG_DIR" "$CLAUDE_HOME/.ssh"
chown "$CLAUDE_UID:$CLAUDE_GID" "$WORKSPACE" 2>/dev/null || true
chmod 700 "$CLAUDE_HOME/.ssh"

# --- 3. SSH host keys (persistent) -------------------------------------------
if [[ ! -f "$HOSTKEY_DIR/ssh_host_ed25519_key" ]]; then
    log "Generating persistent SSH host keys"
    ssh-keygen -q -t ed25519 -f "$HOSTKEY_DIR/ssh_host_ed25519_key" -N ''
    ssh-keygen -q -t rsa -b 4096 -f "$HOSTKEY_DIR/ssh_host_rsa_key" -N ''
fi
chmod 600 "$HOSTKEY_DIR"/ssh_host_*_key
chmod 644 "$HOSTKEY_DIR"/ssh_host_*_key.pub

# --- 4. Authorized keys (SSH access) -----------------------------------------
if [[ -s "$AUTHKEYS_SRC" ]]; then
    install -o "$CLAUDE_UID" -g "$CLAUDE_GID" -m 600 \
        "$AUTHKEYS_SRC" "$CLAUDE_HOME/.ssh/authorized_keys"
    log "Installed authorized_keys for SSH"
else
    log "WARNING: no authorized_keys mounted at $AUTHKEYS_SRC"
    log "         SSH will be unusable; Remote Control still works."
fi

# --- 5. Git SSH key + identity -----------------------------------------------
if [[ -s "$GITKEY_SRC" ]]; then
    install -o "$CLAUDE_UID" -g "$CLAUDE_GID" -m 600 \
        "$GITKEY_SRC" "$CLAUDE_HOME/.ssh/id_ed25519"
    cat > "$CLAUDE_HOME/.ssh/config" <<EOF
Host *
    IdentityFile ~/.ssh/id_ed25519
    StrictHostKeyChecking accept-new
    UserKnownHostsFile ~/.ssh/known_hosts
EOF
    chown "$CLAUDE_UID:$CLAUDE_GID" "$CLAUDE_HOME/.ssh/config"
    chmod 600 "$CLAUDE_HOME/.ssh/config"
    log "Installed git SSH key"
else
    log "No git SSH key mounted at $GITKEY_SRC (https/public repos still work)"
fi

# Git identity: env vars win; otherwise inherit whatever the launcher passed
# from the host's git config. Applied to the claude user's global config.
git_id() {
    local k="$1" v="$2"
    [[ -n "$v" ]] && asclaude git config --global "$k" "$v" || true
}
git_id user.name  "${GIT_AUTHOR_NAME:-}"
git_id user.email "${GIT_AUTHOR_EMAIL:-}"
# safe.directory is multi-valued: `--add` every boot would append a duplicate
# line per restart. Add it only if it isn't already present.
asclaude git config --global --get-all safe.directory 2>/dev/null \
    | grep -qxF "$WORKSPACE" \
    || asclaude git config --global --add safe.directory "$WORKSPACE" || true
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

# --- 6. Credentials reconcile (shared auth volume) ---------------------------
# Credentials are shared across all containers via the claude-auth volume; the
# rest of the config dir is per-container so sessions never collide. Claude
# rewrites .credentials.json on token refresh, so a small loop keeps the
# per-container file and the shared volume converged (newest wins).
if [[ ! -s "$AUTH_DIR/.credentials.json" ]]; then
    if [[ "${CLAUDE_SKIP_AUTH_CHECK:-0}" == "1" ]]; then
        log "WARNING: no credentials in claude-auth volume (auth check skipped)"
    else
        die "No credentials in the claude-auth volume. Run 'make login' once
       before launching containers (see README Quick start)."
    fi
fi
if [[ -s "$AUTH_DIR/.credentials.json" && ! -s "$CLAUDE_CONFIG_DIR/.credentials.json" ]]; then
    install -o "$CLAUDE_UID" -g "$CLAUDE_GID" -m 600 \
        "$AUTH_DIR/.credentials.json" "$CLAUDE_CONFIG_DIR/.credentials.json"
fi

reconcile_creds() {
    local a="$AUTH_DIR/.credentials.json"
    local b="$CLAUDE_CONFIG_DIR/.credentials.json"
    local t
    while sleep 30; do
        [[ -s "$a" || -s "$b" ]] || continue
        # Stage into a unique tmp file in the *target* dir, then atomic-rename.
        # /auth is shared by every container, so a fixed tmp name would let one
        # container's mv pick up another container's half-written file and
        # publish a partial/corrupt .credentials.json fleet-wide.
        if [[ -s "$b" && ( ! -s "$a" || "$b" -nt "$a" ) ]] && ! cmp -s "$b" "$a"; then
            t="$(mktemp "$a.XXXXXX")" || continue
            { install -m 600 "$b" "$t" && mv -f "$t" "$a"; } || rm -f "$t"
        elif [[ -s "$a" && "$a" -nt "$b" ]] && ! cmp -s "$a" "$b"; then
            t="$(mktemp "$b.XXXXXX")" || continue
            { install -o "$CLAUDE_UID" -g "$CLAUDE_GID" -m 600 "$a" "$t" \
                && mv -f "$t" "$b"; } || rm -f "$t"
        fi
    done
}
reconcile_creds &
RECONCILE_PID=$!

# --- 7. Seed .claude.json (onboarding + workspace trust) ---------------------
# With CLAUDE_CONFIG_DIR set, Claude stores .claude.json *inside* it. Pre-accept
# the workspace trust dialog and onboarding non-interactively, and lift the
# oauthAccount written by `make login` so the account shows correctly. Only
# fills missing keys — never clobbers existing per-container state.
CJSON="$CLAUDE_CONFIG_DIR/.claude.json"
[[ -s "$CJSON" ]] || echo '{}' > "$CJSON"
OAUTH_ACCOUNT='{}'
[[ -s "$AUTH_DIR/.claude.json" ]] && \
    OAUTH_ACCOUNT="$(jq -c '.oauthAccount // {}' "$AUTH_DIR/.claude.json" 2>/dev/null || echo '{}')"
jq --argjson oauth "$OAUTH_ACCOUNT" '
    .hasCompletedOnboarding = (.hasCompletedOnboarding // true)
  | .oauthAccount = (.oauthAccount // (if ($oauth|length>0) then $oauth else null end))
  | .projects = (.projects // {})
  | .projects["'"$WORKSPACE"'"] = ((.projects["'"$WORKSPACE"'"] // {}) + {
        hasTrustDialogAccepted: true,
        hasCompletedProjectOnboarding: true,
        hasClaudeMdExternalIncludesApproved: true,
        hasClaudeMdExternalIncludesWarningShown: true
    })
' "$CJSON" > "$CJSON.tmp" && mv -f "$CJSON.tmp" "$CJSON"
chown "$CLAUDE_UID:$CLAUDE_GID" "$CJSON"

# --- 8. Merge baked-in config ------------------------------------------------
# Everything baked into the image is overridable at runtime by mounting onto
# the target path (we only fill what's absent).

# 8a. Global CLAUDE.md
if [[ -f "$BAKE_DIR/CLAUDE.md" && ! -e "$CLAUDE_CONFIG_DIR/CLAUDE.md" ]]; then
    install -o "$CLAUDE_UID" -g "$CLAUDE_GID" -m 644 \
        "$BAKE_DIR/CLAUDE.md" "$CLAUDE_CONFIG_DIR/CLAUDE.md"
    log "Installed global CLAUDE.md"
fi

# 8b. settings.json — baked file is the base, existing user settings win on
#     conflict (recursive merge). Also injects unattended-operation defaults.
#     NOTE: env intentionally does NOT include DISABLE_TELEMETRY/DO_NOT_TRACK.
#     Those (and CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC) make Claude Code skip
#     the GrowthBook fetch, so the `tengu_ccr_bridge` gate defaults false and
#     Remote Control reports "not yet enabled for your account". RC is the point
#     of this image, so they must never be set. See docs/troubleshooting.md.
PERM_MODE="${CLAUDE_PERMISSION_MODE:-bypassPermissions}"
BASE_SETTINGS="$(jq -n --arg pm "$PERM_MODE" '{
    permissions: { defaultMode: $pm },
    skipDangerousModePermissionPrompt: true,
    includeCoAuthoredBy: true,
    env: { DISABLE_AUTOUPDATER: "1" }
}')"
[[ -f "$BAKE_DIR/settings.json" ]] && \
    BASE_SETTINGS="$(jq -s '.[0] * .[1]' <(echo "$BASE_SETTINGS") "$BAKE_DIR/settings.json")"
EXISTING_SETTINGS='{}'
[[ -s "$CLAUDE_CONFIG_DIR/settings.json" ]] && \
    EXISTING_SETTINGS="$(cat "$CLAUDE_CONFIG_DIR/settings.json")"
# Self-heal: strip the Remote-Control-breaking telemetry kills from the final
# settings (covers per-container volumes created by an older image). If any
# were present, drop the cached GrowthBook flags + statsig cache so the next
# Claude run re-fetches them and RC eligibility resolves correctly.
jq -s '.[0] * .[1]' <(echo "$BASE_SETTINGS") <(echo "$EXISTING_SETTINGS") \
    | jq 'if .env then .env |= (del(.DISABLE_TELEMETRY,.DO_NOT_TRACK,.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC)) else . end' \
    > "$CLAUDE_CONFIG_DIR/settings.json"
chown "$CLAUDE_UID:$CLAUDE_GID" "$CLAUDE_CONFIG_DIR/settings.json"
if echo "$EXISTING_SETTINGS" | jq -e '.env // {} | (.DISABLE_TELEMETRY // .DO_NOT_TRACK // .CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC) != null' >/dev/null 2>&1; then
    log "Migrated settings.json: removed telemetry kills that block Remote Control; clearing stale feature-flag cache"
    [[ -s "$CJSON" ]] && jq 'del(.cachedGrowthBookFeatures,.cachedExperimentFeatures)' "$CJSON" > "$CJSON.tmp" \
        && mv -f "$CJSON.tmp" "$CJSON" && chown "$CLAUDE_UID:$CLAUDE_GID" "$CJSON"
    rm -rf "$CLAUDE_CONFIG_DIR/statsig" 2>/dev/null || true
fi

# 8c. Plugins — declarative. Claude Code installs/syncs the marketplaces and
#     enabled plugins from settings.json on startup (idempotent). We union the
#     two plugin keys into existing settings; existing entries win on conflict.
if [[ -f "$BAKE_DIR/plugins/plugins.json" ]]; then
    jq -s '
        .[0] as $cur | .[1] as $plug |
        $cur
        | .extraKnownMarketplaces = (($plug.extraKnownMarketplaces // {}) + ($cur.extraKnownMarketplaces // {}))
        | .enabledPlugins         = (($plug.enabledPlugins // {})         + ($cur.enabledPlugins // {}))
    ' "$CLAUDE_CONFIG_DIR/settings.json" "$BAKE_DIR/plugins/plugins.json" \
        > "$CLAUDE_CONFIG_DIR/settings.json.tmp" \
        && mv -f "$CLAUDE_CONFIG_DIR/settings.json.tmp" "$CLAUDE_CONFIG_DIR/settings.json"
    chown "$CLAUDE_UID:$CLAUDE_GID" "$CLAUDE_CONFIG_DIR/settings.json"
    log "Merged baked-in plugin marketplaces/plugins into settings.json"
fi

# 8d. Custom slash commands
if compgen -G "$BAKE_DIR/commands/*.md" > /dev/null; then
    install -d -o "$CLAUDE_UID" -g "$CLAUDE_GID" "$CLAUDE_CONFIG_DIR/commands"
    for f in "$BAKE_DIR"/commands/*.md; do
        t="$CLAUDE_CONFIG_DIR/commands/$(basename "$f")"
        [[ -e "$t" ]] || install -o "$CLAUDE_UID" -g "$CLAUDE_GID" -m 644 "$f" "$t"
    done
    log "Installed baked-in slash commands"
fi

# 8e. Skills (one directory per skill, must contain SKILL.md)
if [[ -d "$BAKE_DIR/skills" ]]; then
    install -d -o "$CLAUDE_UID" -g "$CLAUDE_GID" "$CLAUDE_CONFIG_DIR/skills"
    for d in "$BAKE_DIR"/skills/*/; do
        [[ -f "$d/SKILL.md" ]] || continue
        name="$(basename "$d")"
        if [[ ! -d "$CLAUDE_CONFIG_DIR/skills/$name" ]]; then
            cp -a "$d" "$CLAUDE_CONFIG_DIR/skills/$name"
            chown -R "$CLAUDE_UID:$CLAUDE_GID" "$CLAUDE_CONFIG_DIR/skills/$name"
        fi
    done
    log "Installed baked-in skills"
fi

# --- 9. Workspace ------------------------------------------------------------
# A bind mount or pre-populated volume wins; otherwise clone GIT_REPO_URL.
shopt -s nullglob dotglob
ws_entries=("$WORKSPACE"/*)
shopt -u nullglob dotglob
ws_populated=0
if (( ${#ws_entries[@]} )); then
    for e in "${ws_entries[@]}"; do
        [[ "$(basename "$e")" == "lost+found" ]] && continue
        ws_populated=1; break
    done
fi

if [[ "$ws_populated" == "1" ]]; then
    log "Using existing workspace contents at $WORKSPACE"
elif [[ -n "${GIT_REPO_URL:-}" ]]; then
    log "Cloning $GIT_REPO_URL into $WORKSPACE"
    clone_args=()
    [[ -n "${GIT_REPO_BRANCH:-}" ]] && clone_args+=(--branch "$GIT_REPO_BRANCH")
    [[ -n "${GIT_REPO_DEPTH:-}"  ]] && clone_args+=(--depth "$GIT_REPO_DEPTH")
    asclaude git clone "${clone_args[@]}" "$GIT_REPO_URL" "$WORKSPACE" \
        || die "git clone failed (check GIT_REPO_URL / git SSH key / branch)"
else
    die "Empty workspace and no GIT_REPO_URL. Set GIT_REPO_URL or bind-mount a
       checkout onto $WORKSPACE (use 'claude-launch --repo' or --workspace)."
fi
chown -R "$CLAUDE_UID:$CLAUDE_GID" "$WORKSPACE" 2>/dev/null || true

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

# --- 11. Start sshd ----------------------------------------------------------
/usr/sbin/sshd -e
log "sshd listening on container port 22"

# --- 12. Launch Claude Code in a persistent tmux session --------------------
CLAUDE_PROJECT_NAME="${CLAUDE_PROJECT_NAME:-claude}"
export CLAUDE_PROJECT_NAME CLAUDE_EXTRA_ARGS="${CLAUDE_EXTRA_ARGS:-}" \
       CLAUDE_DEV_CMD="${CLAUDE_DEV_CMD:-}"

# tmux server runs as the claude user; claude-session is the pane command and
# falls back to an interactive shell if Claude exits, so SSH stays usable.
asclaude tmux new-session -d -s claude -x 220 -y 50 /usr/local/bin/claude-session
log "Claude Code session 'claude' started in tmux"

# Optional dev server: runs $CLAUDE_DEV_CMD in its own 'dev' tmux window so it
# auto-starts on boot, is observable (tmux select-window -t claude:dev), and
# survives independently of the Claude pane.
if [[ -n "${CLAUDE_DEV_CMD:-}" ]]; then
    asclaude tmux new-window -t claude -n dev /usr/local/bin/claude-dev
    log "Dev server started in tmux window 'dev': $CLAUDE_DEV_CMD"
fi

echo
log "Remote Control name : $CLAUDE_PROJECT_NAME  (look for it in the Claude app Code tab)"
log "SSH                 : connect, you'll attach to the live tmux session"
[[ -n "${CLAUDE_DEV_CMD:-}" ]] && \
    log "Dev window          : tmux select-window -t claude:dev  (after SSH attach)"
echo

# --- 13. Stay alive + graceful shutdown --------------------------------------
shutdown() {
    log "Shutting down"
    asclaude tmux kill-server >/dev/null 2>&1 || true
    pkill -x sshd >/dev/null 2>&1 || true
    kill "$RECONCILE_PID" >/dev/null 2>&1 || true
    exit 0
}
trap shutdown TERM INT

# Keep PID 1 alive while the container should run. If the tmux server dies
# entirely (rare), exit so Docker's restart policy can recover it.
while asclaude tmux has-session -t claude >/dev/null 2>&1; do
    sleep 5 & wait $!
done
log "tmux session ended"
shutdown
