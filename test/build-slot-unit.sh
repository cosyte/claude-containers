#!/usr/bin/env bash
# Unit tests for bin/claude-build-slot: NO docker, NO root. Real flock on a temp slot dir.
#   - with slots=2, a third concurrent call waits until one ends, then runs, and says so once
#   - waiters start in arrival order
#   - a killed holder (the wrapper SIGKILLed) frees its slot; a TERMed wrapper ends its command
#   - a nested call runs at once (CLAUDE_BUILD_SLOT_HELD), no deadlock
#   - slots=0 never waits; exit codes pass through; a daemon the build leaves does not keep it
#   - status lists holders and waiters; bad settings and /cache refuse
#   - the image ships it, the docs name its variables
# shellcheck source=test/lib/prelude.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/prelude.sh"
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BS="$REPO_ROOT/bin/claude-build-slot"
TMPD="$(mktemp -d)"
PIDS=()
trap 'kill "${PIDS[@]}" 2>/dev/null; rm -rf "$TMPD"' EXIT

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

export CLAUDE_BUILD_SLOT_DIR="$TMPD/slots" CLAUDE_BUILD_SLOT_POLL=0.1 CLAUDE_BUILD_SLOTS=2
unset CLAUDE_BUILD_SLOT_HELD

# until <seconds> <cmd...>: poll until cmd succeeds
until_() { local t=$1 i; shift; for (( i = 0; i < t * 20; i++ )); do "$@" && return 0; sleep 0.05; done; return 1; }
# gate <name>: a build that marks it started, then runs until its release file appears
gate() { echo "touch $TMPD/$1.started; while [ ! -e $TMPD/$1.go ]; do sleep 0.05; done; echo $1 >>$TMPD/order"; }

# --- exit codes, the env, no wait line when free -------------------------------------------
out="$("$BS" -- bash -c 'exit 7' 2>&1)"; rc=$?
[[ $rc -eq 7 && -z "$out" ]] && ok "exit code passes through, silent when a slot was free" || bad "rc=$rc out=$out"
out="$("$BS" -- bash -c 'echo "held=$CLAUDE_BUILD_SLOT_HELD"')"
[[ "$out" == held=0 ]] && ok "the command sees CLAUDE_BUILD_SLOT_HELD (its slot)" || bad "env: $out"
out="$(echo piped | "$BS" -- cat)"
[[ "$out" == piped ]] && ok "stdin reaches the command" || bad "stdin: $out"
"$BS" -- bash -c 'kill -TERM $$'; rc=$?
[[ $rc -eq 143 ]] && ok "a command ended by a signal exits 128+N" || bad "signal rc=$rc"

# --- two hold, a third waits, then runs ------------------------------------------------------
"$BS" --name alpha -- bash -c "$(gate a)" & PIDS+=($!); pa=$!
"$BS" --name beta  -- bash -c "$(gate b)" & PIDS+=($!); pb=$!
until_ 5 test -e "$TMPD/a.started" -a -e "$TMPD/b.started" || bad "two holders never started"
"$BS" --name gamma -- bash -c "$(gate c)" 2>"$TMPD/c.err" & PIDS+=($!); pc=$!
until_ 5 test -e "$CLAUDE_BUILD_SLOT_DIR/wait.$pc"
sleep 0.5
[[ ! -e "$TMPD/c.started" ]] && ok "a third call waits while two hold the slots" || bad "the third ran at once"

st="$("$BS" status)"
grep -Eq '^  slot [01]  pid [0-9]+  since .*alpha$' <<<"$st" && grep -q 'beta$' <<<"$st" \
    && grep -Eq "^  pid $pc  since .*gamma$" <<<"$st" \
    && ok "status lists the holders and the waiter" || bad "status: $st"

# a fourth arrives later; it must not jump the queue
"$BS" --name delta -- bash -c "$(gate d)" 2>/dev/null & PIDS+=($!); pd=$!
until_ 5 test -e "$CLAUDE_BUILD_SLOT_DIR/wait.$pd"
touch "$TMPD/a.go"; wait "$pa"
until_ 5 test -e "$TMPD/c.started" && ok "the third runs once a holder ends" || bad "the third never ran"
sleep 0.4
[[ ! -e "$TMPD/d.started" ]] && ok "the later waiter stays behind (arrival order)" || bad "the fourth jumped the queue"
grep -Eq '^build slot: waited [0-9]+s behind (alpha, beta|beta, alpha)$' "$TMPD/c.err" \
    && ok "the waiter prints one line naming what it waited behind" || bad "wait line: $(cat "$TMPD/c.err")"

# --- a SIGKILLed holder frees its slot -------------------------------------------------------
kill -KILL "$pb"; wait "$pb" 2>/dev/null
until_ 5 test -e "$TMPD/d.started" && ok "a killed holder frees its slot" || bad "the slot stayed taken after SIGKILL"
touch "$TMPD/b.go" "$TMPD/c.go" "$TMPD/d.go"; wait "$pc" "$pd"

# --- TERM to the wrapper ends the command and frees the slot ---------------------------------
"$BS" -- bash -c "echo \$\$ >$TMPD/e.pid; $(gate e)" & PIDS+=($!); pe=$!
until_ 5 test -s "$TMPD/e.pid"; epid="$(cat "$TMPD/e.pid")"
kill -TERM "$pe"; wait "$pe"; rc=$?
until_ 5 bash -c "! kill -0 $epid 2>/dev/null" && ok "TERM to the wrapper ends its command (rc=$rc)" || bad "the command outlived the wrapper"
[[ ! -e "$CLAUDE_BUILD_SLOT_DIR/slot.0.info" && ! -e "$CLAUDE_BUILD_SLOT_DIR/slot.1.info" ]] \
    && ok "an ended holder leaves no label behind" || bad "stale info: $(ls "$CLAUDE_BUILD_SLOT_DIR")"

# --- a daemon the build leaves behind does not keep the slot ---------------------------------
CLAUDE_BUILD_SLOTS=1 "$BS" -- bash -c "sleep 30 >/dev/null 2>&1 </dev/null & echo \$! >$TMPD/daemon.pid"
PIDS+=("$(cat "$TMPD/daemon.pid")")
out="$(CLAUDE_BUILD_SLOTS=1 timeout 3 "$BS" -- echo free 2>&1)"
[[ "$out" == free ]] && ok "a leftover daemon does not hold the slot" || bad "daemon kept the slot: $out"
kill "$(cat "$TMPD/daemon.pid")" 2>/dev/null

# --- nested calls, slots=0 ---------------------------------------------------------------------
out="$(CLAUDE_BUILD_SLOTS=1 timeout 5 "$BS" -- "$BS" -- "$BS" -- echo nested 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == nested ]] && ok "nested calls run at once, no deadlock" || bad "nested rc=$rc: $out"
"$BS" -- bash -c "$(gate f)" & PIDS+=($!); pf=$!
"$BS" -- bash -c "$(gate g)" & PIDS+=($!); pg=$!
until_ 5 test -e "$TMPD/f.started" -a -e "$TMPD/g.started"
out="$(CLAUDE_BUILD_SLOTS=0 timeout 3 "$BS" -- bash -c 'echo "now ${CLAUDE_BUILD_SLOT_HELD:-unset}"; exit 5' 2>&1)"; rc=$?
[[ $rc -eq 5 && "$out" == "now unset" ]] && ok "slots=0 never waits and keeps the exit code" || bad "slots=0 rc=$rc: $out"
[[ "$(CLAUDE_BUILD_SLOTS=0 "$BS" status)" == *off* ]] && ok "status says off at slots=0" || bad "status at 0"
touch "$TMPD/f.go" "$TMPD/g.go"; wait "$pf" "$pg"
[[ "$("$BS" status)" == *$'holders:\n  none\nwaiters:\n  none'* ]] && ok "status with nothing running" || bad "idle status: $("$BS" status)"

# --- refusals ----------------------------------------------------------------------------------
CLAUDE_BUILD_SLOTS=x "$BS" -- true 2>/dev/null; [[ $? -eq 64 ]] && ok "a bad CLAUDE_BUILD_SLOTS refuses" || bad "bad slots accepted"
CLAUDE_BUILD_SLOT_DIR=/cache/x "$BS" -- true 2>/dev/null; [[ $? -eq 64 ]] && ok "a slot dir under /cache refuses" || bad "/cache accepted"
"$BS" --name x 2>/dev/null; [[ $? -eq 64 ]] && ok "no command refuses" || bad "no command accepted"
"$BS" true 2>/dev/null; [[ $? -eq 64 ]] && ok "a command without -- refuses" || bad "no -- accepted"
"$BS" --help | grep -q 'claude-build-slot status' && ok "--help prints the usage" || bad "--help"
d="$(env -u CLAUDE_BUILD_SLOT_DIR CLAUDE_STATE_DIR="$TMPD/state" "$BS" status | head -1)"
[[ "$d" == *"$TMPD/state/build-slots" ]] && ok "the default dir is under CLAUDE_STATE_DIR" || bad "default dir: $d"

# --- surfaces ---------------------------------------------------------------------------------
grep -q 'COPY bin/claude-build-slot /usr/local/bin/claude-build-slot' "$REPO_ROOT/Dockerfile" \
    && grep -q '/usr/local/bin/claude-build-slot' <(sed -n '/^RUN chmod +x/,/chown/p' "$REPO_ROOT/Dockerfile") \
    && ok "the image ships it on PATH" || bad "Dockerfile"
for v in CLAUDE_BUILD_SLOTS CLAUDE_BUILD_SLOT_DIR; do
    grep -q "$v" "$REPO_ROOT/docs/environment-variables.md" && grep -q "$v" "$REPO_ROOT/.env.example" \
        && ok "$v is documented" || bad "$v missing from docs or .env.example"
done
grep -q 'claude-build-slot' "$REPO_ROOT/claude-config/CLAUDE.md" && grep -q 'claude-build-slot' "$REPO_ROOT/README.md" \
    && grep -q 'claude-build-slot' "$REPO_ROOT/CARD.md" && ok "CLAUDE.md, README and CARD name it" || bad "surfaces"

echo
echo "build-slot-unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
