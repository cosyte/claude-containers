#!/usr/bin/env bash
# Does this CI run need the image smoke test? Prints `true` or `false` on stdout, exits 0.
# CI's `smoke` job runs it as its first step and runs the heavy steps (build, smoke) only on
# `true`, so the job always reports a `smoke` check: a required check that a job-level `if:` or
# a paths filter skipped would leave a docs-only pull request unable to merge.
#
#   scripts/smoke-needed.sh <event name>     (github.event_name), run in the checked-out repo
#
# - Any event but pull_request (a push to main, the nightly, a manual run): `true`.
# - pull_request: HEAD is the merge commit actions/checkout makes (fetch-depth 2, so both
#   parents are there); the change is `git diff HEAD^1 HEAD`, the pull request applied to its
#   base, with renames as a delete and an add so a path moved out of the image list counts.
#   `true` if any changed path is an image path (the list below), else `false`. The paths are
#   read NUL-separated (`-z`), so a name git would print quoted (a non-ASCII byte, a double
#   quote, a backslash, a newline) is matched as it is, never as a quoted string that misses.
# - When in doubt it runs the smoke: a HEAD that is not a merge commit prints `true` with a
#   warning. A git failure exits nonzero, which fails the job: never a silent `false`.
set -uo pipefail

# is_image_path <path>: the paths that change the image or how CI builds and smokes it
is_image_path() {
    case "$1" in
        Dockerfile|sshd_config|bash_profile|entrypoint.sh|Makefile|docker-compose.yml) return 0 ;;
        entrypoint.d/*|bin/*|claude-config/*|scripts/*|containers/*) return 0 ;;
        .dockerignore|test/smoke.sh|.github/workflows/ci.yml) return 0 ;;
    esac
    return 1
}

event="${1:-}"
[[ -n "$event" ]] || { echo "usage: $0 <event name>" >&2; exit 2; }

if [[ "$event" != pull_request ]]; then
    echo "smoke-needed: a $event run tests the whole tree: smoke runs" >&2
    echo true
    exit 0
fi

if ! git rev-parse --verify -q 'HEAD^2' >/dev/null; then
    echo "::warning::smoke-needed: HEAD is not a pull request merge commit: smoke runs" >&2
    echo true
    exit 0
fi

# Bash cannot hold a NUL in a variable, so the NUL-separated list goes through a temp file,
# which also keeps git's exit status.
list="$(mktemp)" || { echo "smoke-needed: mktemp failed" >&2; exit 1; }
trap 'rm -f "$list"' EXIT
git diff -z --no-renames --name-only 'HEAD^1' HEAD >"$list" || { echo "smoke-needed: git diff failed" >&2; exit 1; }

while IFS= read -r -d '' path; do
    [[ -n "$path" ]] || continue
    if is_image_path "$path"; then
        printf 'smoke-needed: %q is an image path: smoke runs\n' "$path" >&2
        echo true
        exit 0
    fi
done <"$list"

echo "smoke-needed: no image path changed: smoke's build and test steps are skipped" >&2
echo false
