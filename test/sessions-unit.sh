#!/usr/bin/env bash
# Unit tests for several Claude sessions in one container (bin/claude-sessions and what it
# touches): NO docker daemon, NO root, NO real claude, NO real tmux. tmux is a fake that
# keeps windows, panes, keystrokes and its global environment in a directory; claude is a
# fake that records its argv; process trees are real (sleep), so the pane-scoped kill is
# tested against the real ps.
#
#   - the spec: names, keys, values, '*', duplicates (claude-sessions check)
#   - boot: CLAUDE_SESSIONS reconciled into the registry, one window per session with the
#     right directory and command, '*' expanded per repo, a named entry beating '*', the
#     goal-chain window, a stopped session left stopped, a dropped entry unregistered, a
#     runtime session kept, a bad entry skipped without failing the boot
#   - claude-session: Remote Control name, directory, model, mode, debug log, the first
#     prompt / goal exactly once, resume by recorded id, --continue only when unambiguous,
#     main unchanged by default and resumable with CLAUDE_MAIN_RESUME=1
#   - supervise: records each window's conversation, one RC watchdog per session with a link
#   - new / stop / start / rm / reset / send / ls --json / health
#   - claude-session-id by window; the RC watchdog kills only its own pane's processes and
#     exits when its window is gone; the usage watchdog resumes every limited session
#   - claude-launch --session / --env, claude-compose-gen --session / --env
#   - the entrypoint and the image wire it all in
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CS="$REPO_ROOT/bin/claude-sessions"
SESSION="$REPO_ROOT/bin/claude-session"
TMPD="$(mktemp -d)"
KILL=()
cleanup() {
    local p
    for p in "$TMPD"/run/*.pid; do [[ -f "$p" ]] && kill "$(cat "$p")" 2>/dev/null; done
    (( ${#KILL[@]} )) && kill "${KILL[@]}" 2>/dev/null
    rm -rf "${TMPD:?}"
}
trap cleanup EXIT

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
check() {  # check <description> <command...>
    local d="$1"; shift
    if "$@"; then ok "$d"; else bad "$d"; fi
}

FAKE="$TMPD/fake"; export FAKE
mkdir -p "$FAKE/bin" "$FAKE/tm/w" "$FAKE/tm/env" "$FAKE/tm/buf"

# --- the fake tmux: session "claude", windows in $FAKE/tm/w/<name>/ --------------------
cat > "$FAKE/bin/tmux" <<'EOF'
#!/usr/bin/env bash
T="$FAKE/tm"
cmd="$1"; shift
target="" name="" dir="" fmt="" buf="" lit=0 args=()
while (( $# )); do
    case "$1" in
        -t) target="$2"; shift 2 ;;
        -n) name="$2"; shift 2 ;;
        -c) dir="$2"; shift 2 ;;
        -F) fmt="$2"; shift 2 ;;
        -b) buf="$2"; shift 2 ;;
        -S) shift 2 ;;
        -l) lit=1; shift ;;
        -d|-p|-g|-k|-r) shift ;;
        *) args+=("$1"); shift ;;
    esac
done
win="${target#*:}"; [[ "$target" == *:* ]] || win=""
case "$cmd" in
    has-session) [[ -e "$T/alive" ]] ;;
    list-windows)
        [[ -e "$T/alive" ]] || exit 1
        while IFS= read -r w; do
            [[ -n "$w" && -d "$T/w/$w" ]] || continue
            l="${fmt//'#{window_name}'/$w}"; l="${l//'#{pane_id}'/$(cat "$T/w/$w/pane")}"
            printf '%s\n' "${l//$'\t'/_}"   # like real tmux: a control character prints as '_'
        done < "$T/order" ;;
    new-window)
        [[ -e "$T/alive" ]] || exit 1
        n=$(( $(cat "$T/next" 2>/dev/null || echo 10) + 1 )); echo "$n" > "$T/next"
        mkdir -p "$T/w/$name"
        echo "%$n" > "$T/w/$name/pane"; printf '%s' "$dir" > "$T/w/$name/dir"; printf '%s' "${args[0]}" > "$T/w/$name/cmd"
        echo "$name" >> "$T/order" ;;
    kill-window)
        rm -rf "${T:?}/w/$win"; grep -vxF "$win" "$T/order" > "$T/order.t"; mv "$T/order.t" "$T/order" ;;
    show-environment)
        [[ -f "$T/env/${args[0]}" ]] || { echo "unknown variable: ${args[0]}" >&2; exit 1; }
        printf '%s=%s\n' "${args[0]}" "$(cat "$T/env/${args[0]}")" ;;
    display-message)
        [[ "${args[0]}" == *pane_pid* && -f "$T/w/$win/pid" ]] || exit 1
        cat "$T/w/$win/pid" ;;
    respawn-pane) printf '%s\n' "${args[0]}" >> "$T/w/$win/respawn" ;;
    send-keys)
        if (( lit )); then printf '%s' "${args[0]}" >> "$T/w/$win/typed"; exit 0; fi
        [[ "${args[0]}" == Enter ]] && { cat "$T/w/$win/typed" 2>/dev/null; echo; echo '<ENTER>'; } >> "$T/w/$win/sent" && : > "$T/w/$win/typed" ;;
    load-buffer) cat > "$T/buf/$buf" ;;
    paste-buffer) cat "$T/buf/$buf" >> "$T/w/$win/typed" ;;
    capture-pane) cat "$T/w/$win/screen" 2>/dev/null ;;
esac
EOF
# A fake RC watchdog: records how it was called; with no args it stays up like the real
# loop (and keeps "rc-watchdog" in its command line, which claude-sessions checks).
cat > "$FAKE/bin/fake-rc-watchdog" <<'EOF'
#!/usr/bin/env bash
echo "${1:-loop} target=$CLAUDE_RC_TMUX_TARGET log=${CLAUDE_RC_DEBUG_LOG:-} cmd=${CLAUDE_RC_RESPAWN_CMD:-} lock=${CLAUDE_RESPAWN_LOCK_DIR:-}" >> "$FAKE/watchdog.calls"
[[ $# -eq 0 ]] && { sleep 300 & wait; }
exit 0
EOF
# A fake claude: records its argv (one per line) and working directory; appends one line per
# call to claude.calls; exits with the next code in $FAKE/codes (0 when there is none).
cat > "$FAKE/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE/claude.args"; pwd > "$FAKE/claude.pwd"
echo "$*" >> "$FAKE/claude.calls"
code=0
if [[ -s "$FAKE/codes" ]]; then code="$(head -n1 "$FAKE/codes")"; sed -i 1d "$FAKE/codes"; fi
exit "$code"
EOF
chmod +x "$FAKE/bin/"*
export PATH="$FAKE/bin:$PATH"

tm_reset() { rm -rf "${FAKE:?}/tm"; mkdir -p "$FAKE/tm/w" "$FAKE/tm/env" "$FAKE/tm/buf"; : > "$FAKE/tm/order"; touch "$FAKE/tm/alive"; }
tm_main() { mkdir -p "$FAKE/tm/w/main"; echo "%0" > "$FAKE/tm/w/main/pane"; echo main >> "$FAKE/tm/order"; }
win_cmd() { cat "$FAKE/tm/w/$1/cmd" 2>/dev/null; }
win_dir() { cat "$FAKE/tm/w/$1/dir" 2>/dev/null; }
windows() { tr '\n' ' ' < "$FAKE/tm/order" | sed 's/ $//'; }

WS="$TMPD/ws"
export CLAUDE_CONFIG_DIR="$TMPD/config" CLAUDE_WORKSPACE="$WS" CLAUDE_PROJECT_NAME=maker \
       CLAUDE_RC_WATCHDOG_BIN="$FAKE/bin/fake-rc-watchdog" CLAUDE_SESSIONS_RUN_DIR="$TMPD/run" \
       CLAUDE_SESSIONS_CGROUP="$TMPD/cg" CLAUDE_RC_DEBUG_LOG="$TMPD/rc/claude-rc-debug.log" \
       CLAUDE_GOAL_CHAIN_BIN=claude-goal-chain CLAUDE_MODEL=opus CLAUDE_SESSIONS_SEND_DELAY=0
unset CLAUDE_SESSIONS CLAUDE_MAIN_RESUME CLAUDE_GOAL_CHAIN_REVIEW CLAUDE_RC_WATCHDOG TMUX
mkdir -p "$CLAUDE_CONFIG_DIR/sessions" "$TMPD/rc" "$TMPD/cg" "$TMPD/home"
REG="$CLAUDE_CONFIG_DIR/session-registry"
for r in home 3d Foo.Bar main; do mkdir -p "$WS/$r/.git"; done
mkdir -p "$WS/notes" "$WS/home/.claude/goals"
echo "home program, GOAL 1 of 3: foundations" > "$WS/home/.claude/goals/g1.goal.txt"

# ======================================================================================
echo "== the spec (claude-sessions check) =="
spec_ok()  { "$CS" check "$1" >/dev/null 2>&1; }
spec_bad() { local out; out="$("$CS" check "$1" 2>&1 >/dev/null)" && return 1; [[ "$out" == *"$2"* ]]; }
check "a full spec is valid" spec_ok 'home goal=.claude/goals/g1.goal.txt chain; 3d; review model=sonnet mode=plan rc=off resume=off'
check "newlines separate entries too, blanks and ';;' are fine" spec_ok $'api\n\n web model=claude-opus-4-8 ;; x model=opus[1m]'
check "'*' with options is valid" spec_ok '* model=sonnet'
check "an uppercase name is refused" spec_bad 'Home' "must be lowercase"
check "a dotted name is refused (tmux reads '.' as a pane)" spec_bad 'a.b' "must be lowercase"
check "main / dev / scm / goal-chain are taken" spec_bad 'dev' "is taken"
check "an unknown key is refused, naming the known ones" spec_bad 'x colour=red' "unknown key 'colour'"
check "a bare word that is not 'chain' is refused" spec_bad 'x fast' "not key=value"
check "rc= takes on/off only" spec_bad 'x rc=maybe' "use on or off"
check "'\$' in a value is refused (compose and tmux would expand it)" spec_bad 'x dir=$HOME' "not allowed"
check "goal= and prompt-file= together are refused" spec_bad 'x goal=a prompt-file=b' "give one"
check "'*' cannot take dir=" spec_bad '* dir=a' "cannot take dir="
check "a name declared twice is refused" spec_bad 'x; y; x' "declared twice"

# ======================================================================================
echo "== boot: CLAUDE_SESSIONS becomes one window per session =="
tm_reset; tm_main
printf '%s' 'maker' > "$FAKE/tm/env/CLAUDE_PROJECT_NAME"
echo 8589934592 > "$TMPD/cg/memory.max"; echo 2048 > "$TMPD/cg/pids.max"
export CLAUDE_SESSIONS='home goal=.claude/goals/g1.goal.txt chain; review dir=home model=sonnet mode=plan rc=off; *; bad name=x'
export CLAUDE_GOAL_CHAIN_REVIEW="it reviews and approves for me"
out="$("$CS" boot 2>&1)"; rc=$?
check "boot exits 0 even with a bad entry" test "$rc" -eq 0
[[ "$out" == *"skipped 'bad name=x'"* ]] && ok "the bad entry is skipped with a log line" || bad "bad entry not reported: $out"
check "windows: main, then declared order, then '*' repos (named entry wins 'home')" \
    test "$(windows)" = "main home review 3d foo-bar goal-chain"
check "home runs in /workspace/home, started with --boot" \
    test "$(win_dir home)|$(win_cmd home)" = "$WS/home|/usr/local/bin/claude-session --session home --boot"
check "review's relative dir=home resolves under /workspace" test "$(win_dir review)" = "$WS/home"
check "'*' names Foo.Bar's session foo-bar and runs it in the real directory" test "$(win_dir foo-bar)" = "$WS/Foo.Bar"
[[ "$out" == *"no session for $WS/main"* ]] && ok "a repo named 'main' gets no session, and the log says how to add one" || bad "repo 'main' not reported: $out"
[[ ! -e "$FAKE/tm/w/notes" ]] && ok "a directory that is not a git repo gets no session" || bad "notes/ got a session"
gc="$(win_cmd goal-chain)"
[[ "$gc" == "claude-goal-chain --review-checkpoints it\\ reviews\\ and\\ approves\\ for\\ me home=$WS/home;"* ]] \
    && ok "goal-chain watches the chained session, with the delegated review quoted" || bad "goal-chain command: $gc"
check "every declared session is registered as source=env" \
    test "$(grep -l '^source=env' "$REG"/*.conf | wc -l)" -eq 4
[[ "$out" == *"Capacity: 5 Claude sessions share 8192 MiB"* && "$out" != *"WARNING: under 1 GiB"* ]] \
    && ok "the capacity line counts main and says what each session gets" || bad "capacity line: $out"
echo 2147483648 > "$TMPD/cg/memory.max"
tm_reset; tm_main
out="$("$CS" boot 2>&1)"
[[ "$out" == *"WARNING: under 1 GiB per session"* ]] && ok "too little memory per session is a warning" || bad "no memory warning: $out"
echo 8589934592 > "$TMPD/cg/memory.max"

echo "== prepare: workspace trust for every session directory, before Claude runs =="
tm_reset; tm_main
echo '{"projects":{"/workspace":{"hasTrustDialogAccepted":true},"'"$WS"'/3d":{"hasTrustDialogAccepted":true,"allowedTools":["x"]}}}' \
    > "$CLAUDE_CONFIG_DIR/.claude.json"
out="$("$CS" prepare 2>&1)"
trust_of() { jq -r --arg d "$1" '.projects[$d].hasTrustDialogAccepted // false' "$CLAUDE_CONFIG_DIR/.claude.json"; }
check "prepare trusts each session's directory" test "$(trust_of "$WS/home")$(trust_of "$WS/Foo.Bar")" = truetrue
check "prepare trusts every repo under /workspace, sessions or not (main/ has none)" test "$(trust_of "$WS/main")" = true
check "an existing project entry keeps its own keys" \
    test "$(jq -c --arg d "$WS/3d" '.projects[$d].allowedTools' "$CLAUDE_CONFIG_DIR/.claude.json")" = '["x"]'
[[ "$out" == *"Workspace trust     : pre-accepted for"* && "$out" != *"$WS/3d "* ]] \
    && ok "prepare says what it trusted, and skips what already was" || bad "prepare output: $out"
check "prepare does not open windows" test "$(windows)" = "main"
mkdir -p "$WS/later"
"$CS" new later --dir later >/dev/null 2>&1
check "a session added at runtime gets its directory trusted too" test "$(trust_of "$WS/later")" = true
"$CS" rm later >/dev/null 2>&1

echo "== boot again: stopped stays stopped, dropped entries go, runtime sessions stay =="
tm_reset; tm_main
echo "stopped=1" > "$REG/3d.state"
mkdir -p "$WS/extra"
"$CS" new scratch --dir extra --no-rc >/dev/null 2>&1
check "new registers a runtime session (source=cli)" grep -qx 'source=cli' "$REG/scratch.conf"
export CLAUDE_SESSIONS='home; *'
tm_reset; tm_main
out="$("$CS" boot 2>&1)"
[[ "$out" == *"review: no longer in CLAUDE_SESSIONS, unregistered"* && ! -f "$REG/review.conf" ]] \
    && ok "a session dropped from CLAUDE_SESSIONS is unregistered" || bad "review not unregistered: $out"
[[ "$out" == *"3d: stopped by hand, not started"* && ! -e "$FAKE/tm/w/3d" ]] \
    && ok "a session stopped by hand stays stopped across a boot" || bad "3d started anyway: $out"
check "the runtime session comes back after a boot" test -e "$FAKE/tm/w/scratch"
check "no chained session now, so no goal-chain window" test ! -e "$FAKE/tm/w/goal-chain"
check "boot with no CLAUDE_SESSIONS and no registry says nothing" \
    test -z "$(env -u CLAUDE_SESSIONS CLAUDE_SESSIONS_REGISTRY="$TMPD/empty-reg" "$CS" boot 2>&1)"

# ======================================================================================
echo "== claude-sessions env: what claude-session sees =="
export CLAUDE_SESSIONS='home goal=.claude/goals/g1.goal.txt; review dir=home model=sonnet mode=plan rc=off resume=off'
tm_reset; tm_main; rm -rf "${REG:?}"; "$CS" boot >/dev/null 2>&1
envof() { ( eval "$("$CS" env "$1")"; eval "echo \"\$$2\"" ); }
check "home: Remote Control name <project>-<name>" test "$(envof home S_RCNAME)" = maker-home
check "home: goal path resolved against its dir" test "$(envof home S_PROMPT_KIND):$(envof home S_PROMPT_PATH)" = "goal:$WS/home/.claude/goals/g1.goal.txt"
check "home: its own debug log beside main's" test "$(envof home S_DEBUG_LOG)" = "$TMPD/rc/claude-rc-debug-home.log"
check "home and review share a directory, so both know it" test "$(envof home S_SHARED)$(envof review S_SHARED)" = 11
check "review: rc=off, resume=off, model and mode carried" test "$(envof review S_RC)/$(envof review S_RESUME)/$(envof review S_MODEL)/$(envof review S_MODE)" = "off/off/sonnet/plan"
check "main: named <project>-main once the container has named sessions, resume off by default" test "$(envof main S_RCNAME)/$(envof main S_RESUME)" = "maker-main/off"
check "main: CLAUDE_MAIN_NAME overrides that name" test "$(CLAUDE_MAIN_NAME=maker-root envof main S_RCNAME)" = maker-root
check "main: plain <project> in a container without named sessions" \
    test "$(CLAUDE_SESSIONS_REGISTRY="$TMPD/empty-reg" envof main S_RCNAME)" = maker
check "main: CLAUDE_MAIN_RESUME=1 turns resume on" test "$(CLAUDE_MAIN_RESUME=1 envof main S_RESUME)" = on
check "env of an unknown session fails" bash -c "! '$CS' env nosuch 2>/dev/null"
unset CLAUDE_RC_DEBUG_LOG
printf '%s' "$TMPD/rc/from-tmux.log" > "$FAKE/tm/env/CLAUDE_RC_DEBUG_LOG"
check "from an SSH login (no env), values come from tmux's global environment" \
    test "$(envof home S_DEBUG_LOG)" = "$TMPD/rc/from-tmux-home.log"
export CLAUDE_RC_DEBUG_LOG="$TMPD/rc/claude-rc-debug.log"

# ======================================================================================
echo "== claude-session: the command line each session runs =="
run_session() {  # run_session <args...>: run claude-session with the fake claude; args in $FAKE/claude.args
    rm -f "$FAKE/claude.args" "$FAKE/claude.pwd"
    HOME="$TMPD/home" CLAUDE_SESSIONS_BIN="$CS" "$SESSION" "$@" </dev/null >"$TMPD/session.out" 2>&1
}
arg_has() { grep -qxF -- "$1" "$FAKE/claude.args"; }
arg_pair() { grep -A1 -xF -- "$1" "$FAKE/claude.args" | sed -n 2p; }
run_session --session home --boot
check "home: runs in its directory" test "$(cat "$FAKE/claude.pwd")" = "$WS/home"
check "home: --remote-control maker-home" test "$(arg_pair --remote-control)" = maker-home
check "home: the display name is the same (--name maker-home), so a resumed conversation is renamed" test "$(arg_pair --name)" = maker-home
check "home: the container's model" test "$(arg_pair --model)" = opus
check "home: its own debug log" test "$(arg_pair --debug-file)" = "$TMPD/rc/claude-rc-debug-home.log"
check "home: first start sends /goal with the file's contents, as the last argument" \
    test "$(tail -n1 "$FAKE/claude.args")" = "/goal home program, GOAL 1 of 3: foundations"
check "home: the start is recorded" grep -qx 'started=1' "$REG/home.state"
run_session --session home --boot
check "home: a second boot with no recorded conversation and a shared dir starts fresh, goal NOT resent" \
    bash -c "! grep -q '^/goal' '$FAKE/claude.args' && ! grep -qx -- --continue '$FAKE/claude.args'"
proj="$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$WS/home" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$proj"; touch "$proj/sid-home-1.jsonl"
"$CS" mark home sid=sid-home-1
run_session --session home --boot
check "home: a boot resumes the recorded conversation (--resume <id>)" test "$(arg_pair --resume)" = sid-home-1
run_session --session home --continue
check "home: --continue resumes the recorded conversation too" test "$(arg_pair --resume)" = sid-home-1
"$CS" mark home sid=gone
run_session --session home --continue
check "home: a recorded id with no transcript and a shared dir: fresh, never a blind --continue" \
    bash -c "! grep -qxE -- '--(continue|resume)' '$FAKE/claude.args'"
run_session --session review --boot
check "review: rc=off still gets its display name" test "$(arg_pair --name)" = maker-review
check "review: rc=off means no --remote-control and no debug log" \
    bash -c "! grep -qxE -- '--(remote-control|debug-file)' '$FAKE/claude.args'"
check "review: mode=plan is --permission-mode plan, model sonnet" \
    test "$(arg_pair --permission-mode)/$(arg_pair --model)" = plan/sonnet
run_session --session review --fresh
check "--fresh never resumes" bash -c "! grep -qxE -- '--(continue|resume)' '$FAKE/claude.args'"
export CLAUDE_SESSIONS='solo dir=notes'
tm_reset; tm_main; "$CS" boot >/dev/null 2>&1
nproj="$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$WS/notes" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$nproj"; touch "$nproj/older.jsonl"
run_session --session solo --continue
check "a session alone in its dir falls back to --continue when nothing is recorded" arg_has --continue
run_session --session nosuch --boot
check "an unknown session never runs claude (drops to a shell)" test ! -e "$FAKE/claude.args"

echo "== claude-session: a crash relaunches, resuming; a deliberate exit does not =="
crash_run() {  # crash_run <codes...> -- <claude-session args...>: number of claude calls
    local codes=()
    while [[ "$1" != -- ]]; do codes+=("$1"); shift; done; shift
    printf '%s\n' "${codes[@]}" > "$FAKE/codes"; rm -f "$FAKE/claude.calls"
    HOME="$TMPD/home" CLAUDE_SESSIONS_BIN="$CS" CLAUDE_SESSION_CRASH_BACKOFF=0 CLAUDE_SESSION_CRASH_RESTARTS=3 \
        "$SESSION" "$@" </dev/null >"$TMPD/crash.out" 2>&1
    wc -l < "$FAKE/claude.calls"
}
"$CS" mark solo sid=older
check "a crash (139) relaunches once, then a clean exit (0) drops to the shell" test "$(crash_run 139 0 -- --session solo --boot)" -eq 2
check "the relaunch resumes the conversation" bash -c "tail -n1 '$FAKE/claude.calls' | grep -q -- '--resume older'"
grep -q "Claude Code crashed (status 139). Restarting in 0s, resuming this conversation (restart 1 of 3" "$TMPD/crash.out" \
    && ok "the pane says it crashed and is restarting" || bad "crash message: $(cat "$TMPD/crash.out")"
check "a deliberate SIGTERM (143, stop or a watchdog respawn) is not relaunched" test "$(crash_run 143 -- --session solo --boot)" -eq 1
check "Ctrl-C (130) is not relaunched" test "$(crash_run 130 -- --session solo --boot)" -eq 1
check "crashes stop being relaunched after CLAUDE_SESSION_CRASH_RESTARTS in the window" test "$(crash_run 134 134 134 134 134 134 -- --session solo --boot)" -eq 4
grep -q "crashed 3 times in 900s: not restarting it automatically again" "$TMPD/crash.out" \
    && ok "and the pane says why it stopped" || bad "give-up message: $(tail -3 "$TMPD/crash.out")"
check "main is relaunched too" test "$(crash_run 1 0 -- --boot)" -eq 2
rm -f "$FAKE/codes"

echo "== the claude launcher waits out an update in progress =="
LP="$TMPD/prefix"; mkdir -p "$LP/lib/node_modules/@anthropic-ai/claude-code/bin"
( sleep 3; mkdir -p "$LP/bin"; printf '#!/bin/sh\necho launched "$@"\n' > "$LP/bin/claude"; chmod +x "$LP/bin/claude" ) &
out="$(CLAUDE_CODE_PREFIX="$LP" "$REPO_ROOT/bin/claude-launcher" --version 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"being updated; waiting"* && "$out" == *"launched --version"* ]] \
    && ok "a missing binary (an update in progress) is waited for, then run" || bad "launcher wait (rc=$rc): $out"
rm -rf "$LP/bin"
out="$(CLAUDE_CODE_PREFIX="$LP" CLAUDE_UPDATE_WAIT=2 "$REPO_ROOT/bin/claude-launcher" 2>&1)"; rc=$?
check "the wait is bounded (CLAUDE_UPDATE_WAIT), then it fails as before" test "$rc" -ne 0

echo "== claude-session: main =="
mkdir -p "$CLAUDE_CONFIG_DIR/projects/x"; touch "$CLAUDE_CONFIG_DIR/projects/x/sid-main.jsonl"
"$CS" mark main sid=sid-main
run_session --boot
check "main: --remote-control and --name <project>-main (named sessions exist), default debug log" \
    test "$(arg_pair --remote-control)|$(arg_pair --name)|$(arg_pair --debug-file)" = "maker-main|maker-main|$TMPD/rc/claude-rc-debug.log"
check "main: a boot is fresh by default (as before named sessions)" bash -c "! grep -qxE -- '--(continue|resume)' '$FAKE/claude.args'"
CLAUDE_MAIN_RESUME=1 run_session --boot
check "main: CLAUDE_MAIN_RESUME=1 resumes its recorded conversation on boot" test "$(arg_pair --resume)" = sid-main
run_session --continue
check "main: the RC watchdog's --continue resumes main's own conversation" test "$(arg_pair --resume)" = sid-main
run_session --resume abc-123
check "main: --resume <id> is passed through" test "$(arg_pair --resume)" = abc-123
CLAUDE_SESSIONS_BIN=/nonexistent run_session --continue
check "main still starts when claude-sessions is missing" test -s "$FAKE/claude.args"

# ======================================================================================
echo "== supervise: conversations recorded, one watchdog per linked session =="
export CLAUDE_SESSIONS='home; review dir=home rc=off'
tm_reset; tm_main; rm -rf "${REG:?}" "${TMPD:?}/run" "${FAKE:?}/watchdog.calls"; "$CS" boot >/dev/null 2>&1
mksess() {  # mksess <pane> <sid>: a live "claude" whose session file maps it to a pane
    bash -c 'exec -a claude-fake sleep 1800' & KILL+=($!)
    jq -n --argjson p "$!" --arg s "$2" --arg t "claude:@1.$1" '{pid:$p,sessionId:$s,status:"idle",tmux:$t,cwd:"/x"}' \
        > "$CLAUDE_CONFIG_DIR/sessions/$!.json"
}
rm -f "$CLAUDE_CONFIG_DIR/sessions/"*.json
mksess "$(cat "$FAKE/tm/w/home/pane")" conv-home
mksess "%0" conv-main
jq -n '{pid:999999,sessionId:"dead",tmux:"claude:@9.%0"}' > "$CLAUDE_CONFIG_DIR/sessions/999999.json"
"$CS" record
check "record notes home's conversation (and starts no watchdog)" \
    bash -c "grep -qx 'sid=conv-home' '$REG/home.state' && [[ ! -e '$FAKE/watchdog.calls' ]]"
"$CS" supervise --once
check "home's conversation is recorded" grep -qx 'sid=conv-home' "$REG/home.state"
check "main's conversation is recorded (a dead process's file is ignored)" grep -qx 'sid=conv-main' "$REG/main.state"
sleep 0.3
check "home (linked) got a watchdog on its window, log, respawn command and lock" \
    grep -qxF "loop target=claude:home log=$TMPD/rc/claude-rc-debug-home.log cmd=/usr/local/bin/claude-session --session home --continue lock=/tmp/claude-respawn-home.lock" "$FAKE/watchdog.calls"
check "review (rc=off) and main (the entrypoint's) got none" test "$(grep -c '^loop' "$FAKE/watchdog.calls")" -eq 1
"$CS" supervise --once; sleep 0.3
check "a second pass does not start a second watchdog" test "$(grep -c '^loop' "$FAKE/watchdog.calls")" -eq 1
CLAUDE_RC_WATCHDOG=0 bash -c "rm -f '$TMPD/run/home.watchdog.pid'; '$CS' supervise --once"; sleep 0.3
check "CLAUDE_RC_WATCHDOG=0 starts none" test "$(grep -c '^loop' "$FAKE/watchdog.calls")" -eq 1

echo "== ls / health =="
json="$("$CS" ls --json)"
check "ls --json lists main and every session" test "$(jq -r '[.[].name] | join(",")' <<<"$json")" = "main,home,review"
check "ls shows a live session's status and conversation" test "$(jq -r '.[] | select(.name=="home") | "\(.state) \(.conversation)"' <<<"$json")" = "idle conv-hom"
check "ls marks a session without Remote Control" test "$(jq -r '.[] | select(.name=="review") | .remote_control' <<<"$json")" = "-"
bash -c 'sleep 1800' & KILL+=($!); echo $! > "$FAKE/tm/w/review/pid"
out="$("$CS" health)"
check "health: a pane whose claude exited is reported" test "$out" = "sessions: 1/2 up (review: claude exited)"
check "ls says 'exited' for it" test "$("$CS" ls --json | jq -r '.[] | select(.name=="review") | .state')" = exited
sj="$(grep -l '"conv-home"' "$CLAUDE_CONFIG_DIR"/sessions/*.json | head -1)"
jq '.status = "shell"' "$sj" > "$sj.t" && mv "$sj.t" "$sj"
check "a session running a background shell (Claude Code's status 'shell') is up, not exited" \
    test "$("$CS" health)" = "sessions: 1/2 up (review: claude exited)"
jq '.status = "idle"' "$sj" > "$sj.t" && mv "$sj.t" "$sj"
printf 'recovery exhausted after 6 attempts\n' > "$TMPD/rc/claude-rc-debug-home.log"
out="$("$CS" health)"
[[ "$out" == *"home: Remote Control dead"* ]] && ok "health: a dead Remote Control link is reported" || bad "health: $out"
: > "$TMPD/rc/claude-rc-debug-home.log"

echo "== capacity: pids and memory near the limits are named =="
echo 8192 > "$TMPD/cg/pids.max"; echo 7000 > "$TMPD/cg/pids.current"
echo 1000 > "$TMPD/cg/memory.current"; echo 8589934592 > "$TMPD/cg/memory.max"
out="$("$CS" health)"
[[ "$out" == *"pids 85% (7000/8192)"* && "$out" != *memory* ]] && ok "health adds 'pids 85%' at 80% and above" || bad "health: $out"
out="$("$CS" supervise --once 2>&1)"
[[ "$out" == *"WARNING: capacity: pids 7000/8192 (85%)"* && "$out" == *"Heaviest: "*" threads, "* ]] \
    && ok "the supervisor warns and names the heaviest processes by threads" || bad "capacity warning: $out"
echo 100 > "$TMPD/cg/pids.current"
check "below the threshold, nothing is added" bash -c "! '$CS' health | grep -q pids"
rm -f "$TMPD/cg/pids.current" "$TMPD/cg/memory.current"; echo 2048 > "$TMPD/cg/pids.max"

echo "== stop / start / restart / reset / rm / send =="
out="$("$CS" stop home 2>&1)"
check "stop ends the pane's claude through the watchdog, then the window" \
    bash -c "grep -q '^--kill-pane target=claude:home' '$FAKE/watchdog.calls' && [[ ! -e '$FAKE/tm/w/home' ]]"
check "stop is remembered" grep -qx 'stopped=1' "$REG/home.state"
"$CS" start home >/dev/null 2>&1
check "start brings it back and clears the stop" bash -c "[[ -e '$FAKE/tm/w/home' ]] && grep -qx 'stopped=0' '$REG/home.state'"
"$CS" restart home --fresh >/dev/null 2>&1
check "restart --fresh respawns through the watchdog with --fresh" \
    grep -q "^--respawn target=claude:home .*cmd=/usr/local/bin/claude-session --session home --fresh" "$FAKE/watchdog.calls"
mkdir -p "$CLAUDE_CONFIG_DIR/projects/-moved"; touch "$CLAUDE_CONFIG_DIR/projects/-moved/imported-1.jsonl"
"$CS" restart home --resume imported-1 >/dev/null 2>&1
check "restart --resume ID respawns with --resume ID" \
    grep -q "^--respawn target=claude:home .*cmd=/usr/local/bin/claude-session --session home --resume imported-1 " "$FAKE/watchdog.calls"
check "restart --resume keeps that id as the session's conversation (no record over it)" grep -qx 'sid=imported-1' "$REG/home.state"
out="$("$CS" restart home --resume nosuch 2>&1)"; rc=$?
check "restart --resume refuses an id with no transcript" bash -c "(( $rc != 0 )) && [[ \"\$1\" == *'no transcript'* ]]" _ "$out"
"$CS" restart main >/dev/null 2>&1
check "restart main respawns main with --continue under main's lock" \
    grep -q "^--respawn target=claude:main .*cmd=/usr/local/bin/claude-session --continue lock=/tmp/claude-respawn.lock" "$FAKE/watchdog.calls"
out="$("$CS" rm home 2>&1)"; rc=$?
check "rm refuses a declared session and says to stop it" bash -c "(( $rc != 0 )) && [[ \"\$1\" == *'claude-sessions stop home'* ]]" _ "$out"
"$CS" new tmp --prompt $'line one\nline two' >/dev/null 2>&1
check "new --prompt keeps the text in a file for the first start" \
    bash -c "grep -qx \"prompt_file=$REG/tmp.prompt\" '$REG/tmp.conf' && [[ \"\$(cat '$REG/tmp.prompt')\" == \$'line one\nline two' ]]"
check "new starts the session now" test -e "$FAKE/tm/w/tmp"
out="$("$CS" new tmp 2>&1)"; rc=$?
check "new refuses an existing name" test "$rc" -ne 0
out="$("$CS" new nodir --dir nowhere 2>&1)"; rc=$?
check "new refuses a missing directory, leaving nothing registered" bash -c "(( $rc != 0 )) && [[ ! -f '$REG/nodir.conf' ]]"
out="$("$CS" new g --dir home --goal missing.txt 2>&1)"; rc=$?
check "new refuses a missing goal file" bash -c "(( $rc != 0 )) && [[ ! -f '$REG/g.conf' ]]"
"$CS" new chained --dir home --chain >/dev/null 2>&1
[[ "$(win_cmd goal-chain)" == *"chained=$WS/home"* ]] && ok "new --chain (re)starts goal-chain with it" || bad "goal-chain: $(win_cmd goal-chain)"
"$CS" rm tmp >/dev/null 2>&1
check "rm removes a runtime session and its window" bash -c "[[ ! -f '$REG/tmp.conf' && ! -f '$REG/tmp.prompt' && ! -e '$FAKE/tm/w/tmp' ]]"
"$CS" reset home >/dev/null 2>&1
check "reset forgets the conversation and the first start" test ! -f "$REG/home.state"
"$CS" send home 'hello there' >/dev/null
check "send types a line and submits it" test "$(cat "$FAKE/tm/w/home/sent")" = $'hello there\n<ENTER>'
: > "$FAKE/tm/w/home/sent"
"$CS" send home $'a\nb' >/dev/null
check "send pastes several lines as one prompt" test "$(cat "$FAKE/tm/w/home/sent")" = $'a\nb\n<ENTER>'

# ======================================================================================
echo "== claude-session-id: by window =="
SID="$REPO_ROOT/bin/claude-session-id"
mksess "$(cat "$FAKE/tm/w/home/pane")" conv-home-2     # home was restarted above: a new pane
check "claude:home -> the conversation in home's current pane" test "$("$SID" claude:home)" = conv-home-2
check "a bare window name works" test "$("$SID" main)" = conv-main
check "a window with no live session is exit 1 (never a sibling's id)" bash -c "! '$SID' claude:review"

# ======================================================================================
echo "== RC watchdog: only its own pane, and only while its window exists =="
WD="$REPO_ROOT/bin/claude-rc-watchdog"
bash -c 'bash -c "exec -a claude-fake sleep 1800" & bash -c "sleep 300" & wait' & root=$!; KILL+=($root)
sleep 300 & other=$!; KILL+=($other)
sleep 0.5
echo "$root" > "$FAKE/tm/w/home/pid"
kids="$(pgrep -P "$root" | tr '\n' ' ')"
( export CLAUDE_RC_TMUX_TARGET=claude:home; source "$WD"; kill_pane_claude )
sleep 0.3
alive=0; for k in $kids; do kill -0 "$k" 2>/dev/null && alive=1; done
check "the pane's processes are gone" test "$alive" -eq 0
check "an unrelated process (another session) is untouched" kill -0 "$other"
( export CLAUDE_RC_TMUX_TARGET=claude:home; source "$WD"; window_alive ) && ok "window_alive: home exists" || bad "window_alive home"
( export CLAUDE_RC_TMUX_TARGET=claude:gone; source "$WD"; ! window_alive ) && ok "window_alive: a stopped session's window does not" || bad "window_alive gone"
check "no pkill of every remote-control process is left" bash -c "! grep -qE '^[^#]*pkill' '$WD'"

echo "== usage watchdog: every limited session is resumed under the new account =="
cat > "$FAKE/bin/fake-names" <<'EOF'
#!/usr/bin/env bash
printf 'main\nhome\nreview\n'
EOF
cat > "$FAKE/bin/fake-sid" <<'EOF'
#!/usr/bin/env bash
echo "sid-${1#*:}"
EOF
chmod +x "$FAKE/bin/fake-names" "$FAKE/bin/fake-sid"
echo "You've hit your session limit · resets 3:45pm" > "$FAKE/tm/w/main/screen"
echo "You've hit your session limit · resets 3:45pm" > "$FAKE/tm/w/home/screen"
echo "all good" > "$FAKE/tm/w/review/screen"
uw="$( export CLAUDE_ACCOUNTS=a,b CLAUDE_RC_WATCHDOG_BIN="$WD" CLAUDE_SESSIONS_BIN="$FAKE/bin/fake-names" \
         CLAUDE_SESSION_ID_BIN="$FAKE/bin/fake-sid" CLAUDE_SESSION_CMD=claude-session
       source "$REPO_ROOT/bin/claude-usage-watchdog"
       echo "limited: $(limited_windows | tr '\n' ' ')"
       with_respawn_lock() { "$@"; }
       _kill_and_respawn_pane() { echo "respawn $WINDOW | $RESPAWN_CMD | $RESPAWN_LOCK_DIR | $LOG"; }
       dismiss_resume_menu() { :; }
       respawn_windows main home )"
[[ "$uw" == *"limited: main home "* ]] && ok "limited_windows finds every session showing the limit" || bad "limited: $uw"
[[ "$uw" == *"respawn claude:main | claude-session --resume sid-main | /tmp/claude-respawn.lock | $TMPD/rc/claude-rc-debug.log"* ]] \
    && ok "main resumes its own conversation" || bad "main respawn: $uw"
[[ "$uw" == *"respawn claude:home | claude-session --session home --resume sid-home | /tmp/claude-respawn-home.lock | $TMPD/rc/claude-rc-debug-home.log"* ]] \
    && ok "home resumes its own conversation, under its own lock" || bad "home respawn: $uw"

# ======================================================================================
echo "== claude-launch --session / --env =="
STUBD="$TMPD/stub"; mkdir -p "$STUBD"
cat > "$STUBD/docker" <<'STUB'
#!/usr/bin/env bash
d="${STUB_STATE:?}"
case "$1" in
    info)    echo ok ;;
    inspect) [[ -e "$d/created" ]] && { echo running; exit 0; }; exit 1 ;;
    image)   [[ "$*" == *Labels* ]] && echo 0; exit 0 ;;
    volume|ps) exit 0 ;;
    run)     shift; printf '%s\n' "$@" > "$d/run-args"; touch "$d/created"; echo deadbeef ;;
    *)       exit 0 ;;
esac
STUB
chmod +x "$STUBD/docker"
mkdir -p "$TMPD/lws"
launch() {
    rm -f "$TMPD/run-args" "$TMPD/created"
    env -u CLAUDE_SESSIONS STUB_STATE="$TMPD" PATH="$STUBD:$PATH" CLAUDE_PORTS_USED_OVERRIDE="" \
        "$REPO_ROOT/bin/claude-launch" stest --workspace "$TMPD/lws" --port 2298 "$@" >"$TMPD/launch.log" 2>&1
}
launch --session 'home goal=g1.txt' --session '3d model=sonnet' --env CLAUDE_MAIN_RESUME=1; rc=$?
args="$(cat "$TMPD/run-args" 2>/dev/null)"
check "--session (repeated) becomes one CLAUDE_SESSIONS" bash -c "(( $rc == 0 )) && grep -qxF 'CLAUDE_SESSIONS=home goal=g1.txt; 3d model=sonnet' <<<\"\$1\"" _ "$args"
check "--env passes the variable" grep -qxF 'CLAUDE_MAIN_RESUME=1' <<<"$args"
grep -q "Sessions: main + home 3d" "$TMPD/launch.log" && ok "the launcher says which sessions start" || bad "launch summary: $(tail -4 "$TMPD/launch.log")"
launch --session 'Bad'; rc=$?
check "an invalid --session fails the launch before docker run" bash -c "(( $rc != 0 )) && [[ ! -e '$TMPD/run-args' ]] && grep -q 'must be lowercase' '$TMPD/launch.log'"
launch --env ANTHROPIC_API_KEY=x; rc=$?
check "--env ANTHROPIC_API_KEY is refused" bash -c "(( $rc != 0 )) && [[ ! -e '$TMPD/run-args' ]]"
launch --env 'not a var'; rc=$?
check "--env needs KEY=VALUE" test "$rc" -ne 0

echo "== claude-compose-gen --session / --env =="
GEN="$REPO_ROOT/bin/claude-compose-gen"
svc_block() { awk -v s="  $2:" 'index($0,s)==1{f=1;next} f && /^  [a-z0-9-]+:$/{exit} f{print}' "$1"; }
gen() { env -u CLAUDE_SESSIONS STUB_STATE="$TMPD" PATH="$STUBD:$PATH" CLAUDE_PORTS_USED_OVERRIDE= "$GEN" "$@" >"$TMPD/gen.log" 2>&1; }
gen --out "$TMPD/c.yml" --group maker=me/home,me/3d --session 'maker=*' --session 'maker=review model=sonnet mode=plan' \
    --env 'maker=CLAUDE_GOAL_CHAIN_REVIEW=it says $HOME "hi"' acme/site; rc=$?
mk="$(svc_block "$TMPD/c.yml" maker)"; st="$(svc_block "$TMPD/c.yml" site)"
check "the group service gets CLAUDE_SESSIONS with both entries" \
    bash -c "(( $rc == 0 )) && grep -qxF '      CLAUDE_SESSIONS: \"*; review model=sonnet mode=plan\"' <<<\"\$1\"" _ "$mk"
check "--env is emitted escaped (\$\$ for compose, \\\" for YAML)" \
    grep -qxF '      CLAUDE_GOAL_CHAIN_REVIEW: "it says $$HOME \"hi\""' <<<"$mk"
check "other services are untouched" bash -c "! grep -qE 'CLAUDE_SESSIONS|GOAL_CHAIN' <<<\"\$1\"" _ "$st"
grep -q '+sessions(\*,review) +env(1)' "$TMPD/gen.log" && ok "the summary names the sessions" || bad "summary: $(grep maker "$TMPD/gen.log")"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    cfg="$(docker compose -f "$TMPD/c.yml" config 2>&1)" \
        && [[ "$cfg" == *'CLAUDE_GOAL_CHAIN_REVIEW: it says $$HOME "hi"'* ]] \
        && ok "docker compose parses it and keeps the value literal" || bad "compose config: $(head -3 <<<"$cfg")"
fi
gen --out "$TMPD/d.yml" acme/site --session 'site=a colour=red'; rc=$?
check "an invalid --session fails the generator and writes nothing" bash -c "(( $rc != 0 )) && [[ ! -e '$TMPD/d.yml' ]] && grep -q \"unknown key 'colour'\" '$TMPD/gen.log'"
gen --out "$TMPD/d.yml" acme/site --session 'nosuch=a'; rc=$?
check "--session for a service not in the stack is refused" bash -c "(( $rc != 0 )) && grep -q 'not a service in this stack' '$TMPD/gen.log'"
gen --out "$TMPD/d.yml" acme/site --env 'site=CLAUDE_MODEL=x'; rc=$?
check "--env of a key the generator sets is refused (no duplicate YAML key)" bash -c "(( $rc != 0 )) && grep -q 'already sets it' '$TMPD/gen.log'"
gen --out "$TMPD/d.yml" acme/site --env 'site=ANTHROPIC_API_KEY=x'; rc=$?
check "--env ANTHROPIC_API_KEY is refused" test "$rc" -ne 0

# ======================================================================================
echo "== the entrypoint follows an account change in the shared credential =="
SYNC="$(awk '/^# >>> credential sync/{f=1} f{print} /^# <<< credential sync/{exit}' "$REPO_ROOT/entrypoint.sh")"
AU="$TMPD/auth"; CF="$TMPD/cfgsync"; mkdir -p "$AU" "$CF"
cred() { printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"r-%s"}}\n' "$1" "$1"; }
acct() { printf '{"oauthAccount":{"accountUuid":"%s","emailAddress":"%s@example.com"}}\n' "$1" "$1"; }
cred tok-new > "$AU/.credentials.json"; acct acct-new > "$AU/.claude.json"
cred tok-old > "$CF/.credentials.json"; acct acct-old > "$CF/.claude.json"
touch -d '1 hour ago' "$CF/.credentials.json"
{
    echo 'set -euo pipefail'
    echo 'log() { echo "[entrypoint] $*"; }'
    echo "AUTH_DIR='$AU' CLAUDE_CONFIG_DIR='$CF' CLAUDE_UID=$(id -u) CLAUDE_GID=$(id -g) CLAUDE_BIN_RE='^/fake/bin/claude\$'"
    printf '%s\n' "$SYNC"
    cat <<'EOS'
cred() { printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"r-%s"}}\n' "$1" "$1"; }
acct() { printf '{"oauthAccount":{"accountUuid":"%s","emailAddress":"%s@example.com"}}\n' "$1" "$1"; }
tok() { sed -E 's/.*"accessToken":"([^"]*)".*/\1/' "$1"; }
CF="$CLAUDE_CONFIG_DIR" AU="$AUTH_DIR"
step() {
    reconcile_once || true
    local sw=none; [[ -s "$CF/.account-changed" ]] && sw="$(cut -d' ' -f2 "$CF/.account-changed")"
    echo "[$1] local=$(tok "$CF/.credentials.json") master=$(tok "$AU/.credentials.json") acct=$(cat "$CF/.credentials-account") cached=$(jq -r .oauthAccount.accountUuid "$CF/.claude.json") switch=$sw"
}
echo "[boot] local=$(tok "$CF/.credentials.json") acct=$(cat "$CF/.credentials-account")"
sleep 1.1; cred tok-new2 > "$CF/.credentials.json"; step refresh-same-account
bash -c 'exec -a /fake/bin/claude sleep 30' & old=$!; sleep 1.2
cred tok-other > "$AU/.credentials.json"; acct acct-other > "$AU/.claude.json"; step account-change
sleep 1.1; cred tok-OLD-refresh > "$CF/.credentials.json"; step old-session-refreshes
kill "$old"; wait "$old" 2>/dev/null || true; step old-sessions-gone
sleep 1.1; cred tok-other2 > "$CF/.credentials.json"; step refresh-after-switch
printf '{"claudeAiOauth":{"accessToken":""}}\n' > "$AU/.credentials.json"; acct acct-third > "$AU/.claude.json"
sleep 1.1; cred tok-mine > "$CF/.credentials.json"; step master-logged-out-other-account
EOS
} > "$TMPD/sync.sh"
out="$(bash "$TMPD/sync.sh" 2>&1)"
grep -q "^\[entrypoint\] Auth account        : this container's own credential was another account's (acct-old" <<<"$out" \
    && grep -q '^\[boot\] local=tok-new acct=acct-new$' <<<"$out" \
    && ok "boot: a container holding another account's credential takes the shared one before any session starts" || bad "boot: $out"
grep -q '^\[refresh-same-account\] local=tok-new2 master=tok-new2 ' <<<"$out" \
    && ok "a token refresh of the same account is still pushed up to the shared credential" || bad "same-account push: $(grep refresh-same <<<"$out")"
grep -q '^\[account-change\] local=tok-other master=tok-other acct=acct-other cached=acct-other switch=acct-other$' <<<"$out" \
    && grep -q "the shared credential is now acct-other@example.com" <<<"$out" \
    && ok "a new account in the shared credential is taken over at once: credential, cached identity, switch request" || bad "account change: $(grep account-change <<<"$out")"
grep -q '^\[old-session-refreshes\] local=tok-other master=tok-other ' <<<"$out" \
    && ok "while an old-account Claude still runs, its refresh is never pushed up (the shared one is put back)" || bad "old refresh: $(grep old-session <<<"$out")"
grep -q "every Claude process now runs on acct-other@example.com" <<<"$out" \
    && grep -q '^\[refresh-after-switch\] local=tok-other2 master=tok-other2 ' <<<"$out" \
    && ok "once every old process is gone, sync is back to normal (refreshes pushed up again)" || bad "after switch: $out"
grep -q '^\[master-logged-out-other-account\] local=tok-mine master= ' <<<"$out" \
    && ok "a logged-out shared credential naming another account is never filled with this one" || bad "logged out: $(grep master-logged <<<"$out")"

cred tok-A > "$AU/.credentials.json"; acct acct-A > "$AU/.claude.json"; touch -d '1 hour ago' "$AU/.credentials.json"
cred tok-B > "$CF/.credentials.json"; acct acct-B > "$CF/.claude.json"; rm -f "${CF:?}/.credentials-account" "${CF:?}/.account-changed"
out="$( { echo 'log() { echo "[entrypoint] $*"; }'; echo "AUTH_DIR='$AU' CLAUDE_CONFIG_DIR='$CF' CLAUDE_UID=$(id -u) CLAUDE_GID=$(id -g) CLAUDE_AUTH_FOLLOW=0"; printf '%s\n' "$SYNC"; echo 'reconcile_once || true'; } | bash 2>&1; echo "master=$(sed -E 's/.*"accessToken":"([^"]*)".*/\1/' "$AU/.credentials.json") switch=$([[ -e "$CF/.account-changed" ]] && echo yes || echo no)")"
[[ "$out" == *"account changes are NOT followed (CLAUDE_AUTH_FOLLOW=0)"* && "$out" == *"master=tok-B switch=no"* ]] \
    && ok "CLAUDE_AUTH_FOLLOW=0 turns it off: the old newest-wins sync, and the boot log says so" || bad "follow off: $out"

echo "== the supervisor moves sessions onto a new account =="
tm_reset; tm_main; rm -rf "${REG:?}" "${TMPD:?}/run" "${FAKE:?}/watchdog.calls"
export CLAUDE_SESSIONS='home; review dir=home'
"$CS" boot >/dev/null 2>&1
rm -f "${CLAUDE_CONFIG_DIR:?}/sessions/"*.json
mksess "$(cat "$FAKE/tm/w/home/pane")" s-home
mksess "$(cat "$FAKE/tm/w/review/pane")" s-review
sj_review="$(grep -l '"s-review"' "$CLAUDE_CONFIG_DIR"/sessions/*.json)"
jq '.status = "busy"' "$sj_review" > "$sj_review.t" && mv "$sj_review.t" "$sj_review"
echo "$(( $(date +%s) + 5 )) acct-new" > "$CLAUDE_CONFIG_DIR/.account-changed"
check "health says sessions are still moving to the new account" bash -c "'$CS' health | grep -q 'moving to a new account (2 sessions to go)'"
"$CS" supervise --once > "$TMPD/sup.out" 2>&1; out="$(cat "$TMPD/sup.out")"   # a file: watchdogs it starts keep a pipe open
[[ "$out" == *"home: restarted onto the new account"* && "$out" != *"review: restarted"* ]] \
    && ok "an idle session is restarted onto the new account; a busy one is left to finish its turn" || bad "switch pass: $out"
check "the restart resumes the session's conversation" grep -q '^--respawn target=claude:home .*--session home --continue' "$FAKE/watchdog.calls"
check "the switch stays open while a session still runs the old account" test -s "$CLAUDE_CONFIG_DIR/.account-changed"
acct acct-new > "$CLAUDE_CONFIG_DIR/.claude.json"; echo acct-new > "$CLAUDE_CONFIG_DIR/.credentials-account"
out="$("$CS" account)"
[[ "$out" == *"account: acct-new@example.com (acct-new)"* && "$out" == *"in progress since"*"still on the previous account: home review"* ]] \
    && ok "claude-sessions account names the account and who is still on the previous one" || bad "account: $out"
echo "You've hit your weekly limit · resets Mon 12:00am" > "$FAKE/tm/w/home/screen"; : > "$FAKE/tm/w/home/sent"
CLAUDE_SESSIONS_SWITCH_NUDGE_TRIES=1 "$CS" supervise --once > "$TMPD/sup.out" 2>&1
grep -q "home: a usage limit had stopped it; told to continue on the new account" "$TMPD/sup.out" \
    && grep -q "^\[account-switch\] This container now uses a different Claude account" "$FAKE/tm/w/home/sent" \
    && ok "a session a usage limit had stopped is told to continue after it moves" || bad "nudge: $(cat "$TMPD/sup.out")"
: > "$FAKE/tm/w/home/screen"
n0="$(grep -c '^--respawn target=claude:review ' "$FAKE/watchdog.calls" || true)"
"$CS" account --now > "$TMPD/acct.out" 2>&1
check "account --now moves a busy session too" test "$(grep -c '^--respawn target=claude:review ' "$FAKE/watchdog.calls")" -gt "$n0"
n0="$(grep -c '^--respawn target=claude:review ' "$FAKE/watchdog.calls")"
CLAUDE_SESSIONS_SWITCH_FORCE_AFTER=1 "$CS" supervise --once > "$TMPD/sup.out" 2>&1
check "CLAUDE_SESSIONS_SWITCH_FORCE_AFTER stays quiet until the deadline (the switch is 5 s in the future here)" \
    test "$(grep -c '^--respawn target=claude:review ' "$FAKE/watchdog.calls")" -eq "$n0"
for f in "$CLAUDE_CONFIG_DIR"/sessions/*.json; do jq ".startedAt = $(( ($(date +%s) + 60) * 1000 ))" "$f" > "$f.t" && mv "$f.t" "$f"; done
"$CS" supervise --once > "$TMPD/sup.out" 2>&1; out="$(cat "$TMPD/sup.out")"   # a file: watchdogs it starts keep a pipe open
[[ "$out" == *"every session now runs on the new account"* && ! -e "$CLAUDE_CONFIG_DIR/.account-changed" ]] \
    && ok "when every session started after the switch, it is closed" || bad "switch close: $out"
check "account then reports no switch in progress" bash -c "'$CS' account | grep -q 'switch : none in progress'"

echo "== a stale session file never hands a window another conversation =="
f="$(grep -l '"s-home"' "$CLAUDE_CONFIG_DIR"/sessions/*.json)"; pid="$(jq -r .pid "$f")"
jq '.procStart = "1"' "$f" > "$f.t" && mv "$f.t" "$f"
rm -f "${REG:?}/home.state"; "$CS" record
check "a file whose procStart is not its pid's start time is ignored" bash -c "! grep -q 's-home' '$REG/home.state' 2>/dev/null"
jq --arg ps "$(sed -E 's/^[0-9]+ \(.*\) //' "/proc/$pid/stat" | awk '{print $20}')" '.procStart = $ps' "$f" > "$f.t" && mv "$f.t" "$f"
"$CS" record
check "the same file with the right procStart is used" grep -qx 'sid=s-home' "$REG/home.state"

echo "== the entrypoint caps library thread pools =="
TB="$(awk '/^# --- 12-threads\. Library thread pools/{f=1} f{print} f&&/^unset _tpp$/{exit}' "$REPO_ROOT/entrypoint.sh")"
tp() {  # tp <env...>: run the extracted block, print the resulting values and the profile file
    env -i PATH="$PATH" "$@" bash -c "log() { echo \"[entrypoint] \$*\"; }
        $(printf '%s\n' "$TB" | sed "s#^THREADS_PROFILE_D=.*#THREADS_PROFILE_D=$TMPD/threads.sh#")
        echo \"vals=\${OMP_NUM_THREADS:-unset},\${OPENBLAS_NUM_THREADS:-unset},\${MKL_NUM_THREADS:-unset},\${NUMEXPR_NUM_THREADS:-unset}\"
        cat $TMPD/threads.sh 2>/dev/null"
}
out="$(tp)"
[[ -n "$TB" && "$out" == *"vals=4,4,4,4"* && "$out" == *'export OMP_NUM_THREADS="${OMP_NUM_THREADS:-4}"'* ]] \
    && ok "unset: every pool is capped at 4, and SSH login shells get the same" || bad "thread caps: $out"
out="$(tp OPENBLAS_NUM_THREADS=16 CLAUDE_THREADS_PER_PROCESS=2)"
[[ "$out" == *"vals=2,16,2,2"* ]] && ok "an operator's own value is kept; CLAUDE_THREADS_PER_PROCESS sets the rest" || bad "preset: $out"
out="$(tp CLAUDE_THREADS_PER_PROCESS=0)"
[[ "$out" == *"vals=unset,unset,unset,unset"* && "$out" == *"NOT capped"* ]] && ok "CLAUDE_THREADS_PER_PROCESS=0 leaves them alone, and says so" || bad "disabled: $out"

echo "== the entrypoint and the image wire it in =="
EP="$REPO_ROOT/entrypoint.sh"
main_line="$(grep -n 'tmux new-session -d -s claude' "$EP" | head -1 | cut -d: -f1)"
boot_line="$(grep -n '/usr/local/bin/claude-sessions boot' "$EP" | head -1 | cut -d: -f1)"
sup_line="$(grep -n '/usr/local/bin/claude-sessions supervise &' "$EP" | head -1 | cut -d: -f1)"
alive_line="$(grep -n '^# --- 13\. Stay alive' "$EP" | cut -d: -f1)"
check "named sessions boot after main's window and before the liveness loop" \
    bash -c "(( ${main_line:-0} > 0 && ${boot_line:-0} > ${main_line:-0} && ${sup_line:-0} > ${boot_line:-0} && ${alive_line:-0} > ${sup_line:-0} ))"
prep_line="$(grep -n '/usr/local/bin/claude-sessions prepare' "$EP" | head -1 | cut -d: -f1)"
check "prepare (trust + registry) runs before main's window, so nothing races on .claude.json" \
    bash -c "(( ${prep_line:-0} > 0 && ${prep_line:-0} < ${main_line:-0} ))"
check "a failed prepare or boot never fails the container" \
    bash -c "grep -q 'claude-sessions prepare \\\\$' '$EP' && grep -q 'claude-sessions boot --no-reconcile \\\\$' '$EP'"
check "main starts with --boot" grep -qF 'MAIN_PANE_CMD="/usr/local/bin/claude-session --boot"' "$EP"
check "CLAUDE_SESSIONS / CLAUDE_MAIN_RESUME / CLAUDE_GOAL_CHAIN_REVIEW reach tmux's environment" \
    bash -c "grep -q 'export CLAUDE_SESSIONS=' '$EP' && grep -q 'CLAUDE_MAIN_RESUME=' '$EP' && grep -q 'CLAUDE_GOAL_CHAIN_REVIEW=' '$EP'"
check "the supervisor is stopped on shutdown" grep -q 'kill "$SESSIONS_PID"' "$EP"
check "shutdown records every window's conversation before tmux goes" \
    bash -c "awk '/^shutdown\\(\\) \\{/{f=1} f&&/claude-sessions record/{r=NR} f&&/tmux kill-server/{k=NR; exit} END{exit !(r && k && r < k)}' '$EP'"
check "the image bakes claude-sessions" grep -qx 'COPY bin/claude-sessions /usr/local/bin/claude-sessions' "$REPO_ROOT/Dockerfile"

echo
echo "sessions-unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
