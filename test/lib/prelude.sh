# shellcheck shell=bash
# Sourced first by every test/*unit.sh. It makes a suite see the same environment in a session
# container as on a laptop or in CI:
#   - unsets what the stack sets in a session and the code under test reads (every CLAUDE_*,
#     GIT_REPOS, GIT_REPO_URL, GRADLE_OPTS): a session's own CLAUDE_GPU=1 or GIT_REPOS otherwise
#     reached the entrypoint and claude-launch under test, and failed workspace, sessions and kit,
#     and its GRADLE_OPTS (§12's caps) failed the facts checks in gradle-limits;
#   - umask 022, as the entrypoint runs (the §7a policy checks judge the modes of what tests make);
#   - its own TMPDIR under the system temp, removed when the suite ends whatever traps it sets:
#     the suite re-runs itself once in a child, and this parent waits and cleans up.

while IFS= read -r _v; do
    case "$_v" in CLAUDE_*|GIT_REPOS|GIT_REPO_URL|GRADLE_OPTS) unset "$_v" ;; esac
done < <(compgen -e)
unset _v
umask 022

if [[ -z "${CC_TEST_PRELUDE_TMP:-}" ]]; then
    CC_TEST_PRELUDE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/$(basename "${BASH_SOURCE[1]}" .sh).XXXXXX")" || exit 1
    export CC_TEST_PRELUDE_TMP
    trap 'rm -rf "$CC_TEST_PRELUDE_TMP"' EXIT   # also on Ctrl-C
    TMPDIR="$CC_TEST_PRELUDE_TMP" bash "${BASH_SOURCE[1]}" "$@"
    exit
fi
export TMPDIR="$CC_TEST_PRELUDE_TMP"
