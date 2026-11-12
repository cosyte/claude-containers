#!/usr/bin/env bash
# Unit tests for CI's smoke decision: NO docker, NO root, NO network.
#   - scripts/smoke-needed.sh, run in a throwaway repo whose HEAD is a pull request merge commit
#     (what actions/checkout makes): a docs-only change prints false, a change to any image path
#     prints true; a push, nightly or manual run prints true; a HEAD that is no merge commit
#     prints true (when in doubt, smoke runs); a rename out of an image path counts; an image
#     path git would print quoted (a non-ASCII byte, a space, a double quote, a newline) counts
#   - .github/workflows/ci.yml: the smoke job has no job-level if: or needs:, so the required
#     smoke check always reports (a skipped required check blocks the merge); no separate
#     changes job; its checkout fetches depth 2; its first step after checkout runs the script;
#     and every later step runs only when the script said true
# shellcheck source=test/lib/prelude.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/prelude.sh"
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/smoke-needed.sh"
CI="$REPO_ROOT/.github/workflows/ci.yml"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

# A throwaway identity for the throwaway repos, never the checkout's.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# pr_repo <file>...: a repo whose base has README.md, Dockerfile and docs/a.md, a PR branch that
# appends to each named file, and HEAD the merge of the PR into the base (first parent the
# base, as in the merge commit a pull_request run checks out). Prints the repo path only.
pr_repo() {
    local d f
    d="$(mktemp -d "$TMPD/r.XXXXXX")"
    {
        git init -q -b main "$d"
        mkdir -p "$d/docs"
        echo base >"$d/README.md"; echo 'FROM scratch' >"$d/Dockerfile"; echo base >"$d/docs/a.md"
        git -C "$d" add -A && git -C "$d" commit -qm base
        git -C "$d" checkout -qb pr
        for f in "$@"; do mkdir -p "$d/$(dirname "$f")"; echo "change $f" >>"$d/$f"; done
        git -C "$d" add -A && git -C "$d" commit -qm pr
        git -C "$d" checkout -q main
        git -C "$d" merge -q --no-ff -m merge pr
    } >/dev/null
    echo "$d"
}

# decide <repo> <event>: the script's stdout (stderr dropped), then its exit status
decide() { (cd "$1" && "$SCRIPT" "$2" 2>/dev/null); }

test_script_exists() {
    [[ -x "$SCRIPT" ]] && ok "scripts/smoke-needed.sh exists and is executable" \
        || bad "scripts/smoke-needed.sh is missing or not executable"
}

test_docs_only_pr_skips_the_heavy_steps() {
    local d out rc
    d="$(pr_repo README.md docs/a.md docs/new.md CONTRIBUTING.md test/docs-unit.sh)"
    out="$(decide "$d" pull_request)"; rc=$?
    [[ $rc -eq 0 && "$out" == false ]] \
        && ok "a docs-only pull request: false (the job passes without building)" \
        || bad "docs-only pull request: rc=$rc out='$out', want rc=0 out=false"
}

test_each_image_path_runs_smoke() {
    local p d out rc miss=""
    for p in Dockerfile sshd_config bash_profile entrypoint.sh entrypoint.d/10-x.sh \
             bin/claude-launch claude-config/settings.json scripts/x.sh containers/x.conf \
             test/smoke.sh Makefile docker-compose.yml .dockerignore .github/workflows/ci.yml; do
        d="$(pr_repo README.md "$p")"
        out="$(decide "$d" pull_request)"; rc=$?
        [[ $rc -eq 0 && "$out" == true ]] || miss+=" $p(rc=$rc out='$out')"
    done
    [[ -z "$miss" ]] && ok "a pull request touching any image path: true (the full smoke runs)" \
        || bad "image paths that did not run smoke:$miss"
}

test_lookalike_paths_do_not_run_smoke() {
    local d out
    d="$(pr_repo docs/Dockerfile.md test/smoke-unit.sh .github/workflows/other.yml binx/a)"
    out="$(decide "$d" pull_request)"
    [[ "$out" == false ]] && ok "lookalike paths (docs/Dockerfile.md, test/smoke-unit.sh, another workflow): false" \
        || bad "lookalike paths: out='$out', want false"
}

# An image path with a byte git quotes by default (core.quotePath) must still match the list: a
# quoted name starts with a double quote and would match nothing, a false that skips the smoke.
test_quoted_image_paths_run_smoke() {
    local p d out rc miss=""
    for p in 'claude-config/café.md' 'claude-config/a b.md' 'bin/a"b' $'entrypoint.d/a\nb.sh' \
             'containers/a\b.conf' $'claude-config/tab\there.md'; do
        d="$(pr_repo README.md "$p")"
        out="$(decide "$d" pull_request)"; rc=$?
        [[ $rc -eq 0 && "$out" == true ]] || miss+=" $(printf '%q' "$p")(rc=$rc out='$out')"
    done
    [[ -z "$miss" ]] && ok "an image path git would quote (non-ASCII, space, double quote, newline, backslash, tab): true" \
        || bad "quoted image paths that did not run smoke:$miss"
    d="$(pr_repo 'docs/café.md' 'docs/a b.md' $'docs/a\nb.md')"
    out="$(decide "$d" pull_request)"; rc=$?
    [[ $rc -eq 0 && "$out" == false ]] && ok "docs paths with the same odd bytes: still false" \
        || bad "odd docs-only paths: rc=$rc out='$out', want rc=0 out=false"
}

test_rename_out_of_an_image_path_runs_smoke() {
    local d out
    d="$TMPD/rename"
    git init -q -b main "$d"
    echo 'FROM scratch' >"$d/Dockerfile"
    git -C "$d" add -A && git -C "$d" commit -qm base
    git -C "$d" checkout -qb pr
    mkdir -p "$d/docs" && git -C "$d" mv Dockerfile docs/Dockerfile.old && git -C "$d" commit -qm pr
    git -C "$d" checkout -q main && git -C "$d" merge -q --no-ff -m merge pr
    out="$(decide "$d" pull_request)"
    [[ "$out" == true ]] && ok "a rename out of an image path (Dockerfile to docs/): true" \
        || bad "rename out of an image path: out='$out', want true"
}

test_other_events_always_run_smoke() {
    local d e out bads=""
    d="$(pr_repo README.md)"
    for e in push schedule workflow_dispatch; do
        out="$(decide "$d" "$e")"
        [[ "$out" == true ]] || bads+=" $e='$out'"
    done
    [[ -z "$bads" ]] && ok "a push, the nightly and a manual run: true, even when only docs changed" \
        || bad "events that skipped smoke:$bads"
}

test_not_a_merge_commit_runs_smoke() {
    local d out rc
    d="$TMPD/linear"
    git init -q -b main "$d"
    echo base >"$d/README.md"
    git -C "$d" add -A && git -C "$d" commit -qm base
    out="$(decide "$d" pull_request)"; rc=$?
    [[ $rc -eq 0 && "$out" == true ]] && ok "a pull_request HEAD that is no merge commit: true (when in doubt, smoke runs)" \
        || bad "no merge commit: rc=$rc out='$out', want rc=0 out=true"
}

test_outside_a_repo_fails() {
    local out rc
    mkdir -p "$TMPD/norepo"
    out="$(cd "$TMPD/norepo" && GIT_CEILING_DIRECTORIES="$TMPD" "$SCRIPT" pull_request 2>/dev/null)"; rc=$?
    [[ "$out" == true || $rc -ne 0 ]] && [[ "$out" != false ]] \
        && ok "outside a git repo: never false (rc=$rc out='$out')" \
        || bad "outside a git repo: rc=$rc out='$out', a false would skip smoke on a broken checkout"
}

# fake_bin <repo> <git action>: a dir for PATH with a mktemp that hands out <repo>.list and a git
# wrapper that runs the real git, then on a `diff` runs <git action> on that file
fake_bin() {
    local f="$1.list" real
    real="$(command -v git)"
    mkdir -p "$1.bin"
    printf '#!/bin/sh\n: >"%s"; echo "%s"\n' "$f" "$f" >"$1.bin/mktemp"
    printf '#!/bin/sh\n"%s" "$@" || exit $?\ncase "$*" in *diff*) %s "%s" ;; esac\n' \
        "$real" "$2" "$f" >"$1.bin/git"
    chmod +x "$1.bin/mktemp" "$1.bin/git"
    echo "$1.bin"
}

# An image change whose path list cannot be read (the temp file is gone after git diff wrote it)
# must fail the step, never print false: a false skips the smoke on an image change.
test_unreadable_path_list_fails() {
    local d b out rc
    d="$(pr_repo README.md bin/new)"
    b="$(fake_bin "$d" 'rm -f')"
    out="$(cd "$d" && PATH="$b:$PATH" "$SCRIPT" pull_request 2>/dev/null)"; rc=$?
    [[ $rc -ne 0 && "$out" != false ]] \
        && ok "the path list removed before it is read: exit $rc, never false" \
        || bad "path list removed before it is read: rc=$rc out='$out', want nonzero and no false"
}

# The last name in the list with no closing NUL is still read: a list cut short of its NUL must
# not drop the one image path in it.
test_last_name_without_nul_is_read() {
    local d b out rc
    d="$(pr_repo README.md bin/new)"
    b="$(fake_bin "$d" "sh -c 'head -c -1 \"\$0\" >\"\$0.t\" && mv \"\$0.t\" \"\$0\"'")"
    out="$(cd "$d" && PATH="$b:$PATH" "$SCRIPT" pull_request 2>/dev/null)"; rc=$?
    [[ $rc -eq 0 && "$out" == true ]] \
        && ok "an image path last in the list with no closing NUL: true" \
        || bad "image path with no closing NUL: rc=$rc out='$out', want rc=0 out=true"
}

test_no_event_is_a_usage_error() {
    local out rc
    out="$("$SCRIPT" 2>/dev/null)"; rc=$?
    [[ $rc -eq 2 && -z "$out" ]] && ok "no event name: exit 2, nothing on stdout" \
        || bad "no event name: rc=$rc out='$out'"
}

# smoke_job: the smoke job's lines, from "  smoke:" to the next job or the end
smoke_job() { awk '/^  smoke:/{f=1; next} f && /^  [A-Za-z_-]+:/{exit} f' "$CI"; }

test_ci_smoke_job_always_runs() {
    local job
    job="$(smoke_job)"
    [[ -n "$job" ]] || { bad "ci.yml has no smoke job"; return; }
    if grep -Eq '^    (if|needs):' <<<"$job"; then
        bad "the smoke job has a job-level if: or needs:, so it can be skipped: $(grep -E '^    (if|needs):' <<<"$job")"
    else
        ok "the smoke job has no job-level if: or needs: (the required check always reports)"
    fi
    if grep -Eq '^  changes:' "$CI" || grep -q 'paths-filter' "$CI"; then
        bad "ci.yml still has a changes job or the paths-filter action"
    else
        ok "no separate changes job and no paths-filter action"
    fi
    if awk '/^on:/{f=1; next} f && /^[A-Za-z]/{exit} f' "$CI" | grep -Eq '^ +paths(-ignore)?:'; then
        bad "a workflow-level paths filter under on:"
    else
        ok "no workflow-level paths filter"
    fi
}

test_ci_heavy_steps_follow_the_decision() {
    local job steps=() cur="" line i decision=-1 unguarded="" ckout=""
    job="$(smoke_job)"
    while IFS= read -r line; do
        if [[ "$line" =~ ^\ {6}-\  ]]; then
            [[ -n "$cur" ]] && steps+=("$cur")
            cur="$line"$'\n'
        elif [[ -n "$cur" ]]; then
            cur+="$line"$'\n'
        fi
    done <<<"$job"
    [[ -n "$cur" ]] && steps+=("$cur")
    (( ${#steps[@]} >= 3 )) || { bad "smoke job: fewer than 3 steps parsed"; return; }
    ckout="${steps[0]}"
    grep -q 'actions/checkout@' <<<"$ckout" && grep -Eq '^ +fetch-depth: 2$' <<<"$ckout" \
        && ok "the first step checks out with fetch-depth 2 (the merge commit and the base)" \
        || bad "first smoke step is not a depth-2 checkout: $ckout"
    grep -Eq '^ +- id: changes$' <<<"${steps[1]}" && grep -q 'scripts/smoke-needed.sh "\$EVENT"' <<<"${steps[1]}" \
        && grep -Eq 'EVENT: \$\{\{ github.event_name \}\}' <<<"${steps[1]}" \
        && grep -q 'image=\$image' <<<"${steps[1]}" && ! grep -Eq '^ +if:' <<<"${steps[1]}" \
        && decision=1
    (( decision == 1 )) && ok "the second step (id changes, always run) runs scripts/smoke-needed.sh with the event name" \
        || bad "the second smoke step is not the decision: ${steps[1]}"
    for (( i = 2; i < ${#steps[@]}; i++ )); do
        grep -Eq "^ +if: steps\.changes\.outputs\.image == 'true'$" <<<"${steps[$i]}" \
            || unguarded+=" [$(head -1 <<<"${steps[$i]}" | sed 's/^ *//')]"
    done
    [[ -z "$unguarded" ]] && ok "every step after the decision ($(( ${#steps[@]} - 2 )) steps) runs only when it said true" \
        || bad "steps that run on a docs-only PR:$unguarded"
    grep -q 'test/smoke.sh' <<<"${steps[${#steps[@]}-1]}" \
        && ok "the last step still runs test/smoke.sh" || bad "the last smoke step no longer runs test/smoke.sh"
}

test_script_exists
test_docs_only_pr_skips_the_heavy_steps
test_each_image_path_runs_smoke
test_lookalike_paths_do_not_run_smoke
test_quoted_image_paths_run_smoke
test_rename_out_of_an_image_path_runs_smoke
test_other_events_always_run_smoke
test_not_a_merge_commit_runs_smoke
test_outside_a_repo_fails
test_unreadable_path_list_fails
test_last_name_without_nul_is_read
test_no_event_is_a_usage_error
test_ci_smoke_job_always_runs
test_ci_heavy_steps_follow_the_decision

echo
echo "smoke-needed-unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
