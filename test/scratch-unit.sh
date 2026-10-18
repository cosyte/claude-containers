#!/usr/bin/env bash
# Unit tests for bin/claude-scratch-reap: NO docker, NO root. A temp dir stands in for /scratch
# and another for /proc (fake environ files, cwd and fd symlinks).
#   - a gone session's folder is removed (CLAUDE_SCRATCH_REAP=on)
#   - kept: a session id found only in a fake environ, a folder held by a fake fd or cwd, one
#     modified within 6 hours, the caller's own
#   - report (the default) and --dry-run remove nothing and log; off does nothing
#   - report names each gone folder once (no second du), forgets one that changed or came back,
#     and --dry-run lists every one without touching that record
#   - the warning above CLAUDE_SCRATCH_WARN_PCT names the largest folders
#   - claude-sessions' supervise loop runs it, and the image ships it
# shellcheck source=test/lib/prelude.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/prelude.sh"
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAP="$REPO_ROOT/bin/claude-scratch-reap"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

S="$TMPD/scratch" P="$TMPD/proc" C="$TMPD/config" STATE="$TMPD/reported"
# A du that counts its calls, so a test can tell a repeat walk from none.
mkdir -p "$TMPD/bin"
printf '#!/usr/bin/env bash\necho x >> "%s"\nexec /usr/bin/du "$@"\n' "$TMPD/du.calls" > "$TMPD/bin/du"
chmod +x "$TMPD/bin/du"
GONE=11111111-1111-4111-8111-111111111111
ENVIRON=22222222-2222-4222-8222-222222222222
FD=33333333-3333-4333-8333-333333333333
CWD=44444444-4444-4444-8444-444444444444
FRESH=55555555-5555-4555-8555-555555555555
OWN=66666666-6666-4666-8666-666666666666
IDLE=77777777-7777-4777-8777-777777777777
CMDLINE=88888888-8888-4888-8888-888888888888
DEADJSON=99999999-9999-4999-8999-999999999999
DEEP=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa

# setup: one folder per case under /scratch/claude-1000/-workspace-x/, all old but FRESH, and a
# fake /proc with a process holding each kept one.
setup() {
    rm -rf "$S" "$P" "$C" "$TMPD/outside" "$STATE"
    local id d
    for id in $GONE $ENVIRON $FD $CWD $FRESH $OWN $IDLE $CMDLINE $DEADJSON $DEEP; do
        d="$S/claude-1000/-workspace-x/$id"
        mkdir -p "$d/sub"; head -c 4096 /dev/zero > "$d/sub/blob"
        [[ "$id" == "$FRESH" ]] || touch -d '7 hours ago' "$d/sub/blob" "$d/sub" "$d"
    done
    mkdir -p "$S/claude-1000/-workspace-x/not-a-session" "$P/100/fd" "$P/200/fd" "$P/300/fd"
    touch -d '7 hours ago' "$S/claude-1000/-workspace-x/not-a-session"
    printf 'HOME=/home/claude\0CLAUDE_CODE_SESSION_ID=%s\0' "$ENVIRON" > "$P/100/environ"
    ln -s "$S/claude-1000/-workspace-x/$FD/sub/blob" "$P/200/fd/3"
    ln -s / "$P/200/cwd"; : > "$P/200/environ"
    ln -s "$S/claude-1000/-workspace-x/$CWD/sub" "$P/300/cwd"; : > "$P/300/environ"
    # An idle session: its id is only in Claude Code's sessions/<pid>.json, and that pid lives.
    mkdir -p "$C/sessions" "$P/400" "$P/500"
    printf '{"pid":400,"sessionId":"%s"}' "$IDLE" > "$C/sessions/400.json"
    printf '{"pid":401,"sessionId":"%s"}' "$DEADJSON" > "$C/sessions/401.json"
    printf 'claude\0--resume\0%s\0' "$CMDLINE" > "$P/500/cmdline"
    # Fresh deep inside an old folder.
    mkdir -p "$S/claude-1000/-workspace-x/$DEEP/a/b"; : > "$S/claude-1000/-workspace-x/$DEEP/a/b/new"
    touch -d '7 hours ago' "$S/claude-1000/-workspace-x/$DEEP/a/b" "$S/claude-1000/-workspace-x/$DEEP/a" "$S/claude-1000/-workspace-x/$DEEP"
    # A project folder that is a symlink out of /scratch, to an old gone-looking session.
    mkdir -p "$TMPD/outside/$GONE"; touch -d '7 hours ago' "$TMPD/outside/$GONE" "$TMPD/outside"
    ln -s "$TMPD/outside" "$S/claude-1000/-workspace-link"
}
run() { CLAUDE_CONFIG_DIR="$C" CLAUDE_SCRATCH_ROOT="$S" CLAUDE_SCRATCH_PROC="$P" CLAUDE_CODE_SESSION_ID="$OWN" \
    CLAUDE_SCRATCH_REAP_STATE="$STATE" PATH="$TMPD/bin:$PATH" "$REAP" "$@"; }
du_calls() { local n; n="$(wc -l < "$TMPD/du.calls" 2>/dev/null)"; echo "${n:-0}"; }
has() { [[ -d "$S/claude-1000/-workspace-x/$1" ]]; }

echo "== on: removes only the gone session's folder =="
setup
out="$(CLAUDE_SCRATCH_REAP=on CLAUDE_SCRATCH_USE_PCT_OVERRIDE=10 run)"
check "the gone session's folder is removed" bash -c "! test -d '$S/claude-1000/-workspace-x/$GONE'"
check "the removal is logged" grep -q "removed .*$GONE" <<<"$out"
check "a session id found only in an environ is kept" has "$ENVIRON"
check "a folder holding a process's open file is kept" has "$FD"
check "a folder holding a process's cwd is kept" has "$CWD"
check "a folder modified within 6 hours is kept" has "$FRESH"
check "the caller's own folder is kept" has "$OWN"
check "a folder not named like a session id is kept" has not-a-session
check "an idle session (id only in a live process's sessions/<pid>.json) is kept" has "$IDLE"
check "a session whose sessions/<pid>.json pid is gone is removed" bash -c "! test -d '$S/claude-1000/-workspace-x/$DEADJSON'"
check "a session id in a process's command line is kept" has "$CMDLINE"
check "an old folder with one fresh file deep inside is kept" has "$DEEP"
check "a folder reached through a symlinked project folder is kept" test -d "$TMPD/outside/$GONE"
check "no warning under the threshold" bash -c "! grep -q WARNING <<<'$out'"

echo "== report (the default) and --dry-run remove nothing and log =="
setup
out="$(CLAUDE_SCRATCH_USE_PCT_OVERRIDE=10 run)"
check "report keeps the gone session's folder" has "$GONE"
check "report logs what it would remove" grep -q "would remove .*$GONE" <<<"$out"
check "report names only the gone sessions" test "$(grep -c 'would remove' <<<"$out")" -eq 2
check "report says how to switch it on" grep -q 'CLAUDE_SCRATCH_REAP=on' <<<"$out"
out="$(CLAUDE_SCRATCH_REAP=on CLAUDE_SCRATCH_USE_PCT_OVERRIDE=10 run --dry-run)"
check "--dry-run keeps the folder even with the mode on" has "$GONE"
check "--dry-run logs" grep -q "would remove .*$GONE" <<<"$out"
out="$(CLAUDE_SCRATCH_REAP=bogus CLAUDE_SCRATCH_USE_PCT_OVERRIDE=10 run)"
check "an unknown mode reports only, and says so" bash -c "test -d '$S/claude-1000/-workspace-x/$GONE' && grep -q 'reporting only' <<<'$out'"

echo "== report names each gone folder once =="
setup; rm -f "$TMPD/du.calls"
out1="$(CLAUDE_SCRATCH_USE_PCT_OVERRIDE=10 run)"; du1="$(du_calls)"
out2="$(CLAUDE_SCRATCH_USE_PCT_OVERRIDE=10 run)"; du2="$(du_calls)"
check "the first pass names the gone folders" test "$(grep -c 'would remove' <<<"$out1")" -eq 2
check "the second pass names none again, and prints no summary" \
    bash -c "! grep -qE 'would remove|report only' <<<'$out2'"
check "the second pass runs no du on them" test "$du2" -eq "$du1"
check "what was named is recorded" grep -qF "$S/claude-1000/-workspace-x/$GONE"$'\t' "$STATE"
G="$S/claude-1000/-workspace-x/$GONE"
touch -d '8 hours ago' "$G"   # its own times change (ctime now), and it is still old
out="$(CLAUDE_SCRATCH_USE_PCT_OVERRIDE=10 run)"
check "a folder whose own times changed is named again" grep -q "would remove .*$GONE" <<<"$out"
check "the summary counts the ones already reported" grep -q 'report only: 1 gone .*plus 1 already reported' <<<"$out"
printf 'CLAUDE_CODE_SESSION_ID=%s\0' "$GONE" > "$P/100/environ"   # the session came back
CLAUDE_SCRATCH_USE_PCT_OVERRIDE=10 run >/dev/null
check "a folder whose session came back is forgotten" bash -c "! grep -qF '$G' '$STATE'"
: > "$P/100/environ"
out="$(CLAUDE_SCRATCH_USE_PCT_OVERRIDE=10 run)"
check "gone again later, it is named again" grep -q "would remove .*$GONE" <<<"$out"
rm -rf "$G"
CLAUDE_SCRATCH_USE_PCT_OVERRIDE=10 run >/dev/null
check "a folder no longer in /scratch is forgotten" bash -c "! grep -qF '$G' '$STATE'"
before="$(cat "$STATE")"
out="$(CLAUDE_SCRATCH_USE_PCT_OVERRIDE=10 run --dry-run)"
check "--dry-run lists every gone folder, already reported or not" grep -q "would remove .*$DEADJSON" <<<"$out"
check "--dry-run leaves the record alone" test "$(cat "$STATE")" = "$before"

echo "== off disables it =="
setup
out="$(CLAUDE_SCRATCH_REAP=off CLAUDE_SCRATCH_USE_PCT_OVERRIDE=99 run)"
check "off removes nothing" has "$GONE"
check "off logs nothing, not even the warning" test -z "$out"

echo "== the warning near full =="
setup
mkdir -p "$S/big"; head -c 3000000 /dev/zero > "$S/big/f"
out="$(CLAUDE_SCRATCH_USE_PCT_OVERRIDE=90 run)"
check "warns above the default 85%" grep -q 'WARNING: .* is 90% full (over 85%)' <<<"$out"
check "the warning names the largest top-level folder first" grep -q "Largest: $S/big (" <<<"$out"
out="$(CLAUDE_SCRATCH_WARN_PCT=95 CLAUDE_SCRATCH_USE_PCT_OVERRIDE=90 run)"
check "CLAUDE_SCRATCH_WARN_PCT raises the threshold" bash -c "! grep -q 'WARNING' <<<'$out'"

echo "== wired in =="
check "supervise runs the reaper" grep -q 'scratch_reap$' <(grep -A8 '^cmd_supervise()' "$REPO_ROOT/bin/claude-sessions")
check "supervise reaps every CLAUDE_SCRATCH_REAP_MIN minutes, default 15" grep -q 'CLAUDE_SCRATCH_REAP_MIN:-15' "$REPO_ROOT/bin/claude-sessions"
check "the image ships it" grep -q 'COPY bin/claude-scratch-reap /usr/local/bin/claude-scratch-reap' "$REPO_ROOT/Dockerfile"
check "a bad flag refuses" bash -c "! '$REAP' --bogus 2>/dev/null"

echo
echo "scratch-unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
