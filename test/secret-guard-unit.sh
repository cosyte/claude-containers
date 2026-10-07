#!/usr/bin/env bash
# Unit tests for bin/claude-secret-guard: NO docker, NO root.
#
# What this covers, with the guard installed the way the entrypoint does it (a global
# core.hooksPath dir whose pre-commit is a symlink to the guard):
#   1. a staged secret is still blocked
#   2. the guard chains to the repo's own .git/hooks/pre-commit in a plain checkout
#   3. ... and from a git worktree, where .git is a file (the hook lives in the main repo)
#   4. the chained hook's failure blocks the commit
#   5. a repo with no hook of its own commits (exit 0)
#   6. a repo hook that IS the guard (symlink) does not loop
set -uo pipefail
# Run from inside a git hook, these would point every git call at the outer repo.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# Isolated global git config: the guard is the global pre-commit, as in the container.
mkdir -p "$TMPD/hooks"
ln -s "$REPO_ROOT/bin/claude-secret-guard" "$TMPD/hooks/pre-commit"
export GIT_CONFIG_GLOBAL="$TMPD/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global core.hooksPath "$TMPD/hooks"
git config --global user.email t@t
git config --global user.name t
git config --global init.defaultBranch main

# commit_in <dir> <file>: stage a new file and commit; prints output, returns git's rc.
commit_in() {
    ( cd "$1" && echo x > "$2" && git add -f "$2" && git commit -q -m "$2" 2>&1 )
}

git init -q "$TMPD/plain"
git -C "$TMPD/plain" commit -q --allow-empty -m init
cat > "$TMPD/plain/.git/hooks/pre-commit" <<HOOK
#!/usr/bin/env bash
echo ran >> "$TMPD/hook.log"
[[ ! -e "$TMPD/hook.fail" ]]
HOOK
chmod +x "$TMPD/plain/.git/hooks/pre-commit"
git -C "$TMPD/plain" worktree add -q "$TMPD/wt"

echo "== the guard itself =="
if ! out="$(commit_in "$TMPD/plain" .env)" && grep -q claude-secret-guard <<<"$out"; then
    ok  "a staged .env is blocked"
else
    bad "a staged .env must be blocked by the guard"
fi
git -C "$TMPD/plain" restore --staged .env; rm -f "$TMPD/plain/.env"

echo
echo "== chaining to the repo's own pre-commit hook =="
rm -f "$TMPD/hook.log"
if out="$(commit_in "$TMPD/plain" a.txt)" && [[ "$(cat "$TMPD/hook.log" 2>/dev/null)" == ran ]]; then
    ok  "a plain checkout runs .git/hooks/pre-commit"
else
    bad "a plain checkout must run .git/hooks/pre-commit (out='$out')"
fi

rm -f "$TMPD/hook.log"
if [[ -f "$TMPD/wt/.git" ]] && out="$(commit_in "$TMPD/wt" b.txt)" \
        && [[ "$(cat "$TMPD/hook.log" 2>/dev/null)" == ran ]]; then
    ok  "a git worktree runs the main repo's hooks/pre-commit"
else
    bad "a git worktree must run the main repo's hooks/pre-commit (out='$out')"
fi

touch "$TMPD/hook.fail"
if commit_in "$TMPD/wt" c.txt >/dev/null; then
    bad "a failing repo hook must block the commit from a worktree"
else
    ok  "a failing repo hook blocks the commit from a worktree"
fi
rm -f "$TMPD/hook.fail"

echo
echo "== a repo with no hook of its own =="
git init -q "$TMPD/nohook"
rm -f "$TMPD/nohook/.git/hooks/pre-commit"
if out="$(commit_in "$TMPD/nohook" d.txt)"; then
    ok  "commits (exit 0) with no repo hook"
else
    bad "a repo with no hook must commit (out='$out')"
fi
if ( cd "$TMPD/nohook" && "$REPO_ROOT/bin/claude-secret-guard" ); then
    ok  "the guard exits 0 when run directly with nothing staged and no repo hook"
else
    bad "the guard must exit 0 with nothing staged and no repo hook"
fi

ln -s "$REPO_ROOT/bin/claude-secret-guard" "$TMPD/nohook/.git/hooks/pre-commit"
if out="$( cd "$TMPD/nohook" && echo x > e.txt && git add e.txt && timeout 10 git commit -q -m e 2>&1 )"; then
    ok  "a repo hook that is the guard itself runs once, no loop"
else
    bad "a repo hook symlinked to the guard must not loop (out='$out')"
fi

echo
echo "secret-guard-unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
