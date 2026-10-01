#!/usr/bin/env bash
# Unit tests for bin/claude-goal-chain: running a /goal program's goals back to back.
# NO docker daemon, NO network, NO root, NO real claude: tmux is a fake that behaves like a
# Claude Code session (/clear starts a new conversation, /goal writes "Goal set" to the
# transcript), the transcripts are fixtures, and origin is a local bare repo (file://).
#
#   - the parsers: goal and review conditions, reset hints, the last goal event
#   - a met goal with a COMPLETE ledger that ends at a checkpoint: it waits for the approval
#     file (one note), then clears the session and starts the next goal from its file
#   - it never advances past a BLOCKED report, an incomplete ledger, a busy session or a
#     goal met too recently; the last goal ends the program
#   - the delegated checkpoint review: the review goal it sends (under 4,000 characters,
#     quoting the owner), a review that did not approve stops the chain, one that did starts
#     the next goal; the watcher itself never writes a checkpoint file
#   - a usage-limit pause is nudged once, after the reset time; a stopped chain resumes when
#     a goal is set by hand; `start` and the single-instance lock
#   - lanes (a .lanes.toml on origin): the default `after` rules; a parked goal is skipped
#     and another lane's goal starts; a note-only parked goal counts as ready; a BLOCKED goal
#     does not stop the chain and is retried only once origin moved AND BLOCKED_RETRY passed;
#     a parked goal starts when its match turns true on origin; "finished" vs "complete";
#     `lanes` output and exit codes; an unusable manifest stops the chain
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GC="$REPO_ROOT/bin/claude-goal-chain"
TMPD="$(mktemp -d)"
FAKEPIDS=()
trap 'kill "${FAKEPIDS[@]}" 2>/dev/null; rm -rf "$TMPD"' EXIT

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
check() {  # check <description> <command...>
    local d="$1"; shift
    if "$@"; then ok "$d"; else bad "$d"; fi
}

export CLAUDE_CONFIG_DIR="$TMPD/config"
export CLAUDE_GOAL_CHAIN_STATE="$TMPD/state"
export CLAUDE_GOAL_CHAIN_STEP_SLEEP=0 CLAUDE_GOAL_CHAIN_SET_TIMEOUT=3 CLAUDE_GOAL_CHAIN_IDLE=120
export FAKE="$TMPD/fake"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$CLAUDE_CONFIG_DIR/sessions" "$FAKE"/{bin,input,sent,buf}

# --- the fake tmux: one pane per window; Enter submits what was typed or pasted -----------------
cat > "$FAKE/bin/tmux" <<'EOF'
#!/usr/bin/env bash
cmd="$1"; shift
win=""; lit=0; buf=""; args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t) win="${2##*:}"; shift 2 ;;
        -b) buf="$2"; shift 2 ;;
        -F) shift 2 ;;
        -l) lit=1; shift ;;
        -p|-r|-d) shift ;;
        *) args+=("$1"); shift ;;
    esac
done
case "$cmd" in
    list-panes) cat "$FAKE/panes/$win" 2>/dev/null || exit 1 ;;
    load-buffer) cp "${args[0]}" "$FAKE/buf/$buf" ;;
    paste-buffer) cat "$FAKE/buf/$buf" >> "$FAKE/input/$win" ;;
    send-keys)
        if (( lit )); then printf '%s' "${args[0]}" >> "$FAKE/input/$win"; exit 0; fi
        [[ "${args[0]}" == Enter ]] || exit 0
        text="$(cat "$FAKE/input/$win" 2>/dev/null)"; : > "$FAKE/input/$win"
        printf '%s\n' "$text" | jq -Rs . >> "$FAKE/sent/$win"
        sj="$(cat "$FAKE/sessjson/$win")"
        if [[ "$text" == "/clear" ]]; then
            n=$(( $(cat "$FAKE/clears/$win" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE/clears/$win"
            jq --arg s "$win-s$((n + 1))" '.sessionId = $s' "$sj" > "$sj.tmp" && mv "$sj.tmp" "$sj"
        elif [[ "$text" == "/goal "* ]]; then
            cond="${text#/goal }"
            tr="$("$FAKE/bin/transcript-of" "$win")"
            jq -cn --arg c "$cond" '{type:"system",subtype:"local_command",timestamp:"2026-09-29T11:00:00Z",content:("<local-command-stdout>Goal set: " + $c[0:100]),commandRun:{command:"goal",args:$c}}' >> "$tr"
            jq -cn --arg c "$cond" '{type:"attachment",timestamp:"2026-09-29T11:00:00Z",attachment:{type:"goal_status",met:false,sentinel:true,condition:$c}}' >> "$tr"
        fi ;;
esac
exit 0
EOF
cat > "$FAKE/bin/transcript-of" <<'EOF'
#!/usr/bin/env bash
sj="$FAKE/sessjson/$1"
cwd="$(jq -r .cwd "$(cat "$sj")")"; sid="$(jq -r .sessionId "$(cat "$sj")")"
d="$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$cwd" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$d"; echo "$d/$sid.jsonl"
EOF
# sessjson/<win> holds the PATH of that window's sessions/<pid>.json
chmod +x "$FAKE/bin/tmux" "$FAKE/bin/transcript-of"
export PATH="$FAKE/bin:$PATH"
mkdir -p "$FAKE/panes" "$FAKE/sessjson" "$FAKE/clears"

# --- a program repo with an origin -----------------------------------------------------------------
mkrepo() {  # mkrepo <name>: /ws/<name> cloned from a bare origin, with a 3-goal program
    local src="$TMPD/src/$1" g="$TMPD/src/$1/.claude/goals"
    mkdir -p "$g"; git init -q -b main "$src"
    echo "# $1 brief" > "$g/2026-09-$1.md"
    echo "$1 program, GOAL 1 of 3: Foundations. It ends at Checkpoint H (§14) and never writes CHECKPOINT-H.approved." > "$g/2026-09-$1-g1.goal.txt"
    printf '%s\n%s\n' "$1 program, GOAL 2 of 3: Build. Precondition: \`.claude/goals/CHECKPOINT-H.approved\` exists." \
        "The goal is met only when the final turn prints GOAL REPORT (goal 2)." > "$g/2026-09-$1-g2.goal.txt"
    echo "$1 program, GOAL 3 of 3: Finale. Precondition: the g2 ledger is complete." > "$g/2026-09-$1-g3.goal.txt"
    git -C "$src" add -A && git -C "$src" commit -qm init
    git clone -q --bare "$src" "$TMPD/bare/$1.git"
    git clone -q "file://$TMPD/bare/$1.git" "$TMPD/ws/$1"
}
push_file() {  # push_file <name> <path> <content>: commit a file to origin's main (like a goal would)
    local c="$TMPD/pusher-$1"
    [[ -d "$c" ]] || git clone -q "file://$TMPD/bare/$1.git" "$c"
    git -C "$c" pull -q --rebase
    mkdir -p "$(dirname "$c/$2")"; printf '%s\n' "$3" > "$c/$2"
    git -C "$c" add -A && git -C "$c" commit -qm "add $2" && git -C "$c" push -q origin main
}

# --- a fake session in a window --------------------------------------------------------------------
mksession() {  # mksession <win> <pane-id> <cwd> <status>
    bash -c 'exec -a claude-fake-session sleep 600' & FAKEPIDS+=($!)
    local pid=$! sj="$CLAUDE_CONFIG_DIR/sessions/$!.json"
    jq -n --argjson p "$pid" --arg s "$1-s1" --arg st "$4" --arg t "claude:@9.$2" --arg c "$3" \
        '{pid:$p,sessionId:$s,status:$st,tmux:$t,cwd:$c}' > "$sj"
    echo "$2" > "$FAKE/panes/$1"; echo "$sj" > "$FAKE/sessjson/$1"
}
set_status() { local sj; sj="$(cat "$FAKE/sessjson/$1")"; jq --arg st "$2" '.status = $st' "$sj" > "$sj.t" && mv "$sj.t" "$sj"; }
tr_of() { transcript-of "$1"; }
ev_met() {  # ev_met <win> <condition> <ts>
    jq -cn --arg c "$2" --arg t "$3" '{type:"attachment",timestamp:$t,attachment:{type:"goal_status",met:true,condition:$c,reason:"done"}}' >> "$(tr_of "$1")"
}
ev_say() {  # ev_say <win> <text> [sidechain]
    jq -cn --arg x "$2" --argjson sc "${3:-false}" '{type:"assistant",isSidechain:$sc,timestamp:"2026-09-29T09:59:00Z",message:{content:[{type:"text",text:$x}]}}' >> "$(tr_of "$1")"
}
sent_count() { [[ -f "$FAKE/sent/$1" ]] && wc -l < "$FAKE/sent/$1" || echo 0; }
sent_last() { tail -n1 "$FAKE/sent/$1" | jq -r .; }
sent_has() { jq -r . "$FAKE/sent/$1" 2>/dev/null | grep -qF -- "$2"; }
at() { CLAUDE_GOAL_CHAIN_NOW="$(date -d "$1" +%s)" "$GC" --once "${@:2}" >/dev/null 2>&1; }  # at <time> <args>

# shellcheck disable=SC1090
source "$GC"   # the functions, without running main

echo "== parsers =="
check "a goal condition parses to program, n and N" [ "$(parse_goal 'home program, GOAL 2 of 9: Build. FIRST…')" = "home 2 9" ]
check "a review condition parses to checkpoint, program and n" \
    [ "$(parse_review 'CHECKPOINT REVIEW H for the home program, after GOAL 1 of 9, on Noah'"'"'s behalf.')" = "H home 1" ]
not() { ! "$@"; }
check "anything else is not a program goal" not parse_goal 'all tests in test/auth pass'
CLAUDE_GOAL_CHAIN_NOW="$(date -d '2026-09-29T12:00:00Z' +%s)"; export CLAUDE_GOAL_CHAIN_NOW
check "'resets Oct 1, 1pm (UTC)' is 2026-10-01 13:00 UTC" \
    [ "$(reset_epoch "You've hit your weekly limit · resets Oct 1, 1pm (UTC)")" = "$(date -d '2026-10-01T13:00:00Z' +%s)" ]
check "'resets 3pm (UTC)' later today is today" [ "$(reset_epoch "You've hit your session limit · resets 3pm (UTC)")" = "$(date -d '2026-09-29T15:00:00Z' +%s)" ]
check "'resets Mon 12:00am (UTC)' is the coming Monday" [ "$(reset_epoch "You've hit your weekly limit · resets Mon 12:00am (UTC)")" = "$(date -d '2026-10-05T00:00:00Z' +%s)" ]
check "'resets 9am (UTC)' already past is tomorrow" [ "$(reset_epoch "You've hit your session limit · resets 9am (UTC)")" = "$(date -d '2026-09-30T09:00:00Z' +%s)" ]
check "the older 'will reset at 3pm (America/Santiago)' honours the zone" \
    [ "$(reset_epoch 'Claude usage limit reached. Your limit will reset at 3pm (America/Santiago).')" = "$(TZ=America/Santiago date -d '2026-09-29 15:00' +%s)" ]
check "no hint, no time" [ -z "$(reset_epoch 'something failed')" ]
unset CLAUDE_GOAL_CHAIN_NOW
T="$TMPD/t.jsonl"
{ jq -cn '{type:"system",subtype:"local_command",timestamp:"T1",content:"<local-command-stdout>Goal set: home program, GOAL 1 of 3",commandRun:{args:"home program, GOAL 1 of 3: x"}}'
  jq -cn '{type:"assistant",timestamp:"T2",message:{content:[{type:"text",text:"Goal set: a sentence the model wrote"}]}}'
  jq -cn '{type:"attachment",isSidechain:true,timestamp:"T3",attachment:{type:"goal_status",met:true,condition:"a subagent"}}'
} > "$T"
check "the last event is the main thread's 'set', not model text or a subagent" [ "$(last_goal_event "$T" | cut -f1,2)" = "T1	set" ]
jq -cn '{type:"system",subtype:"informational",timestamp:"T4",content:"Goal paused · usage limit reached · send a message after it resets to continue"}' >> "$T"
check "a usage pause is read as 'paused'" [ "$(last_goal_event "$T" | cut -f2)" = paused ]
jq -cn '{type:"attachment",timestamp:"T5",attachment:{type:"goal_status",met:false,condition:"home program, GOAL 1 of 3"}}' >> "$T"
check "met:false without the sentinel is a failed goal" [ "$(last_goal_event "$T" | cut -f2)" = failed ]

echo "== a met goal at a checkpoint, then the next goal =="
mkdir -p "$TMPD/bare" "$TMPD/ws"
mkrepo home
WS="$TMPD/ws/home"
check "needed_checkpoints: g2 needs H, g1 needs nothing" \
    [ "$(needed_checkpoints "$WS/.claude/goals/2026-09-home-g2.goal.txt"):$(needed_checkpoints "$WS/.claude/goals/2026-09-home-g1.goal.txt")" = "CHECKPOINT-H.approved:" ]
mksession home %1 "$WS" busy
G1="$(cat "$WS/.claude/goals/2026-09-home-g1.goal.txt")"
ev_say home "GOAL REPORT (goal 1): Foundations ... Checkpoint H packet ..."
ev_met home "$G1" 2026-09-29T10:00:00Z
at 2026-09-29T10:05:00Z home="$WS"
check "a busy session is left alone" [ "$(sent_count home)" = 0 ]
set_status home idle
at 2026-09-29T10:01:00Z home="$WS"
check "a goal met under IDLE_SECONDS ago is left alone" [ "$(sent_count home)" = 0 ]
at 2026-09-29T10:05:00Z home="$WS"
check "no COMPLETE line on origin: the chain stops with one note" bash -c "[ $(sent_count home) = 1 ] && jq -r . '$FAKE/sent/home' | grep -q 'no .COMPLETE (goal 1). line'"
check "  ...and the session was not cleared" [ ! -f "$FAKE/clears/home" ]
at 2026-09-29T10:06:00Z home="$WS"
check "  ...the note is sent once, not every pass" [ "$(sent_count home)" = 1 ]

# The ledger lands: a fresh met event (the goal re-run by hand) is judged again.
rm -f "$CLAUDE_GOAL_CHAIN_STATE/home.state"
push_file home .claude/goals/2026-09-home-g1.status.md "COMPLETE (goal 1): 2026-09-29"
ev_met home "$G1" 2026-09-29T10:10:00Z
at 2026-09-29T10:15:00Z home="$WS"
check "COMPLETE, no approval, no delegation: it waits and says what it waits for" \
    bash -c "sent_last() { tail -n1 '$FAKE/sent/home' | jq -r .; }; sent_last | grep -q 'starts once .claude/goals/CHECKPOINT-H.approved is on origin'"
check "  ...phase is 'waiting', the session not cleared" bash -c "grep -q '^phase=waiting' '$CLAUDE_GOAL_CHAIN_STATE/home.state' && [ ! -f '$FAKE/clears/home' ]"
n_before="$(sent_count home)"
at 2026-09-29T10:20:00Z home="$WS"
check "  ...and it does not repeat the note while waiting" [ "$(sent_count home)" = "$n_before" ]
push_file home .claude/goals/CHECKPOINT-H.approved "Approved by Noah, 2026-09-29"
at 2026-09-29T10:25:00Z home="$WS"
check "the approval lands: /clear, then /goal with goal 2's file verbatim" \
    bash -c "[ \"\$(cat '$FAKE/clears/home')\" = 1 ] && [ \"\$(tail -n2 '$FAKE/sent/home' | head -n1 | jq -r .)\" = /clear ] && [ \"\$(tail -n1 '$FAKE/sent/home' | jq -r .)\" = \"/goal \$(cat '$WS/.claude/goals/2026-09-home-g2.goal.txt')\" ]"
check "  ...the new conversation has goal 2 set" [ "$(last_goal_event "$(tr_of home)" | cut -f2)" = active ]
check "  ...phase is back to 'watching'" grep -q '^phase=watching' "$CLAUDE_GOAL_CHAIN_STATE/home.state"

echo "== BLOCKED, and the end of the program =="
G2="$(cat "$WS/.claude/goals/2026-09-home-g2.goal.txt")"
ev_say home "BLOCKED (goal 2): precondition not met"
ev_met home "$G2" 2026-09-29T11:30:00Z
push_file home .claude/goals/2026-09-home-g2.status.md "COMPLETE (goal 2): 2026-09-29"
clears_before="$(cat "$FAKE/clears/home")"
at 2026-09-29T11:40:00Z home="$WS"
check "a BLOCKED report stops the chain even though the evaluator said met" \
    bash -c "tail -n1 '$FAKE/sent/home' | jq -r . | grep -q 'goal 2 ended BLOCKED' && [ \"\$(cat '$FAKE/clears/home')\" = $clears_before ]"
check "a goal set by hand in a stopped session resumes the chain" \
    bash -c "printf '/goal %s' \"\$(cat '$WS/.claude/goals/2026-09-home-g3.goal.txt')\" > '$FAKE/input/home'; tmux send-keys -t claude:home Enter; CLAUDE_GOAL_CHAIN_NOW=\$(date +%s) '$GC' --once home='$WS' >/dev/null 2>&1; grep -q '^phase=watching' '$CLAUDE_GOAL_CHAIN_STATE/home.state'"
G3="$(cat "$WS/.claude/goals/2026-09-home-g3.goal.txt")"
ev_say home "GOAL REPORT (goal 3): Finale ..."
ev_met home "$G3" 2026-09-29T12:00:00Z
push_file home .claude/goals/2026-09-home-g3.status.md "COMPLETE (goal 3): 2026-09-29"
at 2026-09-29T12:05:00Z home="$WS"
check "the last goal file done: 'program is complete', phase 'done', nothing started" \
    bash -c "tail -n1 '$FAKE/sent/home' | jq -r . | grep -q 'The home program is complete' && grep -q '^phase=done' '$CLAUDE_GOAL_CHAIN_STATE/home.state'"

echo "== the delegated checkpoint review =="
mkrepo shop
WS2="$TMPD/ws/shop"
mksession shop %2 "$WS2" idle
S1="$(cat "$WS2/.claude/goals/2026-09-shop-g1.goal.txt")"
ev_say shop "GOAL REPORT (goal 1): Foundations. Checkpoint H packet: proposals (a) (b)."
ev_met shop "$S1" 2026-09-29T10:00:00Z
push_file shop .claude/goals/2026-09-shop-g1.status.md "COMPLETE (goal 1): 2026-09-29"
QUOTE="it reviews and approves for me then starts the next goal"
at 2026-09-29T10:05:00Z --review-checkpoints "$QUOTE" shop="$WS2"
REVIEW="$(tail -n1 "$FAKE/sent/shop" | jq -r . | sed 's|^/goal ||')"
check "COMPLETE + delegation: /clear, then a review goal for Checkpoint H" \
    bash -c "[ \"\$(cat '$FAKE/clears/shop')\" = 1 ] && printf '%s' \"\$1\" | head -n1 | grep -q '^CHECKPOINT REVIEW H for the shop program, after GOAL 1 of 3'" _ "$REVIEW"
check "  ...under the 4,000-character /goal limit" [ "$(printf '%s' "$REVIEW" | LC_ALL=C.UTF-8 wc -m)" -lt 4000 ]
check "  ...quoting the owner's delegation and the approval wording" \
    bash -c "grep -qF \"$QUOTE\" <<<\"\$1\" && grep -q \"Approved on Noah's behalf by the delegated checkpoint review\" <<<\"\$1\" && ! grep -qF '\\\"' <<<\"\$1\"" _ "$REVIEW"
check "  ...refusing what only the owner can do or judge" bash -c "grep -q 'Never approve on Noah.s behalf anything only Noah can do or judge' <<<\"\$1\" && grep -q 'fit, feel or look' <<<\"\$1\"" _ "$REVIEW"
check "  ...with the goal's packet saved for it" grep -q "Checkpoint H packet" "$CLAUDE_GOAL_CHAIN_STATE/packet-shop-H.md"
check "  ...and phase 'reviewing'" grep -q '^phase=reviewing' "$CLAUDE_GOAL_CHAIN_STATE/shop.state"
ev_say shop "CHECKPOINT REVIEW (H): NOT APPROVED. The gate fails on a fresh clone."
ev_met shop "$REVIEW" 2026-09-29T10:40:00Z
at 2026-09-29T10:45:00Z shop="$WS2"
check "a review that did not approve stops the chain; nothing is started" \
    bash -c "tail -n1 '$FAKE/sent/shop' | jq -r . | grep -q 'review did not approve' && [ \"\$(cat '$FAKE/clears/shop')\" = 1 ]"
# Re-run: this time the review approved (it committed the file).
push_file shop .claude/goals/CHECKPOINT-H.approved "Approved on Noah's behalf by the delegated checkpoint review, 2026-09-29"
ev_met shop "$REVIEW" 2026-09-29T11:00:00Z
at 2026-09-29T11:05:00Z shop="$WS2"
check "a review that approved: /clear, then goal 2 from its file" \
    bash -c "[ \"\$(cat '$FAKE/clears/shop')\" = 2 ] && [ \"\$(tail -n1 '$FAKE/sent/shop' | jq -r .)\" = \"/goal \$(cat '$WS2/.claude/goals/2026-09-shop-g2.goal.txt')\" ]"
check "the watcher itself never writes or commits a checkpoint file" \
    bash -c "! grep -n 'CHECKPOINT' '$GC' | grep -qE 'git +(add|commit)|>[[:space:]]*\"?[^[:space:]]*CHECKPOINT'"
check "  ...and no checkpoint file appeared that the test did not push" \
    bash -c "[ -z \"\$(git -C '$WS2' status --porcelain --untracked-files=all | grep CHECKPOINT)\" ]"

echo "== a usage-limit pause =="
mkrepo lab
WS3="$TMPD/ws/lab"
mksession lab %3 "$WS3" idle
jq -cn '{type:"system",subtype:"local_command",timestamp:"2026-09-29T09:00:00Z",content:"<local-command-stdout>Goal set: lab program, GOAL 1 of 3",commandRun:{args:"lab program, GOAL 1 of 3: Foundations"}}' >> "$(tr_of lab)"
jq -cn '{type:"assistant",isApiErrorMessage:true,timestamp:"2026-09-29T10:00:00Z",message:{content:[{type:"text",text:"You'"'"'ve hit your weekly limit · resets Oct 1, 1pm (UTC)"}]}}' >> "$(tr_of lab)"
jq -cn '{type:"system",subtype:"informational",timestamp:"2026-09-29T10:00:00Z",content:"Goal paused · usage limit reached · send a message after it resets to continue"}' >> "$(tr_of lab)"
at 2026-10-01T12:00:00Z lab="$WS3"
check "before the reset: no nudge" [ "$(sent_count lab)" = 0 ]
at 2026-10-01T13:05:00Z lab="$WS3"
check "after the reset: one nudge to continue, naming the limit" bash -c "[ $(sent_count lab) = 1 ] && tail -n1 '$FAKE/sent/lab' | jq -r . | grep -q 'Continue toward the goal' && tail -n1 '$FAKE/sent/lab' | jq -r . | grep -q 'resets Oct 1'"
at 2026-10-01T13:10:00Z lab="$WS3"
check "  ...and not again a few minutes later" [ "$(sent_count lab)" = 1 ]

echo "== lanes =="
export CLAUDE_GOAL_CHAIN_PARK_POLL=600 CLAUDE_GOAL_CHAIN_BLOCKED_RETRY=21600
mklanes() {  # mklanes <name> <manifest>: goals 1-5 with a lanes manifest; goal 4 needs CHECKPOINT-Z
    local src="$TMPD/src/$1" g="$TMPD/src/$1/.claude/goals" n
    mkdir -p "$g"; git init -q -b main "$src"
    for n in 1 2 3 5; do echo "$1 program, GOAL $n of 5: step $n." > "$g/2026-10-$1-g$n.goal.txt"; done
    echo "$1 program, GOAL 4 of 5: step 4. Precondition: \`.claude/goals/CHECKPOINT-Z.approved\` exists." > "$g/2026-10-$1-g4.goal.txt"
    printf '%s\n' "$2" > "$g/2026-10-$1.lanes.toml"
    git -C "$src" add -A && git -C "$src" commit -qm init
    git clone -q --bare "$src" "$TMPD/bare/$1.git"
    git clone -q "file://$TMPD/bare/$1.git" "$TMPD/ws/$1"
}
mklanes dev '[lanes]
input = "mice"
house = "sensors"
audio = "speakers"

[[goal]]
n = 1
lane = "input"

[[goal]]
n = 2
lane = "input"
parked_until = [ { file = "hw/pick.toml", match = '"'"'^round2 = "g6r'"'"' } ]

[[goal]]
n = 3
lane = "house"

[[goal]]
n = 5
lane = "audio"
parked_until = [ { note = "the speakers are bought" } ]'
WS4="$TMPD/ws/dev"
L="$WS4/.claude/goals/2026-10-dev"
check "default 'after': the lane's previous goal, none for a lane's first, n-1 for a goal with no lane (4 is unlisted)" \
    [ "$(lanes_read "$WS4" 2026-10-dev | awk -F'\t' '$1 == "goal" {printf "%s:%s:%s:%s ", $2, $3, $4, $5}')" = "1:input:-:0 2:input:1:1 3:house:-:0 4:-:3:0 5:audio:-:1 " ]
check "  ...and the conditions come out one per line" \
    [ "$(lanes_read "$WS4" 2026-10-dev | awk -F'\t' '$1 == "cond" {printf "%s|%s|%s|%s ", $2, $3, $4, $5}')" = '2|match|hw/pick.toml|^round2 = "g6r 5|note|the speakers are bought| ' ]
out="$("$GC" lanes "$WS4" 2>&1)"; rc=$?
check "'lanes' before any work: exit 1, not finished; goal 1 ready, goal 2 (owner) waits on goal 1, goal 4 on goal 3 and CHECKPOINT-Z" \
    bash -c "[ $rc = 1 ] && grep -q '^finished: no' <<<\"\$1\" && grep -qE '^1 +input +agent +ready' <<<\"\$1\" && grep -qE '^2 +input +owner +waiting +after goal 1$' <<<\"\$1\" && grep -qE '^4 +- +agent +waiting +after goal 3; CHECKPOINT-Z.approved' <<<\"\$1\"" _ "$out"
push_file dev .claude/goals/CHECKPOINT-Z.approved "Approved by Noah, 2026-09-30"
mksession dev %4 "$WS4" idle
ev_say dev "GOAL REPORT (goal 1): step 1"
ev_met dev "$(cat "$L-g1.goal.txt")" 2026-09-30T10:00:00Z
push_file dev .claude/goals/2026-10-dev-g1.status.md "COMPLETE (goal 1): 2026-09-30"
at 2026-09-30T10:05:00Z dev="$WS4"
check "goal 1 done, goal 2 parked: the house lane's goal 3 starts (/clear, then its file)" \
    bash -c "[ \"\$(cat '$FAKE/clears/dev')\" = 1 ] && [ \"\$(tail -n1 '$FAKE/sent/dev' | jq -r .)\" = \"/goal \$(cat '$L-g3.goal.txt')\" ]"
ev_say dev "GOAL REPORT (goal 3): step 3"
ev_met dev "$(cat "$L-g3.goal.txt")" 2026-09-30T11:00:00Z
push_file dev .claude/goals/2026-10-dev-g3.status.md "COMPLETE (goal 3): 2026-09-30"
at 2026-09-30T11:05:00Z dev="$WS4"
check "goal 3 done: goal 4 (after 3, its checkpoint on origin) starts" [ "$(sent_last dev)" = "/goal $(cat "$L-g4.goal.txt")" ]
ev_say dev "GOAL REPORT (goal 4): step 4"
ev_met dev "$(cat "$L-g4.goal.txt")" 2026-09-30T12:00:00Z
push_file dev .claude/goals/2026-10-dev-g4.status.md "COMPLETE (goal 4): 2026-09-30"
at 2026-09-30T12:05:00Z dev="$WS4"
check "a note-only parked goal counts as ready: goal 5 starts (goal 2 is still parked)" [ "$(sent_last dev)" = "/goal $(cat "$L-g5.goal.txt")" ]
out="$("$GC" lanes "$WS4" 2026-10-dev 2>&1)"; rc=$?
check "'lanes' now: exit 0, finished (only parked goals open) but not complete" \
    bash -c "[ $rc = 0 ] && grep -q '^finished: yes' <<<\"\$1\" && grep -q '^complete: no' <<<\"\$1\" && grep -qE '^4 +- +agent +done' <<<\"\$1\"" _ "$out"
clears_before="$(cat "$FAKE/clears/dev")"
ev_say dev "BLOCKED (goal 5): precondition not met"
ev_met dev "$(cat "$L-g5.goal.txt")" 2026-09-30T13:00:00Z
at 2026-09-30T13:05:00Z dev="$WS4"
check "a BLOCKED goal does not stop the chain: one 'has finished' note naming what is open" \
    bash -c "sent_last() { tail -n1 '$FAKE/sent/dev' | jq -r .; }; sent_last | grep -q 'The dev program has finished' && sent_last | grep -q 'goal 2 (input) parked: no line of hw/pick.toml' && sent_last | grep -q 'goal 5 (audio) blocked'"
check "  ...phase 'parked', nothing cleared, the hold recorded" \
    bash -c "grep -q '^phase=parked' '$CLAUDE_GOAL_CHAIN_STATE/dev.state' && grep -q '^blocked_5=' '$CLAUDE_GOAL_CHAIN_STATE/dev.state' && [ \"\$(cat '$FAKE/clears/dev')\" = $clears_before ]"
n_before="$(sent_count dev)"
at 2026-09-30T13:10:00Z dev="$WS4"
check "  ...not re-checked before PARK_POLL, and no repeated note" [ "$(sent_count dev)" = "$n_before" ]
push_file dev hw/pick.toml 'round2 = "g6r1a"'
at 2026-09-30T14:20:00Z dev="$WS4"
check "the parked goal's condition turns true on origin: goal 2 starts" [ "$(sent_last dev)" = "/goal $(cat "$L-g2.goal.txt")" ]
ev_say dev "GOAL REPORT (goal 2): step 2"
ev_met dev "$(cat "$L-g2.goal.txt")" 2026-09-30T15:00:00Z
push_file dev .claude/goals/2026-10-dev-g2.status.md "COMPLETE (goal 2): 2026-09-30"
at 2026-09-30T15:05:00Z dev="$WS4"
check "origin moved, but BLOCKED_RETRY has not passed: goal 5 is still held (a note, nothing started)" \
    bash -c "tail -n1 '$FAKE/sent/dev' | jq -r . | grep -q 'goal 5 (audio) blocked' && ! tail -n1 '$FAKE/sent/dev' | jq -r . | grep -q 'goal 2'"
at 2026-09-30T19:30:00Z dev="$WS4"
check "origin moved and BLOCKED_RETRY passed: goal 5 is retried" [ "$(sent_last dev)" = "/goal $(cat "$L-g5.goal.txt")" ]
ev_say dev "GOAL REPORT (goal 5): step 5"
ev_met dev "$(cat "$L-g5.goal.txt")" 2026-09-30T20:00:00Z
push_file dev .claude/goals/2026-10-dev-g5.status.md "COMPLETE (goal 5): 2026-09-30"
at 2026-09-30T20:05:00Z dev="$WS4"
check "every goal done: 'complete' note, phase 'done'" \
    bash -c "tail -n1 '$FAKE/sent/dev' | jq -r . | grep -q 'The dev program is complete: every goal in its lanes manifest is COMPLETE' && grep -q '^phase=done' '$CLAUDE_GOAL_CHAIN_STATE/dev.state'"

# The hold on its own: it lifts only when origin moved AND BLOCKED_RETRY passed.
state_set hold blocked_5 "k sha1 1000"
check "blocked_hold: same commit, long after: held" bash -c "CLAUDE_GOAL_CHAIN_NOW=$((1000 + 30000)); export CLAUDE_GOAL_CHAIN_NOW; source '$GC'; blocked_hold hold 5 sha1"
check "blocked_hold: origin moved, too soon: held" bash -c "CLAUDE_GOAL_CHAIN_NOW=$((1000 + 3600)); export CLAUDE_GOAL_CHAIN_NOW; source '$GC'; blocked_hold hold 5 sha2"
check "blocked_hold: origin moved and BLOCKED_RETRY passed: released" bash -c "CLAUDE_GOAL_CHAIN_NOW=$((1000 + 30000)); export CLAUDE_GOAL_CHAIN_NOW; source '$GC'; ! blocked_hold hold 5 sha2"
check "blocked_hold: no record, nothing held" bash -c "source '$GC'; ! blocked_hold hold 7 sha1"

mklanes bad '[[goal]]
n = "one"'
WS5="$TMPD/ws/bad"
out="$("$GC" lanes "$WS5" 2>&1)"; rc=$?
check "an unusable manifest: 'lanes' exits 2 and says why" bash -c "[ $rc = 2 ] && grep -q 'needs a whole number n' <<<\"\$1\"" _ "$out"
mksession bad %5 "$WS5" idle
ev_say bad "GOAL REPORT (goal 1): step 1"
ev_met bad "$(cat "$WS5/.claude/goals/2026-10-bad-g1.goal.txt")" 2026-09-30T10:00:00Z
push_file bad .claude/goals/2026-10-bad-g1.status.md "COMPLETE (goal 1): 2026-09-30"
at 2026-09-30T10:05:00Z bad="$WS5"
check "  ...and the chain stops with a note instead of guessing" \
    bash -c "tail -n1 '$FAKE/sent/bad' | jq -r . | grep -q 'lanes manifest cannot be used' && grep -q '^phase=stopped' '$CLAUDE_GOAL_CHAIN_STATE/bad.state'"
out="$("$GC" lanes "$TMPD/ws/home" 2>&1)"; rc=$?
check "a program without a manifest: 'lanes' exits 2 (the strict n, n+1 chain above is unchanged)" bash -c "[ $rc = 2 ] && grep -q '0 lanes manifests' <<<\"\$1\"" _ "$out"

echo "== start, status, and the lock =="
CLAUDE_GOAL_CHAIN_NOW="$(date +%s)" "$GC" start lab 2 "$WS3" >/dev/null 2>&1
check "'start WINDOW N' clears and sets goal N" \
    [ "$(tail -n1 "$FAKE/sent/lab" | jq -r .)" = "/goal $(cat "$WS3/.claude/goals/2026-09-lab-g2.goal.txt")" ]
check "'status' lists the watched windows and the delegation" \
    bash -c "'$GC' status | grep -q '^home ' && '$GC' status | grep -q 'checkpoint reviews: delegated'"
( exec 8>"$CLAUDE_GOAL_CHAIN_STATE/.lock"; flock 8; sleep 5 ) & FAKEPIDS+=($!)
sleep 0.5
"$GC" --once lab="$WS3" >/dev/null 2>&1; rc=$?
check "a second watcher refuses while one holds the lock" [ "$rc" = 1 ]
check "an unknown option is refused" bash -c "! '$GC' --bogus x >/dev/null 2>&1"

echo
echo "== $PASS passed, $FAIL failed =="
(( FAIL == 0 ))
