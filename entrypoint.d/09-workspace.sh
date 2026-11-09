# shellcheck shell=bash
# --- 9. Workspace ------------------------------------------------------------
# A bind mount or pre-populated volume wins; otherwise clone GIT_REPO_URL.
UMBRELLA_PROFILE_D="/etc/profile.d/claude-umbrella.sh"   # COSYTE_UMBRELLA for SSH logins (root-only)
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

ws_repos_list="${GIT_REPOS:-}"     # unset is the common case: never expand it bare under set -u

# Umbrella mode (GIT_UMBRELLA=1): the one repo at /workspace (GIT_REPO_URL, or a checkout
# already there) is an umbrella that pins other repos as git submodules, and they come with
# it. Its submodule URLs are usually SSH (git@github.com:owner/repo.git) and a deploy key
# reaches one repo, so github.com SSH URLs are rewritten to HTTPS in the agent's global git
# config: the clone, and every later fetch and push in a submodule, then go over HTTPS with
# GH_TOKEN through gh's credential helper (§5). After the clone (below the mode branches),
# every boot checks out the submodules not checked out yet and never touches one that is.
# COSYTE_UMBRELLA names the umbrella's path for the tools that look for it. The decision and
# why: docs/architecture.md.
ws_umbrella=0
case "${GIT_UMBRELLA:-}" in
    1|true|yes|on) ws_umbrella=1 ;;
    ""|0|false|no|off) ;;
    *) die "GIT_UMBRELLA='${GIT_UMBRELLA}' is not a recognised value: 1/true/yes/on clones the repo at
       $WORKSPACE with its submodules, 0/false/no/off (or unset) does not." ;;
esac
if (( ws_umbrella )); then
    [[ -z "${ws_repos_list//[[:space:]]/}" ]] \
        || die "GIT_UMBRELLA and GIT_REPOS are both set: an umbrella brings its repos as submodules of
       the one repo at $WORKSPACE, not as sibling checkouts."
    for ws_from in 'git@github.com:' 'ssh://git@github.com/'; do
        # grep reads all of it (no -q): under pipefail an early exit could SIGPIPE git and
        # read as "absent", adding a duplicate line.
        asclaude git config --global --get-all url.https://github.com/.insteadOf 2>/dev/null \
            | grep -xF "$ws_from" >/dev/null \
            || asclaude git config --global --add url.https://github.com/.insteadOf "$ws_from"
    done
    log "Umbrella            : github.com SSH URLs go over HTTPS for the agent (git url.insteadOf)"
    [[ -n "${GH_TOKEN:-}" ]] \
        || log "WARNING: GIT_UMBRELLA without GH_TOKEN: HTTPS reaches public repos only, so a private submodule can be neither fetched nor pushed"
    unset ws_from
fi

# Multi-repo mode (GIT_REPOS, from claude-compose-gen --group or several claude-launch
# --repo): /workspace is a parent directory and each repo lives in /workspace/<name>, the
# last path component of its URL without .git. Entries are whitespace-separated
# URL[#BRANCH]. Every boot clones only what is missing, so a repo added to the list later
# appears on the next restart, and an existing checkout is never touched (it is the
# session's work, whatever state it is in). The session starts in /workspace and sees
# them all.
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
# The umbrella's submodules: the ones not checked out yet ("-" in `git submodule status`: a
# fresh clone's, a pin added since, or one an earlier boot could not fetch), the same as
# `git clone --recurse-submodules` the first time. One that cannot be fetched is a WARNING,
# never a failed boot: the next boot tries again, and a session can fetch it itself.
ws_unfetched() {
    asclaude git -C "$WORKSPACE" submodule status 2>/dev/null | sed -n 's/^-[0-9a-f]* //p' || true
}
if (( ws_umbrella )); then
    [[ -e "$WORKSPACE/.git" ]] \
        || die "GIT_UMBRELLA is set, but $WORKSPACE holds no repo at its root. Set GIT_REPO_URL to the
       umbrella, or bind-mount its checkout onto $WORKSPACE."
    mapfile -t ws_missing < <(ws_unfetched)
    if (( ${#ws_missing[@]} )); then
        log "Umbrella            : checking out ${#ws_missing[@]} submodules not checked out yet (${ws_missing[*]})"
        asclaude git -C "$WORKSPACE" submodule update --init --recursive -- "${ws_missing[@]}" || true
        mapfile -t ws_missing < <(ws_unfetched)
        (( ${#ws_missing[@]} == 0 )) \
            || log "WARNING: umbrella submodules still not checked out: ${ws_missing[*]} (GH_TOKEN must reach them; the next boot tries again)"
    fi
    export COSYTE_UMBRELLA="$WORKSPACE"
    { printf 'export COSYTE_UMBRELLA=%q\n' "$COSYTE_UMBRELLA" > "$UMBRELLA_PROFILE_D.tmp" \
        && chmod 644 "$UMBRELLA_PROFILE_D.tmp" && mv -f "$UMBRELLA_PROFILE_D.tmp" "$UMBRELLA_PROFILE_D"; } 2>/dev/null \
        || log "WARNING: could not write $UMBRELLA_PROFILE_D: an SSH login shell will not see COSYTE_UMBRELLA"
    log "Umbrella            : COSYTE_UMBRELLA=$COSYTE_UMBRELLA"
    unset ws_missing
else
    rm -f "$UMBRELLA_PROFILE_D" 2>/dev/null || true
fi
unset -f ws_unfetched

# Only the root and its top level here, so the sessions can write to /workspace; the rest
# of the tree is checked in the background once they are up (§12g).
own_tree "$WORKSPACE" -maxdepth 1 2>/dev/null || true
