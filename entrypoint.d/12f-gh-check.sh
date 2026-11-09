# shellcheck shell=bash
# --- 12f. GitHub token check --------------------------------------------------
# What GH_TOKEN can do on each github.com repo under /workspace (read, contents write, PR
# write, checks read), and whether the token holds a scope a session must never have
# (delete_repo, admin:org), probed read-only by claude-gh-check in the background so it never
# blocks or fails the boot. The result (no token in it) is world-readable at GH_CHECK_FILE;
# each repo missing a permission gets one WARNING line here, and a forbidden scope one ERROR
# line (the check exits 1 then, and its result is kept). Repos left unprobed past
# CLAUDE_GH_CHECK_MAX_REPOS, or a cap that is not a number, get a WARNING line too.
# docs/github-token.md says which token a session needs. Without GH_TOKEN a stale result is removed and nothing runs.
GH_CHECK_FILE="/run/claude/gh-check.txt"
GH_CHECK_CMD="/usr/local/bin/claude-gh-check"
if [[ -n "${GH_TOKEN:-}" ]]; then
    (
        rc=0
        out="$(asclaude "$GH_CHECK_CMD" 2>/dev/null)" || rc=$?
        [[ -n "$out" ]] || out="github: skipped (claude-gh-check failed, exit $rc)"
        mkdir -p "${GH_CHECK_FILE%/*}" && chmod 711 "${GH_CHECK_FILE%/*}" \
            && tmp="$(mktemp "$GH_CHECK_FILE.XXXXXX")" && printf '%s\n' "$out" > "$tmp" \
            && chmod 644 "$tmp" && mv -f "$tmp" "$GH_CHECK_FILE" \
            || log "WARNING: could not write $GH_CHECK_FILE"
        while IFS= read -r line; do
            [[ "$line" =~ \ NO ]] && log "WARNING: GH_TOKEN is missing a permission: $line (docs/github-token.md)"
            [[ "$line" == "github token: scopes FAIL"* ]] && log "ERROR: GH_TOKEN holds a scope a session must never have: $line"
            [[ "$line" == "github: not probed: "* || "$line" == "github: CLAUDE_GH_CHECK_MAX_REPOS="* ]] \
                && log "WARNING: $line (docs/github-token.md)"
        done <<<"$out"
        exit 0
    ) &
else
    rm -f "$GH_CHECK_FILE"
fi
