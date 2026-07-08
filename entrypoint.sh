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
# CLAUDE_BROKER_GIT_KEY=1 loads the deploy key into a ROOT-owned ssh-agent and
# exposes only the agent socket to the claude user: git can sign/push with the
# key, but the unprivileged (prompt-injectable) agent can never read the private
# key bytes, so it can't be exfiltrated. Default off keeps the historical
# readable key file. Either way the key is never baked into the image.
git_brokered=0
if [[ -s "$GITKEY_SRC" ]]; then
    cat > "$CLAUDE_HOME/.ssh/config" <<EOF
Host *
    StrictHostKeyChecking accept-new
    UserKnownHostsFile ~/.ssh/known_hosts
EOF
    if [[ "${CLAUDE_BROKER_GIT_KEY:-0}" =~ ^(1|true|yes|on)$ ]]; then
        # Key lives only in a ROOT ssh-agent's memory (+ the root-only mounted
        # key file). ssh-agent rejects cross-uid peers, so a root socat relay
        # exposes a claude-usable socket and forwards to the root agent: claude
        # signs through it (git push works) but can neither extract the key
        # (agent protocol never returns private keys) nor read root's memory.
        mkdir -p /run/claude && chmod 711 /run/claude
        AGENT_SOCK="/run/claude/agent-root.sock"     # root-only
        CLAUDE_SOCK="/run/claude/agent.sock"         # claude-usable, via relay
        rm -f "$AGENT_SOCK" "$CLAUDE_SOCK"
        if ssh-agent -a "$AGENT_SOCK" >/dev/null 2>&1; then
            for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -S "$AGENT_SOCK" ]] && break; sleep 0.2; done
        fi
        if [[ -S "$AGENT_SOCK" ]] && SSH_AUTH_SOCK="$AGENT_SOCK" ssh-add "$GITKEY_SRC" >/dev/null 2>&1; then
            socat "UNIX-LISTEN:$CLAUDE_SOCK,fork,mode=0600,user=$CLAUDE_USER" \
                  "UNIX-CONNECT:$AGENT_SOCK" >/dev/null 2>&1 &
            for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -S "$CLAUDE_SOCK" ]] && break; sleep 0.2; done
        fi
        if [[ -S "$CLAUDE_SOCK" ]]; then
            chmod 600 "$AGENT_SOCK" 2>/dev/null || true     # keep the real agent root-only
            export SSH_AUTH_SOCK="$CLAUDE_SOCK"
            printf 'export SSH_AUTH_SOCK=%s\n' "$CLAUDE_SOCK" > /etc/profile.d/claude-ssh-agent.sh
            git_brokered=1
            log "Git SSH key broker  : key held in a root ssh-agent (claude signs via relay, cannot read it)"
        else
            log "Git SSH key broker  : WARNING — ssh-agent/relay setup failed; falling back to a readable key file"
        fi
    fi
    if [[ "$git_brokered" == 0 ]]; then
        install -o "$CLAUDE_UID" -g "$CLAUDE_GID" -m 600 \
            "$GITKEY_SRC" "$CLAUDE_HOME/.ssh/id_ed25519"
        printf 'Host *\n    IdentityFile ~/.ssh/id_ed25519\n' >> "$CLAUDE_HOME/.ssh/config"
        log "Installed git SSH key"
    fi
    chown "$CLAUDE_UID:$CLAUDE_GID" "$CLAUDE_HOME/.ssh/config"
    chmod 600 "$CLAUDE_HOME/.ssh/config"
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

# Secret guard: a fleet-wide pre-commit hook (global core.hooksPath) that blocks
# committing obvious secrets/credentials — important because the agent commits
# and pushes autonomously with a mounted key and one shared credential volume.
# Disable with CLAUDE_SECRET_GUARD=0. The hook chains to a repo's own pre-commit.
HOOKS_DIR="$CLAUDE_HOME/.claude-hooks"
case "${CLAUDE_SECRET_GUARD:-1}" in
    0|false|no|off)
        asclaude git config --global --unset core.hooksPath 2>/dev/null || true
        log "Secret guard         : disabled (CLAUDE_SECRET_GUARD=0)" ;;
    *)
        asclaude mkdir -p "$HOOKS_DIR"
        ln -sf /usr/local/bin/claude-secret-guard "$HOOKS_DIR/pre-commit"
        chown -h "$CLAUDE_UID:$CLAUDE_GID" "$HOOKS_DIR/pre-commit" 2>/dev/null || true
        asclaude git config --global core.hooksPath "$HOOKS_DIR"
        log "Secret guard         : on (blocks committing secrets; bypass with git commit --no-verify)" ;;
esac

# GitHub HTTPS auth (dynamic, additive): when GH_TOKEN is supplied, wire the
# `gh` CLI in as git's credential helper for github.com so HTTPS clone/push
# also work with the token. SSH remotes keep using the mounted deploy key, so
# a session can use either transport. `gh auth setup-git` resets the helper
# before re-adding its own, so running it on every boot stays idempotent.
if [[ -n "${GH_TOKEN:-}" ]]; then
    if asclaude gh auth setup-git --hostname github.com >/dev/null 2>&1; then
        log "GH_TOKEN set: gh wired in as git credential helper (HTTPS + SSH both usable)"
    else
        log "WARNING: 'gh auth setup-git' failed; HTTPS git auth via GH_TOKEN unavailable"
    fi
else
    log "No GH_TOKEN: git uses the SSH deploy key only; gh CLI is unauthenticated"
fi

# --- 5b. Worker broker (controller mode, CC-2) --------------------------------
# CLAUDE_WORKER_BROKER=1 starts the ROOT-owned worker broker: on a controller
# (a Sysbox container running an inner dockerd) it is the ONLY principal that
# may launch nested workers. Mirrors the git-key broker above — root owns the
# capability, the unprivileged agent gets a narrow request channel
# (claude-worker-request → spool dir), never the inner Docker socket. The broker
# FAILS CLOSED unless the substrate holds: userns containment readable from
# /proc/self/uid_map AND a host-attested, CVE-patched Sysbox version in
# CLAUDE_SYSBOX_ATTESTED_VERSION (the host launch path runs preflight_sysbox and
# passes SYSBOX_VERSION in). See bin/claude-worker-broker for the template.
if [[ "${CLAUDE_WORKER_BROKER:-0}" =~ ^(1|true|yes|on)$ ]]; then
    # Best-effort early lock: keep the agent off an already-present inner socket
    # even before the broker's own lockdown (the broker re-asserts at startup).
    if [[ -S /var/run/docker.sock ]]; then
        chown root:root /var/run/docker.sock 2>/dev/null || true
        chmod 600 /var/run/docker.sock 2>/dev/null || true
    fi
    CLAUDE_BROKER_CLIENT_USER="${CLAUDE_BROKER_CLIENT_USER:-$CLAUDE_USER}" \
        /usr/local/bin/claude-worker-broker >> /var/log/claude-worker-broker.log 2>&1 &
    log "Worker broker       : starting as root (agent requests via claude-worker-request; refuses if the substrate checks fail — see /var/log/claude-worker-broker.log)"
fi

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
# Defense-in-depth: lock the SHARED fleet-wide credential master to root-only so
# a prompt-injected agent can't read or even list it. The agent keeps its OWN
# per-container session token ($CLAUDE_CONFIG_DIR/.credentials.json, claude:600,
# unavoidable — Claude Code authenticates with it), but cannot reach the master
# that backs every other container. `make login` (root-chowns /auth) is separate.
chown root:root "$AUTH_DIR" 2>/dev/null || true
chmod 700 "$AUTH_DIR" 2>/dev/null || true
[[ -e "$AUTH_DIR/.credentials.json" ]] && { chown root:root "$AUTH_DIR/.credentials.json" 2>/dev/null || true; chmod 600 "$AUTH_DIR/.credentials.json" 2>/dev/null || true; }

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

# 8c-bis. Runtime plugin injection — no rebuild required.
# CLAUDE_EXTRA_MARKETPLACES: "name=url[,name=url,...]"  (git source, autoUpdate=true)
# CLAUDE_EXTRA_PLUGINS:      "plugin@marketplace[,...]"
# Existing settings.json entries always win (same semantics as the baked merge above).
if [[ -n "${CLAUDE_EXTRA_MARKETPLACES:-}" ]] || [[ -n "${CLAUDE_EXTRA_PLUGINS:-}" ]]; then
    MKT_JSON="{}"
    if [[ -n "${CLAUDE_EXTRA_MARKETPLACES:-}" ]]; then
        IFS=',' read -ra _MKT_ENTRIES <<< "$CLAUDE_EXTRA_MARKETPLACES"
        for _entry in "${_MKT_ENTRIES[@]}"; do
            _name="${_entry%%=*}"; _url="${_entry#*=}"
            [[ -n "$_name" && -n "$_url" && "$_name" != "$_url" ]] || continue
            MKT_JSON="$(jq --arg n "$_name" --arg u "$_url" \
                '. + {($n): {"source": {"source": "git", "url": $u}, "autoUpdate": true}}' \
                <<< "$MKT_JSON")"
        done
    fi
    PLG_JSON="{}"
    if [[ -n "${CLAUDE_EXTRA_PLUGINS:-}" ]]; then
        IFS=',' read -ra _PLG_ENTRIES <<< "$CLAUDE_EXTRA_PLUGINS"
        for _entry in "${_PLG_ENTRIES[@]}"; do
            [[ -n "$_entry" ]] || continue
            PLG_JSON="$(jq --arg p "$_entry" '. + {($p): true}' <<< "$PLG_JSON")"
        done
    fi
    jq --argjson mkt "$MKT_JSON" --argjson plg "$PLG_JSON" '
        .extraKnownMarketplaces = ($mkt + (.extraKnownMarketplaces // {}))
        | .enabledPlugins       = ($plg + (.enabledPlugins // {}))
    ' "$CLAUDE_CONFIG_DIR/settings.json" \
        > "$CLAUDE_CONFIG_DIR/settings.json.tmp" \
        && mv -f "$CLAUDE_CONFIG_DIR/settings.json.tmp" "$CLAUDE_CONFIG_DIR/settings.json"
    chown "$CLAUDE_UID:$CLAUDE_GID" "$CLAUDE_CONFIG_DIR/settings.json"
    log "Merged runtime plugin marketplaces/plugins into settings.json"
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

# --- 10b. Optional: register chrome-devtools-mcp (frontend debugging) --------
# When CLAUDE_BROWSER=1 (set by `claude-launch --browser` or the env), register
# the Chrome DevTools MCP server so Claude can navigate, evaluate, inspect
# console/network, take screenshots, run Lighthouse, etc. against any frontend
# the agent spins up in /workspace. The image must be built with
# WITH_BROWSER=1 — we check by probing the baked binaries and warn-skip if
# absent (rather than silently failing inside Claude). Headless, isolated
# profile (clean per session), --no-sandbox is required in unprivileged Docker.
case "${CLAUDE_BROWSER:-0}" in
    1|true|yes|on)
        if command -v chrome-devtools-mcp >/dev/null 2>&1 \
           && command -v chromium >/dev/null 2>&1; then
            if asclaude claude mcp get chrome-devtools >/dev/null 2>&1; then
                log "MCP 'chrome-devtools' already configured, skipping"
            else
                cdt_json="$(jq -n '{
                    type: "stdio",
                    command: "chrome-devtools-mcp",
                    args: [
                        "--executablePath", "/usr/bin/chromium",
                        "--headless",
                        "--isolated",
                        "--chromeArg=--no-sandbox",
                        "--chromeArg=--disable-dev-shm-usage",
                        "--chromeArg=--disable-gpu"
                    ],
                    env: { CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS: "1" }
                }')"
                if asclaude claude mcp add-json --scope user chrome-devtools "$cdt_json" >/dev/null 2>&1; then
                    log "Registered MCP server 'chrome-devtools' (headless Chromium)"
                else
                    log "WARNING: failed to register chrome-devtools MCP"
                fi
            fi
        else
            log "WARNING: CLAUDE_BROWSER=1 but chrome-devtools-mcp / chromium not in image."
            log "         Rebuild with: make build-browser   (or --build-arg WITH_BROWSER=1)"
        fi
        ;;
esac

# --- 11. Start sshd ----------------------------------------------------------
/usr/sbin/sshd -e
log "sshd listening on container port 22"

# --- 12. Launch Claude Code in a persistent tmux session --------------------
CLAUDE_PROJECT_NAME="${CLAUDE_PROJECT_NAME:-claude}"
# RC debug log path: claude-session writes Remote Control events here; the
# watchdog and the Docker healthcheck read it. Exported so the tmux server (and
# anything respawned in it) inherits it; CLAUDE_RC_DEBUG_LOG is also a baked ENV
# so the healthcheck — a separate process spawned by dockerd — sees it too.
export CLAUDE_RC_DEBUG_LOG="${CLAUDE_RC_DEBUG_LOG-/tmp/claude-rc-debug.log}"
export CLAUDE_PROJECT_NAME CLAUDE_EXTRA_ARGS="${CLAUDE_EXTRA_ARGS:-}" \
       CLAUDE_DEV_CMD="${CLAUDE_DEV_CMD:-}"

# Model selection: default to the best available model. The `opus` alias always
# resolves to the latest Opus, so the fleet tracks the strongest model without a
# code change when a newer one ships. Override per-container with CLAUDE_MODEL —
# any Claude Code alias (opus, sonnet, haiku, opusplan, default) or a full model
# id (e.g. claude-opus-4-8). Both the interactive session and the autopilot loop
# read it and pass `--model`. To defer to Claude Code's own default, set
# CLAUDE_MODEL=default (empty/unset falls back to opus, the best available).
export CLAUDE_MODEL="${CLAUDE_MODEL:-opus}"
log "Model               : $CLAUDE_MODEL (override with CLAUDE_MODEL; 'default' = Claude Code's pick)"

# Two modes, selected by CLAUDE_AUTOPILOT:
#   interactive (default) — main pane is claude-session (Remote Control + SSH).
#   autopilot             — main pane is claude-autopilot, a headless Claude loop
#                           (default `/next`) for unattended continuous build-out;
#                           there is no Remote Control link, so the RC watchdog is
#                           skipped. Either way SSH attaches to the live tmux pane.
case "${CLAUDE_AUTOPILOT:-0}" in
    1|true|yes|on) CLAUDE_MODE=autopilot;   MAIN_PANE_CMD=/usr/local/bin/claude-autopilot ;;
    *)             CLAUDE_MODE=interactive; MAIN_PANE_CMD=/usr/local/bin/claude-session ;;
esac
export CLAUDE_MODE \
       CLAUDE_AUTOPILOT_CMD="${CLAUDE_AUTOPILOT_CMD:-}" \
       CLAUDE_AUTOPILOT_INTERVAL="${CLAUDE_AUTOPILOT_INTERVAL:-}" \
       CLAUDE_AUTOPILOT_MAX_RUNS="${CLAUDE_AUTOPILOT_MAX_RUNS:-}" \
       CLAUDE_AUTOPILOT_BACKOFF_MAX="${CLAUDE_AUTOPILOT_BACKOFF_MAX:-}" \
       CLAUDE_AUTOPILOT_LOG_DIR="${CLAUDE_AUTOPILOT_LOG_DIR:-}" \
       CLAUDE_AUTOPILOT_RESUME="${CLAUDE_AUTOPILOT_RESUME:-}" \
       CLAUDE_AUTOPILOT_QUEUE="${CLAUDE_AUTOPILOT_QUEUE:-}" \
       CLAUDE_AUTOPILOT_QUEUE_DIR="${CLAUDE_AUTOPILOT_QUEUE_DIR:-}" \
       CLAUDE_AUTOPILOT_QUEUE_DELAY="${CLAUDE_AUTOPILOT_QUEUE_DELAY:-}" \
       CLAUDE_SCM_OBSERVER="${CLAUDE_SCM_OBSERVER:-}" \
       CLAUDE_SCM_INTERVAL="${CLAUDE_SCM_INTERVAL:-}" \
       CLAUDE_SCM_EVENTS="${CLAUDE_SCM_EVENTS:-}" \
       CLAUDE_SCM_PR_FILTER="${CLAUDE_SCM_PR_FILTER:-}" \
       CLAUDE_SCM_PR_LIMIT="${CLAUDE_SCM_PR_LIMIT:-}" \
       CLAUDE_SCM_PRIORITY="${CLAUDE_SCM_PRIORITY:-}" \
       CLAUDE_PERMISSION_MODE="${CLAUDE_PERMISSION_MODE:-bypassPermissions}"

# OpenTelemetry: opt-in fleet observability. Claude Code reads OTEL_* + the
# enable flag straight from the process environment (env > settings.json), and
# the tmux panes inherit this exported env, so we just compose sane defaults and
# a per-container resource tag — no settings.json surgery, and the auth header (a
# secret) stays in process env, never persisted to the config volume. Enabled by
# CLAUDE_OTEL_ENABLED=1 or simply by supplying an OTLP endpoint. Orthogonal to
# the Remote-Control telemetry concern above (that's nonessential-traffic, not
# this). Ref: code.claude.com/docs/en/monitoring-usage
if [[ "${CLAUDE_OTEL_ENABLED:-0}" =~ ^(1|true|yes|on)$ || -n "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" ]]; then
    export CLAUDE_CODE_ENABLE_TELEMETRY=1
    export OTEL_METRICS_EXPORTER="${OTEL_METRICS_EXPORTER:-otlp}"
    export OTEL_LOGS_EXPORTER="${OTEL_LOGS_EXPORTER:-otlp}"
    export OTEL_EXPORTER_OTLP_PROTOCOL="${OTEL_EXPORTER_OTLP_PROTOCOL:-http/protobuf}"
    # Traces are a Claude Code beta (needed for trace backends like Langfuse).
    if [[ "${CLAUDE_OTEL_TRACES:-0}" =~ ^(1|true|yes|on)$ ]]; then
        export CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1
        export OTEL_TRACES_EXPORTER="${OTEL_TRACES_EXPORTER:-otlp}"
    fi
    # service.name is fixed to "claude-code" upstream, so distinguish containers
    # with a custom tag (+ any operator-supplied attributes).
    _ra="service.instance.id=${CLAUDE_PROJECT_NAME},claude.project=${CLAUDE_PROJECT_NAME}"
    [[ -n "${OTEL_RESOURCE_ATTRIBUTES:-}" ]] && _ra="${_ra},${OTEL_RESOURCE_ATTRIBUTES}"
    export OTEL_RESOURCE_ATTRIBUTES="$_ra"
    # OTEL_EXPORTER_OTLP_ENDPOINT / _HEADERS arrive via env (-e/.env) and are
    # already exported into this environment, so the panes inherit them as-is.
    log "OpenTelemetry        : on → ${OTEL_EXPORTER_OTLP_ENDPOINT:-<no endpoint set!>} (${OTEL_EXPORTER_OTLP_PROTOCOL})$([[ -n "${OTEL_EXPORTER_OTLP_HEADERS:-}" ]] && echo ' +auth')"
    [[ -z "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" ]] && \
        log "OpenTelemetry        : WARNING — enabled but OTEL_EXPORTER_OTLP_ENDPOINT is empty; nothing will be exported"
fi

# Egress lockdown (opt-in): apply a default-deny firewall NOW — after the
# entrypoint's own setup (clone, plugin install) has finished with open egress,
# and as root (we still hold NET_ADMIN) before the unprivileged agent starts, so
# the agent runs sealed and cannot alter its own rules. Fail-open by design.
if [[ "${CLAUDE_EGRESS_LOCKDOWN:-0}" =~ ^(1|true|yes|on)$ ]]; then
    if /usr/local/bin/claude-egress-firewall; then
        log "Egress lockdown      : default-deny active (allowlist + CLAUDE_EGRESS_EXTRA_HOSTS)"
    else
        log "Egress lockdown      : FAILED to apply — egress left OPEN (see [egress] lines above)"
    fi
fi

# tmux server runs as the claude user; the main pane command falls back to an
# interactive shell if it exits, so SSH stays usable. The pane lives in window
# 'main' (the RC watchdog respawns it by name in interactive mode).
asclaude tmux new-session -d -s claude -n main -x 220 -y 50 "$MAIN_PANE_CMD"
log "Claude Code session 'claude' started in tmux (mode: $CLAUDE_MODE)"

# Optional dev server: runs $CLAUDE_DEV_CMD in its own 'dev' tmux window so it
# auto-starts on boot, is observable (tmux select-window -t claude:dev), and
# survives independently of the Claude pane.
if [[ -n "${CLAUDE_DEV_CMD:-}" ]]; then
    asclaude tmux new-window -t claude -n dev /usr/local/bin/claude-dev
    log "Dev server started in tmux window 'dev': $CLAUDE_DEV_CMD"
fi

# Optional SCM observer: polls the workspace repo's PRs and routes CI failures /
# change requests / merge conflicts into the autopilot task queue. Runs in its
# own 'scm' tmux window. Pair with CLAUDE_AUTOPILOT=1 + CLAUDE_AUTOPILOT_QUEUE=1
# so the same container consumes what it observes.
if [[ "${CLAUDE_SCM_OBSERVER:-0}" =~ ^(1|true|yes|on)$ ]]; then
    asclaude tmux new-window -t claude -n scm /usr/local/bin/claude-scm-observer
    log "SCM observer         : routing repo events into the queue (tmux window 'scm')"
    [[ "${CLAUDE_AUTOPILOT_QUEUE:-0}" =~ ^(1|true|yes|on)$ ]] || \
        log "SCM observer         : NOTE — enqueues tasks, but nothing consumes them without CLAUDE_AUTOPILOT=1 + CLAUDE_AUTOPILOT_QUEUE=1"
fi

# --- 12b. Remote Control watchdog -------------------------------------------
# Claude Code's RC bridge retries reconnection on its own — a transient network
# drop self-heals — but it can also fail terminally (logs a give-up and stops):
# the link then dies silently with no recovery while the `claude` process stays
# alive and the phone session goes dark (see docs/troubleshooting.md). The
# watchdog detects that terminal state from the RC debug log and respawns the
# session with --continue once the pane is idle.
RC_WATCHDOG_PID=""
if [[ "$CLAUDE_MODE" == "autopilot" ]]; then
    log "Remote Control watchdog skipped (autopilot mode — no Remote Control session)"
elif [[ "${CLAUDE_RC_WATCHDOG:-1}" != "0" ]]; then
    asclaude /usr/local/bin/claude-rc-watchdog &
    RC_WATCHDOG_PID=$!
    log "Remote Control watchdog started (disable with CLAUDE_RC_WATCHDOG=0)"
else
    log "Remote Control watchdog disabled (CLAUDE_RC_WATCHDOG=0)"
fi

echo
if [[ "$CLAUDE_MODE" == "autopilot" ]]; then
    log "Autopilot           : headless loop running '${CLAUDE_AUTOPILOT_CMD:-/next}' in tmux window 'main'"
else
    log "Remote Control name : $CLAUDE_PROJECT_NAME  (look for it in the Claude app Code tab)"
fi
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
    [[ -n "${RC_WATCHDOG_PID:-}" ]] && kill "$RC_WATCHDOG_PID" >/dev/null 2>&1 || true
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
