# shellcheck shell=bash
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
# of the tree is checked in the background once they are up (§12g).
own_tree "$WORKSPACE" -maxdepth 1 2>/dev/null || true
