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

# shellcheck disable=SC2034  # the sections in entrypoint.d/ read these
{
AUTH_DIR="/auth"                              # shared credentials volume
HOSTKEY_DIR="/etc/ssh/host-keys"              # shared host-key volume
BAKE_DIR="/opt/claude-config"                 # image-baked config source
AUTHKEYS_SRC="/etc/claude/authorized_keys"    # host-mounted, read-only
GITKEY_SRC="/etc/claude/git-key"              # host-mounted, read-only
WORKSPACE="/workspace"
}

log()  { echo "[entrypoint] $*"; }
die()  { echo "[entrypoint] ERROR: $*" >&2; exit 1; }
asclaude() { gosu "$CLAUDE_USER" env CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" HOME="$CLAUDE_HOME" "$@"; }
# Hand a tree to the agent user, touching only what is not already its own. `chown -R` writes
# every inode (a chown with the same owner still updates ctime), so on maker's config volume
# and ten-repo workspace on spinning disk it held every boot for minutes before any session
# started (2026-10-07). find only reads a tree that is already right. -h: a symlink itself,
# never its target, as chown -R did; find does not follow symlinks either. -execdir, not -exec:
# the workspace pass runs while the agent is up (§12f), and -h guards only the last component,
# so a parent directory swapped for a symlink between find and chown would hand the agent a
# root file. -execdir chowns ./name from inside the directory find already holds.
own_tree() {
    find "$@" \( ! -uid "$CLAUDE_UID" -o ! -gid "$CLAUDE_GID" \) \
        -execdir chown -h "$CLAUDE_UID:$CLAUDE_GID" {} +
}

# --- Sections ------------------------------------------------------------------
# Each numbered section is its own file in $ENTRYPOINT_D (entrypoint.d/ in the repo), named
# NN[x]-name.sh after its number, and sourced here in that order: into this shell, so the
# variables, functions and background jobs a section leaves are there for every later one,
# and `set -euo pipefail` holds inside each. Sorted in the C locale: elsewhere a collation
# that skips punctuation would put 00b- before 00-. Each section is announced as "§<n> <name>"
# so the boot log shows where every line came from. The sections still below the loop move
# into entrypoint.d/ next.
ENTRYPOINT_D=/usr/local/lib/claude/entrypoint.d
mapfile -t _sections < <(printf '%s\n' "$ENTRYPOINT_D"/[0-9]*.sh | LC_ALL=C sort)
[[ -f "${_sections[0]}" ]] || die "no sections in $ENTRYPOINT_D: the image is incomplete"
for _section in "${_sections[@]}"; do
    _name="${_section##*/}"; _name="${_name%.sh}"; _n="${_name%%-*}"
    log "§${_n#0} ${_name#*-}"
    # shellcheck source=/dev/null  # each file is linted on its own (Makefile LINT_SH)
    source "$_section"
done
unset _sections _section _name _n

# --- 7b. Browser decision (§10b acts on it) ----------------------------------
# Made here, before the session memory below, so the facts can say whether this session
# has the chrome-devtools MCP and §8e can install the frontend-debugging skill only when
# it does. CLAUDE_BROWSER is TRI-STATE (the whole contract is at §10b):
#   unset / empty / other -> auto (on iff the browser variant is baked),
#   1|true|yes|on -> on (fails loud in §10b when nothing is baked), 0|false|no|off -> off.
# Normalize: strip surrounding whitespace / a trailing CR (a CRLF-authored .env
# yields `1\r`, which must still match "1", not silently fall through to auto)
# and lowercase, so the tri-state match is robust to how the value was set.
_browser_baked() {
    command -v chrome-devtools-mcp >/dev/null 2>&1 && command -v chromium >/dev/null 2>&1
}
_cb="$(printf '%s' "${CLAUDE_BROWSER:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
BROWSER_MCP=off
case "$_cb" in
    0|false|no|off) ;;
    *) if _browser_baked; then BROWSER_MCP=on; fi ;;
esac

# --- 7c. Session memory: what this container has (+ the GPU note) ------------------
# Every session reads Claude Code's MANAGED memory file (root-owned, read above the
# user's own CLAUDE.md). At every boot it gets a "This container" section that
# claude-container-facts writes from probes run now (browser, chrome-devtools MCP, GPU,
# toolchains, /cache and /scratch, how to install more), and on a --gpu session the GPU
# note after it. It lives in the container layer and is rewritten on every boot, but
# never over a file an operator put there: ours carries one of the two markers.
# The paths are named on their own lines so test/container-facts-unit.sh can run this
# exact block unprivileged against a sandbox.
SESSION_MD=/etc/claude-code/CLAUDE.md
SESSION_MD_OWNER=root:root
FACTS_CMD=/usr/local/bin/claude-container-facts
GPU_NOTE_SRC=/opt/claude-config/CLAUDE.gpu.md
FACTS_MARK="claude-containers: container facts"
GPU_NOTE_MARK="claude-containers: GPU session note"
if [[ -e "$SESSION_MD" ]] && ! grep -qF -e "$FACTS_MARK" -e "$GPU_NOTE_MARK" "$SESSION_MD" 2>/dev/null; then
    log "Session memory      : NOT written, $SESSION_MD is an operator's own file"
else
    smd_tmp="$(mktemp)"
    # Bounded: each probe has its own 5s limit, this caps the whole run.
    if ! CLAUDE_FACTS_BROWSER_MCP="$BROWSER_MCP" CLAUDE_FACTS_GPU_STATE="$GPU_STATE_FILE" \
            timeout 60 "$FACTS_CMD" > "$smd_tmp" 2>/dev/null; then
        printf '<!-- %s -->\n## This container\n\n- The probe (claude-container-facts) failed at this start: nothing is known about this container.\n' \
            "$FACTS_MARK" > "$smd_tmp"
    fi
    smd_what="container facts"
    if [[ "${CLAUDE_GPU:-0}" =~ ^(1|true|yes|on)$ && -f "$GPU_NOTE_SRC" ]]; then
        { echo; cat "$GPU_NOTE_SRC"; } >> "$smd_tmp"
        smd_what="container facts + GPU note"
    fi
    if mkdir -p "${SESSION_MD%/*}" && chmod 755 "${SESSION_MD%/*}" \
            && install -m 644 "$smd_tmp" "$SESSION_MD" && chown "$SESSION_MD_OWNER" "$SESSION_MD"; then
        log "Session memory      : $SESSION_MD ($smd_what)"
    else
        log "Session memory      : WARNING, could not write $SESSION_MD"
    fi
    rm -f "$smd_tmp"
    unset smd_tmp smd_what
fi

# --- 8. Merge baked-in config ------------------------------------------------
# Everything baked into the image is overridable at runtime by mounting onto
# the target path (we only fill what's absent).

# 8a. Global CLAUDE.md: the image's copy at EVERY start (not only the first), so a
#     change to claude-config/CLAUDE.md reaches an existing container at its next start.
#     The one exception is the override: a file the operator mounted over the path (a
#     bind mount, so it has its own line in mountinfo) is left alone.
MOUNTINFO=/proc/self/mountinfo
if [[ -f "$BAKE_DIR/CLAUDE.md" ]]; then
    gmd="$CLAUDE_CONFIG_DIR/CLAUDE.md"
    if awk -v p="$gmd" '$5 == p { f = 1 } END { exit !f }' "$MOUNTINFO" 2>/dev/null; then
        log "Global CLAUDE.md    : left alone, $gmd is mounted (the operator's own)"
    elif ! cmp -s "$BAKE_DIR/CLAUDE.md" "$gmd"; then
        # Never fatal: a full volume (or a directory at the path) must not stop the boot.
        if install -o "$CLAUDE_UID" -g "$CLAUDE_GID" -m 644 "$BAKE_DIR/CLAUDE.md" "$gmd" 2>/dev/null; then
            log "Global CLAUDE.md    : installed the image's copy"
        else
            log "Global CLAUDE.md    : WARNING, could not install the image's copy at $gmd"
        fi
    fi
    unset gmd
fi

# 8b. settings.json: baked file is the base, existing user settings win on
#     conflict (recursive merge). Also injects unattended-operation defaults.
#     NOTE: env intentionally does NOT include DISABLE_TELEMETRY/DO_NOT_TRACK.
#     Those (and CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC) make Claude Code skip
#     the GrowthBook fetch, so the `tengu_ccr_bridge` gate defaults false and
#     Remote Control reports "not yet enabled for your account". RC is the point
#     of this image, so they must never be set. See docs/troubleshooting.md.
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
    > "$CLAUDE_CONFIG_DIR/settings.json"
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

# 8c. Plugins: declarative. Claude Code registers the marketplaces from settings.json on
#     startup; a baked plugin from a git source may still need `claude plugin install` once
#     (the runtime kit hook below installs what IT declares). We union the
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

# 8c-bis. Runtime kit injection: no rebuild required (bin/claude-kit).
# CLAUDE_EXTRA_MARKETPLACES: "name=url[#ref][,...]"  git source; "#ref" pins a branch or tag
#                            and turns autoUpdate off (a pin and auto-update contradict).
# CLAUDE_EXTRA_PLUGINS:      "plugin@marketplace[,...]"
# A declared marketplace replaces the settings.json entry of that name (adding, moving or
# dropping #ref takes effect at the next start); for enabledPlugins an existing value wins.
# The plugins are installed by the CLI, as the agent user, in §12d before any session starts.
if [[ -n "${CLAUDE_EXTRA_MARKETPLACES:-}" ]] || [[ -n "${CLAUDE_EXTRA_PLUGINS:-}" ]]; then
    if /usr/local/bin/claude-kit settings "$CLAUDE_CONFIG_DIR/settings.json"; then
        log "Merged runtime plugin marketplaces/plugins into settings.json"
    else
        log "WARNING: claude-kit could not merge CLAUDE_EXTRA_MARKETPLACES / CLAUDE_EXTRA_PLUGINS into settings.json"
    fi
    chown "$CLAUDE_UID:$CLAUDE_GID" "$CLAUDE_CONFIG_DIR/settings.json"
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

# 8e. Skills (one directory per skill, must contain SKILL.md). A skill is installed only
#     when what it needs is in this container (_skill_usable). One that is not is skipped,
#     and an unmodified copy a past start installed is removed; an edited one is kept.
_skill_usable() {  # _skill_usable <name>
    case "$1" in
        frontend-debugging) [[ "$BROWSER_MCP" == on ]] ;;  # chromium + the DevTools MCP (§7b)
        *) return 0 ;;
    esac
}
if [[ -d "$BAKE_DIR/skills" ]]; then
    install -d -o "$CLAUDE_UID" -g "$CLAUDE_GID" "$CLAUDE_CONFIG_DIR/skills"
    for d in "$BAKE_DIR"/skills/*/; do
        [[ -f "$d/SKILL.md" ]] || continue
        name="$(basename "$d")"
        t="$CLAUDE_CONFIG_DIR/skills/$name"
        if ! _skill_usable "$name"; then
            if [[ -d "$t" ]] && diff -rq "$d" "$t" >/dev/null 2>&1; then
                rm -rf "$t"
                log "Skill $name: removed, this container lacks what it needs"
            fi
            continue
        fi
        if [[ ! -d "$t" ]]; then
            cp -a "$d" "$t"
            chown -R "$CLAUDE_UID:$CLAUDE_GID" "$t"
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

# Multi-repo mode (GIT_REPOS, from claude-compose-gen --group or several claude-launch
# --repo): /workspace is a parent directory and each repo lives in /workspace/<name>, the
# last path component of its URL without .git. Entries are whitespace-separated
# URL[#BRANCH]. Every boot clones only what is missing, so a repo added to the list later
# appears on the next restart, and an existing checkout is never touched (it is the
# session's work, whatever state it is in). The session starts in /workspace and sees
# them all.
ws_repos_list="${GIT_REPOS:-}"     # unset is the common case: never expand it bare under set -u
if [[ -n "${ws_repos_list//[[:space:]]/}" ]]; then
    [[ -z "${GIT_REPO_URL:-}" ]] \
        || die "GIT_REPOS and GIT_REPO_URL are both set: a workspace holds one repo at its root,
       or several in subdirectories, not both."
    [[ ! -e "$WORKSPACE/.git" ]] \
        || die "GIT_REPOS is set, but $WORKSPACE already holds a single repo at its root.
       Cloning others inside it would nest repos. Use a fresh workspace volume for a
       multi-repo container."
    declare -A ws_repo_seen=(); ws_repo_names=()
    for ws_spec in $ws_repos_list; do
        ws_url="${ws_spec%%#*}" ws_branch=""
        [[ "$ws_spec" == *#* ]] && ws_branch="${ws_spec#*#}"
        ws_name="${ws_url%/}"; ws_name="${ws_name##*/}"; ws_name="${ws_name##*:}"; ws_name="${ws_name%.git}"
        [[ "$ws_name" =~ ^[A-Za-z0-9._-]+$ && "$ws_name" != "." && "$ws_name" != ".." ]] \
            || die "GIT_REPOS: cannot derive a directory name from '$ws_url'"
        [[ -z "${ws_repo_seen[$ws_name]:-}" ]] \
            || die "GIT_REPOS: two repos would both clone into $WORKSPACE/$ws_name"
        ws_repo_seen[$ws_name]=1; ws_repo_names+=("$ws_name")
        ws_dest="$WORKSPACE/$ws_name"
        if [[ -e "$ws_dest/.git" || -n "$(ls -A "$ws_dest" 2>/dev/null)" ]]; then
            log "Workspace repo      : $ws_name (existing checkout, left as it is)"
            continue
        fi
        clone_args=()
        [[ -n "$ws_branch" ]] && clone_args+=(--branch "$ws_branch")
        [[ -n "${GIT_REPO_DEPTH:-}" ]] && clone_args+=(--depth "$GIT_REPO_DEPTH")
        log "Workspace repo      : cloning $ws_url${ws_branch:+ (branch $ws_branch)} into $ws_dest"
        asclaude git clone "${clone_args[@]}" "$ws_url" "$ws_dest" \
            || die "git clone of $ws_url into $ws_dest failed (check the URL, the git SSH key, the branch)"
    done
    log "Workspace           : $WORKSPACE holds ${#ws_repo_names[@]} repos (${ws_repo_names[*]})"
    unset ws_repo_seen ws_repo_names ws_spec ws_url ws_branch ws_name ws_dest
elif [[ "$ws_populated" == "1" ]]; then
    log "Using existing workspace contents at $WORKSPACE"
elif [[ -n "${GIT_REPO_URL:-}" ]]; then
    log "Cloning $GIT_REPO_URL into $WORKSPACE"
    clone_args=()
    [[ -n "${GIT_REPO_BRANCH:-}" ]] && clone_args+=(--branch "$GIT_REPO_BRANCH")
    [[ -n "${GIT_REPO_DEPTH:-}"  ]] && clone_args+=(--depth "$GIT_REPO_DEPTH")
    asclaude git clone "${clone_args[@]}" "$GIT_REPO_URL" "$WORKSPACE" \
        || die "git clone failed (check GIT_REPO_URL / git SSH key / branch)"
else
    die "Empty workspace and no GIT_REPO_URL or GIT_REPOS. Set one, or bind-mount a
       checkout onto $WORKSPACE (use 'claude-launch --repo' or --workspace)."
fi
# Only the root and its top level here, so the sessions can write to /workspace; the rest
# of the tree is checked in the background once they are up (§12f).
own_tree "$WORKSPACE" -maxdepth 1 2>/dev/null || true

# --- 9b. This container's mise shims ----------------------------------------------
# The shared /cache/mise/shims holds a shim for every tool any container installed, and a shim
# with no version set here answers `command -v` and then fails. PATH holds a per-container
# view instead ($CLAUDE_STATE_DIR/mise-shims) linking only the tools that resolve here: the
# global config and the workspace's configs, so after §9. The shared dir is never changed.
MISE_SHIMS_CMD=/usr/local/bin/claude-mise-shims
if mise_shims_out="$(asclaude timeout 120 "$MISE_SHIMS_CMD" 2>&1)"; then
    log "mise shims          : ${mise_shims_out#claude-mise-shims: }"
else
    log "WARNING: mise shims: $MISE_SHIMS_CMD failed (${mise_shims_out:-no output}); tools mise"
    log "WARNING: provides read as \"command not found\" until it is run again."
fi
unset mise_shims_out

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

# --- 10b. Register chrome-devtools-mcp (frontend debugging) ------------------
# Registers the Chrome DevTools MCP server so Claude can navigate, evaluate,
# inspect console/network, take screenshots, run Lighthouse, etc. against any
# frontend the agent spins up in /workspace.
#
# CLAUDE_BROWSER is TRI-STATE: the browser image is meant to "just work", so a
# baked variant auto-enables the MCP with no second flag:
#   • unset / empty / other  → AUTO: register iff the browser variant is baked
#     (both chrome-devtools-mcp AND chromium on PATH, the functional signal a
#     registration actually needs; the image also carries a `claude.browser`
#     LABEL the launcher pre-flight reads). A lean image stays silent.
#   • 1|true|yes|on          → FORCE ON: register; if the binaries are NOT baked,
#     fail LOUD + actionable (rebuild hint), never a silent no-op.
#   • 0|false|no|off         → OPT OUT: skip even on a browser image.
# Registration is idempotent (the `claude mcp get` guard below), so re-runs and
# a resumed session never double-register. Headless, isolated profile (clean per
# session); --no-sandbox is required in unprivileged Docker.
#
# The --chromeArg flags below need chrome-devtools-mcp >=1.0 (the Dockerfile pin
# asserts this at build time). On 0.x they were silently dropped by yargs, Chrome
# exited with "No usable sandbox!", and every tool call failed "Target closed".
# --no-usage-statistics opts out of the telemetry 1.x sends to Google by default.
# _browser_baked, _cb and BROWSER_MCP are set in §7b.
_register_chrome_devtools_mcp() {
    if asclaude claude mcp get chrome-devtools >/dev/null 2>&1; then
        log "MCP 'chrome-devtools' already configured, skipping"
        return 0
    fi
    # Resolve the SAME chromium the detection probe found, rather than hardcoding
    # /usr/bin/chromium, so a variant that installs chromium elsewhere (or as a
    # differently-named binary on PATH) can't auto-register a config that then
    # points at a missing executable. Fall back to /usr/bin/chromium if unresolved.
    local chromium_path cdt_json
    chromium_path="$(command -v chromium 2>/dev/null || echo /usr/bin/chromium)"
    cdt_json="$(jq -n --arg exe "$chromium_path" '{
        type: "stdio",
        command: "chrome-devtools-mcp",
        args: [
            "--executablePath", $exe,
            "--headless",
            "--isolated",
            "--chromeArg=--no-sandbox",
            "--chromeArg=--disable-dev-shm-usage",
            "--chromeArg=--disable-gpu",
            "--no-usage-statistics"
        ],
        env: { CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS: "1" }
    }')"
    if asclaude claude mcp add-json --scope user chrome-devtools "$cdt_json" >/dev/null 2>&1; then
        log "Registered MCP server 'chrome-devtools' (headless Chromium)"
    else
        log "WARNING: failed to register chrome-devtools MCP"
        _browser_mcp_failed
    fi
}
# §7c and §8e acted on BROWSER_MCP=on; a registration that failed makes both untrue, so
# correct the session's facts line and take back an unmodified frontend-debugging skill.
_browser_mcp_failed() {
    BROWSER_MCP=off
    if grep -qF "$FACTS_MARK" "$SESSION_MD" 2>/dev/null; then
        sed -i 's/^- chrome-devtools MCP: on$/- chrome-devtools MCP: off (its registration failed at start)/' "$SESSION_MD" || true
    fi
    local t="$CLAUDE_CONFIG_DIR/skills/frontend-debugging"
    if [[ -d "$t" ]] && diff -rq "$BAKE_DIR/skills/frontend-debugging" "$t" >/dev/null 2>&1; then
        rm -rf "$t"
        log "Skill frontend-debugging: removed, the chrome-devtools MCP is not registered"
    fi
}
case "$_cb" in
    1|true|yes|on)
        # Explicit request: must be satisfiable, else fail loud (never silent).
        if _browser_baked; then
            _register_chrome_devtools_mcp
        else
            log "ERROR: CLAUDE_BROWSER=1 (or --browser) requested, but this image has no"
            log "       chrome-devtools-mcp / chromium baked in: the MCP cannot be enabled."
            log "       Rebuild the browser variant:  make build-browser"
            log "       (or:  make build WITH_BROWSER=1 CLAUDE_IMAGE=<tag>)."
            log "       Frontend debugging is UNAVAILABLE in this container until you do."
        fi
        ;;
    0|false|no|off)
        # Explicit opt-out: honored even on a browser image.
        # A registration a past start made lives on in the config volume: drop it, or the
        # session would have the tools while its facts say off.
        if asclaude claude mcp get chrome-devtools >/dev/null 2>&1; then
            if asclaude claude mcp remove --scope user chrome-devtools >/dev/null 2>&1; then
                log "chrome-devtools MCP disabled (CLAUDE_BROWSER=off): removed the registration a past start made"
            else
                log "WARNING: CLAUDE_BROWSER=off, but the chrome-devtools MCP a past start registered could not be removed"
            fi
        elif _browser_baked; then
            log "chrome-devtools MCP disabled (CLAUDE_BROWSER=off); skipping"
        fi
        ;;
    *)
        # Auto: a browser image enables the MCP by itself; a lean image is silent.
        if _browser_baked; then
            log "Browser image detected (chromium + chrome-devtools-mcp present): auto-registering chrome-devtools MCP"
            _register_chrome_devtools_mcp
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
# so the healthcheck, a separate process spawned by dockerd, sees it too.
export CLAUDE_RC_DEBUG_LOG="${CLAUDE_RC_DEBUG_LOG-/tmp/claude-rc-debug.log}"
export CLAUDE_PROJECT_NAME CLAUDE_EXTRA_ARGS="${CLAUDE_EXTRA_ARGS:-}" \
       CLAUDE_DEV_CMD="${CLAUDE_DEV_CMD:-}"

# Model selection: default to the best available model. The `opus` alias always
# resolves to the latest Opus, so the fleet tracks the strongest model without a
# code change when a newer one ships. Override per-container with CLAUDE_MODEL:
# any Claude Code alias (opus, sonnet, haiku, opusplan, default) or a full model
# id (e.g. claude-opus-4-8). Both the interactive session and the autopilot loop
# read it and pass `--model`. To defer to Claude Code's own default, set
# CLAUDE_MODEL=default (empty/unset falls back to opus, the best available).
export CLAUDE_MODEL="${CLAUDE_MODEL:-opus}"
log "Model               : $CLAUDE_MODEL (override with CLAUDE_MODEL; 'default' = Claude Code's pick)"

# Two modes:
#   interactive (default): main pane is claude-session (Remote Control + SSH).
#   autopilot (CLAUDE_AUTOPILOT=1): main pane is claude-autopilot, a headless Claude
#                           loop running CLAUDE_AUTOPILOT_CMD for unattended build-out;
#                           there is no Remote Control link, so the RC watchdog is
#                           skipped.
# Either way SSH attaches to the live tmux pane. The third mode, CLAUDE_CONTROLLER, was
# removed and is refused up in §0b: long before we get here.
case "${CLAUDE_AUTOPILOT:-0}" in
    1|true|yes|on) CLAUDE_MODE=autopilot;   MAIN_PANE_CMD=/usr/local/bin/claude-autopilot ;;
    # --boot: resume main's last conversation when CLAUDE_MAIN_RESUME=1; otherwise (the
    # default) a fresh one, exactly as before named sessions existed.
    *)             CLAUDE_MODE=interactive; MAIN_PANE_CMD="/usr/local/bin/claude-session --boot" ;;
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
# Named sessions (bin/claude-sessions, §12d). Exported so the tmux server carries them:
# claude-sessions run from an SSH login reads them back from tmux's global environment.
export CLAUDE_SESSIONS="${CLAUDE_SESSIONS:-}" \
       CLAUDE_MAIN_RESUME="${CLAUDE_MAIN_RESUME:-0}" \
       CLAUDE_RC_WATCHDOG="${CLAUDE_RC_WATCHDOG:-1}"

# OpenTelemetry: opt-in fleet observability. Claude Code reads OTEL_* + the
# enable flag straight from the process environment (env > settings.json), and
# the tmux panes inherit this exported env, so we just compose sane defaults and
# a per-container resource tag: no settings.json surgery, and the auth header (a
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
        log "OpenTelemetry        : WARNING, enabled but OTEL_EXPORTER_OTLP_ENDPOINT is empty; nothing will be exported"
fi

# --- 12-threads. Library thread pools --------------------------------------------------
# OpenMP, OpenBLAS, MKL, numexpr and Accelerate size their pools to the HOST's CPU count:
# nproc ignores the cgroup quota. On a 56-thread host `import numpy, build123d` alone starts
# 111 threads, and threads count against pids.max. Parallel test workers multiplied that:
# two pytest-xdist runs of 28 workers held ~8,000 threads, hit a pids.max of 8192, and every
# Claude session that then needed a thread crashed. Cap each process's pools unless the
# operator (or the image) already set a variable; CLAUDE_THREADS_PER_PROCESS=0 leaves them
# alone. A repo's own .claude/settings.json env still overrides these for its session.
# Written to /etc/profile.d as well, since an SSH login gets a fresh environment.
THREADS_PROFILE_D="/etc/profile.d/claude-threads.sh"
_tpp="${CLAUDE_THREADS_PER_PROCESS:-4}"
if [[ "$_tpp" =~ ^[1-9][0-9]*$ ]]; then
    : > "$THREADS_PROFILE_D.tmp" 2>/dev/null || true
    for _v in OMP_NUM_THREADS OPENBLAS_NUM_THREADS MKL_NUM_THREADS NUMEXPR_NUM_THREADS VECLIB_MAXIMUM_THREADS; do
        [[ -n "${!_v:-}" ]] || export "$_v=$_tpp"
        printf 'export %s="${%s:-%s}"\n' "$_v" "$_v" "${!_v}" >> "$THREADS_PROFILE_D.tmp" 2>/dev/null || true
    done
    mv -f "$THREADS_PROFILE_D.tmp" "$THREADS_PROFILE_D" 2>/dev/null && chmod 644 "$THREADS_PROFILE_D" 2>/dev/null || true
    log "Thread pools        : OMP/OpenBLAS/MKL/numexpr/vecLib ${OMP_NUM_THREADS} per process (CLAUDE_THREADS_PER_PROCESS; 0 = leave them alone)"
else
    rm -f "$THREADS_PROFILE_D" 2>/dev/null || true
    log "Thread pools        : NOT capped (CLAUDE_THREADS_PER_PROCESS=${_tpp}); libraries size them to the host's $(nproc) CPUs"
fi
unset _tpp

# Native Claude Code CLI tuning knobs (real upstream env vars the `claude`
# binary reads directly, see .env.example). Nothing to translate here, just
# surface non-default values in the boot log for operator visibility; a
# default fleet (all unset) stays quiet.
for _v in CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION BASH_DEFAULT_TIMEOUT_MS BASH_MAX_TIMEOUT_MS API_TIMEOUT_MS; do
    [[ -n "${!_v:-}" ]] && log "CLI tuning           : ${_v}=${!_v}"
done

# --- 12a. Egress lockdown (opt-in) -------------------------------------------
# Apply a default-deny firewall NOW, after the entrypoint's own setup (clone,
# plugin install) has finished with open egress, and as root (we still hold
# NET_ADMIN) before the unprivileged agent starts, so the agent runs sealed and
# cannot alter its own rules.
#
# TWO POSTURES, CHOSEN BY SPELLING. Fail-open stays the default and is what
# 1|true|yes|on have always meant: a firewall that could not be applied is a loud
# log line and the agent starts anyway, because a container that bricks a
# homelab's connectivity on a bad allowlist is the worse regression. `strict` is
# the fail-CLOSED spelling for an operator running an agent on untrusted input:
# same firewall, same ruleset, same log lines, but a run that leaves BOTH families
# unrestricted REFUSES TO START THE AGENT instead of proceeding. Lockdown stops
# being a request and becomes a requirement, and the operator escapes a refusing
# container by changing this one variable back.
#
# PER FAMILY, ALWAYS. A container can route IPv4 and IPv6, and the firewall can
# succeed on one and fail on the other, so there is no honest single-sentence
# answer to "is lockdown active". This block therefore never emits an unqualified
# "active": every line below names BOTH families and says, for each, whether it
# is default-deny or UNRESTRICTED. An operator reading `claude-logs` sees the
# unprotected family by name, which is the whole point of the line.
#
# The firewall's exit status IS the per-family verdict (see bin/claude-egress-firewall):
#   0 both default-deny · 2 IPv4 default-deny + IPv6 open · anything else both open.
# Note `set -e` is on, so the status is captured with `|| rc=$?`, never bare.
EGRESS_FIREWALL_BIN="/usr/local/bin/claude-egress-firewall"
if [[ "${CLAUDE_EGRESS_LOCKDOWN:-0}" =~ ^(1|true|yes|on|strict)$ ]]; then
    egress_strict=0
    if [[ "${CLAUDE_EGRESS_LOCKDOWN:-0}" == "strict" ]]; then egress_strict=1; fi
    egress_rc=0
    "$EGRESS_FIREWALL_BIN" || egress_rc=$?
    case "$egress_rc" in
        0) log "Egress lockdown      : IPv4 default-deny, IPv6 default-deny (allowlist + CLAUDE_EGRESS_EXTRA_HOSTS)" ;;
        2) log "Egress lockdown      : IPv4 default-deny, IPv6 UNRESTRICTED (the IPv6 ruleset could not be applied, see [egress] lines above)" ;;
        # Every OTHER status means the firewall applied NOTHING (fail_open() exits 1
        # on all five of its reasons, and a status this entrypoint cannot interpret
        # is read the same way: claim nothing). The log line is identical either way;
        # what strict adds is that the entrypoint stops here instead of falling
        # through to the tmux launch on the next statement.
        *) log "Egress lockdown      : IPv4 UNRESTRICTED, IPv6 UNRESTRICTED (FAILED to apply, egress left OPEN, see [egress] lines above)"
           if (( egress_strict == 1 )); then
               die "Egress lockdown was requested STRICTLY (CLAUDE_EGRESS_LOCKDOWN=strict) and the
       ruleset could NOT be applied: claude-egress-firewall exited $egress_rc, so this
       container has UNRESTRICTED egress on both address families. Starting the agent
       now is the exact outcome strict exists to prevent, so it is not started.
       The [egress] lines above name the cause (no NET_ADMIN capability, no iptables
       in the image, or an allowlist that resolved to nothing). Fix that, or set
       CLAUDE_EGRESS_LOCKDOWN=1 for the fail-open posture that logs and boots anyway."
           fi ;;
    esac
    # PERIODIC RE-RESOLVE. The allowlist above is a snapshot of DNS at boot, and this
    # container is meant to run for weeks: a CDN that rotates addresses turns the
    # snapshot into a set of rules pointing at hosts nobody serves any more, and the
    # agent's tooling starts failing at a moment nobody is watching. So a container
    # under lockdown can re-resolve on an interval, committing each refreshed ruleset
    # through the same atomic restore the boot pass used.
    #
    # IT RUNS HERE, AS ROOT, and it is started BEFORE the privilege drop for the same
    # reason the boot pass is: the agent has no NET_ADMIN and cannot signal a root
    # process, so it can neither alter what the refresh commits nor stop it happening.
    #
    # THE POSTURE IS ALWAYS STATED. Absent, malformed and non-positive intervals are
    # one case (no refresh), and silence about it would leave an operator who typed
    # `CLAUDE_EGRESS_REFRESH_INTERVAL=15m` believing their allowlist was being kept
    # current when it never will be. Only the "Egress lockdown" lines above are the
    # per-family posture contract; this is a separate line and does not touch it.
    egress_refresh="${CLAUDE_EGRESS_REFRESH_INTERVAL:-}"
    if [[ -z "$egress_refresh" ]]; then
        log "Egress refresh       : OFF (CLAUDE_EGRESS_REFRESH_INTERVAL is not set; the allowlist is resolved once, at boot, and pinned addresses go stale as CDNs rotate)"
    elif [[ ! "$egress_refresh" =~ ^[0-9]+$ ]] || (( 10#$egress_refresh <= 0 )); then
        log "Egress refresh       : OFF (CLAUDE_EGRESS_REFRESH_INTERVAL='${egress_refresh}' is not a positive whole number of seconds, so it cannot be an interval; the allowlist is resolved once, at boot)"
    elif [[ "$egress_rc" != 0 && "$egress_rc" != 2 ]]; then
        log "Egress refresh       : OFF (the boot pass committed no ruleset, so there is nothing to refresh; re-committing later would seal a container this log has already reported as UNRESTRICTED)"
    else
        "$EGRESS_FIREWALL_BIN" --refresh-daemon &
        log "Egress refresh       : every ${egress_refresh}s, as root (re-resolves the same allowlist and re-commits it atomically; a lookup that comes back empty RETAINS the ruleset in force and is logged by name, never narrowed)"
    fi
elif [[ -n "${CLAUDE_EGRESS_LOCKDOWN:-}" ]] && [[ ! "${CLAUDE_EGRESS_LOCKDOWN}" =~ ^(0|false|no|off)$ ]]; then
    # An unrecognised value: neither an off value nor an on/strict spelling. Silence
    # here is the failure mode strict exists to end, because a mistyped `stict` (or a
    # trailing space) would otherwise read as a deliberate "off" and the operator
    # would believe they were contained. WARN, never die: refusing to boot on a
    # stale or fat-fingered .env line would be a worse regression than the one being
    # reported, which is the same trade section 0 makes for the retired vars.
    log "Egress lockdown      : IPv4 UNRESTRICTED, IPv6 UNRESTRICTED (CLAUDE_EGRESS_LOCKDOWN='${CLAUDE_EGRESS_LOCKDOWN}' is not a recognised value, so NO firewall was applied; recognised: 0/false/no/off = off, 1/true/yes/on = lockdown that fails OPEN, strict = lockdown that refuses to start the agent when it cannot be applied)"
fi

# Named sessions, step 1 of 2 (§12d is step 2): bring the registry in line with
# CLAUDE_SESSIONS and pre-accept workspace trust for every session directory NOW, while no
# Claude process is running to rewrite .claude.json under us. The trust seeded for
# /workspace in §7 does not cover /workspace/<repo>: without this a named session would sit
# on the trust dialog. Never fatal.
# The kit's plugins (CLAUDE_EXTRA_MARKETPLACES / CLAUDE_EXTRA_PLUGINS, §8c-bis) are installed
# here, before any Claude session exists, so every session loads them from its first start
# (a plugin's SessionStart hook included). Bounded per CLI call, and never fatal: a kit that
# cannot be fetched is a warning in this log, and the container boots without it.
if [[ -n "${CLAUDE_EXTRA_MARKETPLACES:-}" ]] || [[ -n "${CLAUDE_EXTRA_PLUGINS:-}" ]]; then
    asclaude /usr/local/bin/claude-kit install \
        || log "WARNING: claude-kit install failed; declared plugins may be missing (claude-kit status)"
fi

asclaude /usr/local/bin/claude-sessions prepare \
    || log "WARNING: claude-sessions prepare failed; named sessions may be missing (claude-sessions ls)"

# tmux server runs as the claude user; the main pane command falls back to an
# interactive shell if it exits, so SSH stays usable. The pane lives in window
# 'main' (the RC watchdog respawns it by name in interactive mode).
asclaude tmux new-session -d -s claude -n main -x 220 -y 50 "$MAIN_PANE_CMD"
# A degraded GPU (§2b) stays visible to anyone attached, not only in the boot log.
if [[ -n "$GPU_DEGRADED_REASON" ]]; then
    asclaude tmux set-option -t claude status-right-length 120 >/dev/null 2>&1 || true
    asclaude tmux set-option -t claude status-right \
        "#[bg=red,fg=white,bold] GPU DEGRADED: ${GPU_DEGRADED_REASON//#/##} (claude-gpu status) " >/dev/null 2>&1 || true
fi
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
        log "SCM observer         : NOTE, enqueues tasks, but nothing consumes them without CLAUDE_AUTOPILOT=1 + CLAUDE_AUTOPILOT_QUEUE=1"
fi

# --- 12b. Remote Control watchdog -------------------------------------------
# Claude Code's RC bridge retries reconnection on its own: a transient network
# drop self-heals, but it can also fail terminally (logs a give-up and stops):
# the link then dies silently with no recovery while the `claude` process stays
# alive and the phone session goes dark (see docs/troubleshooting.md). The
# watchdog detects that terminal state from the RC debug log and respawns the
# session with --continue once the pane is idle.
RC_WATCHDOG_PID=""
if [[ "$CLAUDE_MODE" == "autopilot" ]]; then
    log "Remote Control watchdog skipped ($CLAUDE_MODE mode, no Remote Control session)"
elif [[ "${CLAUDE_RC_WATCHDOG:-1}" != "0" ]]; then
    asclaude /usr/local/bin/claude-rc-watchdog &
    RC_WATCHDOG_PID=$!
    log "Remote Control watchdog started (disable with CLAUDE_RC_WATCHDOG=0)"
else
    log "Remote Control watchdog disabled (CLAUDE_RC_WATCHDOG=0)"
fi

# --- 12c. Usage-limit account-rotation watchdog (multi-account mode only) ----
# Rotates to a different pre-authenticated account when the active one hits
# its usage limit, resuming the same conversation. Only meaningful with
# CLAUDE_ACCOUNTS set (nothing to rotate to otherwise) and in interactive
# mode (autopilot has its own reset-time backoff, bin/claude-autopilot).
USAGE_WATCHDOG_PID=""
if [[ "$CLAUDE_MODE" == "autopilot" || -z "${CLAUDE_ACCOUNTS:-}" ]]; then
    : # nothing to watch
elif [[ "${CLAUDE_USAGE_WATCHDOG:-1}" != "0" ]]; then
    asclaude /usr/local/bin/claude-usage-watchdog &
    USAGE_WATCHDOG_PID=$!
    log "Usage-limit watchdog started (accounts: $CLAUDE_ACCOUNTS; disable with CLAUDE_USAGE_WATCHDOG=0)"
else
    log "Usage-limit watchdog disabled (CLAUDE_USAGE_WATCHDOG=0)"
fi

# --- 12d. Named sessions ------------------------------------------------------
# CLAUDE_SESSIONS (claude-launch --session, claude-compose-gen --session) declares more
# Claude sessions beside main, each in its own tmux window with its own Remote Control
# link, directory, model and optional first prompt / goal; `claude-sessions new` adds more
# at runtime and those persist on the config volume. `prepare` (above, before main started)
# reconciled the declaration; `boot` starts every registered session that was not stopped
# by hand, resuming its last conversation. It never fails the boot: a bad entry is skipped
# with a log line.
#
# The supervisor always runs (it is cheap): it records which conversation each window is
# running, so a restart or an RC recovery resumes exactly that one, and keeps a Remote
# Control watchdog beside every named session.
asclaude /usr/local/bin/claude-sessions boot --no-reconcile \
    || log "WARNING: claude-sessions boot failed; named sessions may be missing (claude-sessions ls)"
asclaude /usr/local/bin/claude-sessions supervise &
SESSIONS_PID=$!
# The kit's optional start command (CLAUDE_EXTRA_START_CMD), once per container start, in the
# background, after the sessions are up. Never fatal.
if [[ -n "${CLAUDE_EXTRA_START_CMD:-}" ]]; then
    asclaude /usr/local/bin/claude-kit start \
        || log "WARNING: claude-kit start failed; CLAUDE_EXTRA_START_CMD did not run (claude-kit status)"
fi

# --- 12e. GitHub token check --------------------------------------------------
# What GH_TOKEN can do on each github.com repo under /workspace (read, contents write, PR
# write, checks read), probed read-only by claude-gh-check in the background so it never
# blocks or fails the boot. The result (no token in it) is world-readable at GH_CHECK_FILE;
# each repo missing a permission gets one WARNING line here. docs/github-token.md says which
# permissions a session needs. Without GH_TOKEN a stale result is removed and nothing runs.
GH_CHECK_FILE="/run/claude/gh-check.txt"
GH_CHECK_CMD="/usr/local/bin/claude-gh-check"
if [[ -n "${GH_TOKEN:-}" ]]; then
    (
        out="$(asclaude "$GH_CHECK_CMD" 2>/dev/null)" || out="github: skipped (claude-gh-check failed)"
        mkdir -p "${GH_CHECK_FILE%/*}" && chmod 711 "${GH_CHECK_FILE%/*}" \
            && tmp="$(mktemp "$GH_CHECK_FILE.XXXXXX")" && printf '%s\n' "$out" > "$tmp" \
            && chmod 644 "$tmp" && mv -f "$tmp" "$GH_CHECK_FILE" \
            || log "WARNING: could not write $GH_CHECK_FILE"
        while IFS= read -r line; do
            [[ "$line" =~ \ NO ]] && log "WARNING: GH_TOKEN is missing a permission: $line (docs/github-token.md)"
        done <<<"$out"
        exit 0
    ) &
else
    rm -f "$GH_CHECK_FILE"
fi

# --- 12f. Workspace ownership, the deep pass (background) ---------------------
# §9 owned the workspace root and its top level; the rest is checked here, after sshd and the
# sessions are up. Even a pass that changes nothing reads every inode, and on one spinning disk
# a monorepo with per-project node_modules held the boot for over 25 minutes with no sshd and
# no session (a real host, 2026-10-07). Until the pass reaches it, a deeper file with a foreign
# owner (a bind mount from another uid) is read-only to the agent.
(
    ws_own_start=$SECONDS
    own_tree "$WORKSPACE" 2>/dev/null || true
    log "Workspace ownership : checked in $(( SECONDS - ws_own_start ))s (background)"
) &

echo
if [[ "$CLAUDE_MODE" == "autopilot" ]]; then
    if [[ -n "${CLAUDE_AUTOPILOT_CMD:-}" ]]; then
        log "Autopilot           : headless loop running '${CLAUDE_AUTOPILOT_CMD}' in tmux window 'main'"
    else
        log "Autopilot           : queue consumer in tmux window 'main' (no CLAUDE_AUTOPILOT_CMD, idles when the queue is empty)"
    fi
else
    log "Remote Control name : $CLAUDE_PROJECT_NAME  (look for it in the Claude app Code tab)"
fi
log "SSH                 : connect, you'll attach to the live tmux session"
_named="$(asclaude /usr/local/bin/claude-sessions names 2>/dev/null | grep -vx main | tr '\n' ' ' || true)"
[[ -n "${_named// }" ]] && \
    log "Named sessions      : ${_named% }  (claude-sessions ls; Remote Control ${CLAUDE_PROJECT_NAME}-<name>)"
unset _named
[[ -n "${CLAUDE_DEV_CMD:-}" ]] && \
    log "Dev window          : tmux select-window -t claude:dev  (after SSH attach)"
echo

# --- 13. Stay alive + graceful shutdown --------------------------------------
shutdown() {
    log "Shutting down"
    # Note every window's current conversation first, so the next boot resumes exactly it
    # (the supervisor only records every 15s). Bounded: a stop must never hang on this.
    timeout 5 gosu "$CLAUDE_USER" env CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" HOME="$CLAUDE_HOME" \
        /usr/local/bin/claude-sessions record >/dev/null 2>&1 || true
    asclaude tmux kill-server >/dev/null 2>&1 || true
    pkill -x sshd >/dev/null 2>&1 || true
    kill "$RECONCILE_PID" >/dev/null 2>&1 || true
    [[ -n "${ACCT_SWITCH_PID:-}" ]] && kill "$ACCT_SWITCH_PID" >/dev/null 2>&1 || true
    [[ -n "${RC_WATCHDOG_PID:-}" ]] && kill "$RC_WATCHDOG_PID" >/dev/null 2>&1 || true
    [[ -n "${USAGE_WATCHDOG_PID:-}" ]] && kill "$USAGE_WATCHDOG_PID" >/dev/null 2>&1 || true
    [[ -n "${SESSIONS_PID:-}" ]] && kill "$SESSIONS_PID" >/dev/null 2>&1 || true
    exit 0
}
trap shutdown TERM INT

# Keep PID 1 alive while the container should run. If the tmux server dies
# entirely (rare), exit so Docker's restart policy can recover it.
#
# Require several CONSECUTIVE failures, not one. This probe is not a pure read:
# `asclaude` is gosu + env + tmux, so every check costs three forks. When the container
# is out of PIDs: the cgroup pids.max counts THREADS, so a browser session reaches it long before the process count suggests: fork returns EAGAIN and
# the probe fails against a tmux that is perfectly alive. Treating that one failure as
# "tmux died" tore a healthy container down, and the restart policy then brought it back
# with an empty session, losing the user's work. Observed twice in 16h on a real host:
# the entrypoint logged `fork: retry: Resource temporarily unavailable` four seconds
# after it reported "tmux session ended". Retrying costs a few extra seconds when tmux is genuinely gone;
# not retrying costs a live session on any transient resource blip.
LIVENESS_MAX_FAILURES="${CLAUDE_LIVENESS_MAX_FAILURES:-3}"
liveness_failures=0
while :; do
    if asclaude tmux has-session -t claude >/dev/null 2>&1; then
        liveness_failures=0
    else
        liveness_failures=$(( liveness_failures + 1 ))
        if (( liveness_failures >= LIVENESS_MAX_FAILURES )); then
            break
        fi
        log "tmux liveness probe failed (${liveness_failures}/${LIVENESS_MAX_FAILURES}): retrying in 5s"
    fi
    sleep 5 & wait $!
done
log "tmux session ended (liveness probe failed ${LIVENESS_MAX_FAILURES}x consecutively)"
shutdown
