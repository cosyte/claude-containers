#!/usr/bin/env bash
# Unit tests for the flags claude-launch and claude-compose-gen share (bin/_common.sh,
# take_shared_flag): NO docker daemon (a stub), NO root.
#
# What this covers:
#   - each shared flag, valid and invalid, fed to both tools: the same accept or refuse, and
#     a refusal's message is the same text (claude-compose-gen gets the value as REPO=VALUE)
#   - every shared flag in the table has a case here
#   - each shared flag name is in exactly one `case` arm across the two tools and _common.sh
# shellcheck source=test/lib/prelude.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/prelude.sh"
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

LAUNCH="$REPO_ROOT/bin/claude-launch"
GEN="$REPO_ROOT/bin/claude-compose-gen"
COMMON="$REPO_ROOT/bin/_common.sh"

# A docker that knows the CDI GPU, has every volume and a browser image, and records `run`.
# `sleep` is stubbed too: claude-launch waits 2s after `docker run` for a crashing entrypoint.
STUBD="$TMPD/stub"; mkdir -p "$STUBD" "$TMPD/ws"
cat > "$STUBD/docker" <<'STUB'
#!/usr/bin/env bash
d="${STUB_STATE:?}"
case "$1" in
    info)    [[ "$*" == *DiscoveredDevices* ]] && echo "nvidia.com/gpu=all "; echo ok ;;
    inspect) [[ -e "$d/created" ]] && { echo running; exit 0; }; exit 1 ;;
    image)   [[ "$*" == *Labels* ]] && echo 1; exit 0 ;;
    volume|ps) exit 0 ;;
    run)     shift; printf '%s\n' "$@" > "$d/run-args"; touch "$d/created"; echo deadbeef ;;
    *)       exit 0 ;;
esac
STUB
printf '#!/bin/sh\nexit 0\n' > "$STUBD/sleep"
chmod +x "$STUBD/docker" "$STUBD/sleep"

# Each run: "<accepted|refused> <message>", the message being the error text from "==> error:" on.
errtext() { sed -n '/==> error:/,$p' "$1"; }
run_launch() {
    rm -f "$TMPD/run-args" "$TMPD/created"
    env -u CLAUDE_SESSIONS -u CLAUDE_GPU -u CLAUDE_BROWSER STUB_STATE="$TMPD" PATH="$STUBD:$PATH" \
        CLAUDE_PORTS_USED_OVERRIDE="" "$LAUNCH" ftest --workspace "$TMPD/ws" --port 2298 "$@" \
        >"$TMPD/launch.log" 2>&1
    if [[ $? -eq 0 && -e "$TMPD/run-args" ]]; then echo accepted; else echo refused; errtext "$TMPD/launch.log"; fi
}
run_gen() {
    rm -f "$TMPD/dc.yml"
    env -u CLAUDE_SESSIONS STUB_STATE="$TMPD" PATH="$STUBD:$PATH" CLAUDE_PORTS_USED_OVERRIDE="" \
        "$GEN" --out "$TMPD/dc.yml" acme/site "$@" >"$TMPD/gen.log" 2>&1
    if [[ $? -eq 0 && -e "$TMPD/dc.yml" ]]; then echo accepted; else echo refused; errtext "$TMPD/gen.log"; fi
}

# same <want> <label> <launch args> -- <compose-gen args>: both tools give <want>, and the
# same message when they refuse.
COVERED=" "
same() {
    local want="$1" label="$2" la=() ga=() l g; shift 2
    while [[ "$1" != -- ]]; do la+=("$1"); shift; done; shift
    ga=("$@")
    COVERED+="${la[0]} "
    l="$(run_launch "${la[@]}")"; g="$(run_gen "${ga[@]}")"
    if [[ "${l%%$'\n'*}" != "$want" || "${g%%$'\n'*}" != "$want" ]]; then
        bad "$label: want $want; claude-launch: ${l//$'\n'/ | }; claude-compose-gen: ${g//$'\n'/ | }"
    elif [[ "$want" == refused && ( "$l" != "$g" || "$l" != *"==> error:"* ) ]]; then
        bad "$label: the messages differ: claude-launch: ${l//$'\n'/ | }; claude-compose-gen: ${g//$'\n'/ | }"
    else
        l="${l#accepted}"; l="${l#refused$'\n'}"; ok "$label: $want by both${l:+: ${l//$'\n'/ }}"
    fi
}

KIT='kit=https://git.example.com/org/kit.git#v1.2.0'
echo "== each shared flag: the same accept or refuse, and the same message =="
same accepted "--model sonnet"             --model sonnet -- --model site=sonnet
same refused  "--model with no model"      --model '' -- --model site=
same accepted "--expose 4321:4321"         --expose 4321:4321 -- --expose site:4321:4321
same refused  "--expose with one port"     --expose 4321 -- --expose site:4321
same refused  "--expose with a name"       --expose web:4321 -- --expose site:web:4321
same accepted "--dev-cmd"                  --dev-cmd 'npm run dev -- --host 0.0.0.0' -- --dev-cmd 'site=npm run dev -- --host 0.0.0.0'
same refused  "--dev-cmd with no value"    --dev-cmd -- --dev-cmd
same accepted "--start-cmd"                --start-cmd 'kit serve --ensure' -- --start-cmd 'site=kit serve --ensure'
same refused  "--start-cmd empty"          --start-cmd '' -- --start-cmd site=
same refused  "--start-cmd with a newline" --start-cmd $'echo a\necho b' -- --start-cmd $'site=echo a\necho b'
same accepted "--browser"                  --browser -- --browser site
same accepted "--gpu"                      --gpu -- --gpu site
same accepted "--marketplace"              --marketplace "$KIT" -- --marketplace "site=$KIT"
same refused  "--marketplace with no URL"  --marketplace kit -- --marketplace site=kit
same accepted "--plugin"                   --plugin helper@kit --marketplace "$KIT" -- --plugin site=helper@kit --marketplace "site=$KIT"
same refused  "--plugin empty"             --plugin '' -- --plugin site=
same accepted "--accounts"                 --accounts a1,a2 -- --accounts site=a1,a2
same accepted "--accounts with stray spaces and commas" --accounts 'a1, ,a2 ' -- --accounts 'site=a1, ,a2 '
same refused  "--accounts with no name"    --accounts ' , ' -- --accounts 'site= , ' 
same accepted "--session"                  --session 'home model=sonnet' -- --session 'site=home model=sonnet'
same refused  "--session with a bad name"  --session Bad -- --session site=Bad
same refused  "--session empty"            --session ' ; ' -- --session 'site= ; '
same accepted "--env"                      --env MY_NOTE=1 -- --env site=MY_NOTE=1
same refused  "--env not KEY=VALUE"        --env 'not a var' -- --env 'site=not a var'
same refused  "--env ANTHROPIC_API_KEY"    --env ANTHROPIC_API_KEY=x -- --env site=ANTHROPIC_API_KEY=x
same refused  "--env with a newline"       --env $'K=a\nb' -- --env $'site=K=a\nb'
same accepted "--cache"                    --cache teamcache -- --cache teamcache
same refused  "--cache with no value"      --cache -- --cache
same accepted "--no-cache"                 --no-cache -- --no-cache
for flag in --docker --no-docker --sysbox --broker --worker-tarball; do
    same refused "$flag (removed)"         "$flag" -- "$flag"
done
for flag in -h --help; do
    COVERED+="$flag "
    run_launch "$flag" >/dev/null; l=$?; grep -q '^claude-launch' "$TMPD/launch.log"; lh=$?
    run_gen "$flag" >/dev/null; grep -q 'claude-compose-gen' "$TMPD/gen.log"; gh=$?
    (( lh == 0 && gh == 0 )) && ok "$flag prints each tool's own help" || bad "$flag: help not printed ($l)"
done

# --- the table, and one case arm per name -------------------------------------------------
# The shared names: every pattern of a case arm in shared_flag_row.
arm_names() {   # arm_names <file>...: each flag a `case` arm names, one per line
    sed -nE 's/^[[:space:]]*(-[-[:alnum:]]*(\|-[-[:alnum:]]*)*)\).*/\1/p' "$@" | tr '|' '\n'
}
shared="$(sed -n '/^shared_flag_row() {/,/^}/p' "$COMMON" > "$TMPD/table"; arm_names "$TMPD/table")"
(( $(wc -l <<<"$shared") >= 18 )) && ok "the table lists the shared flags ($(wc -l <<<"$shared"))" \
    || bad "the table in shared_flag_row looks empty: $shared"
echo "== every shared flag has a case above =="
missing=""
for f in $shared; do [[ "$COVERED" == *" $f "* ]] || missing+=" $f"; done
[[ -z "$missing" ]] && ok "every shared flag is fed to both tools" || bad "not tested:$missing"
echo "== each shared flag name is in exactly one case arm (the two tools and _common.sh) =="
all="$(arm_names "$LAUNCH" "$GEN" "$COMMON")"
for f in $shared; do
    n="$(grep -cxF -- "$f" <<<"$all")"
    (( n == 1 )) && ok "$f: one case arm" || bad "$f is in $n case arms across the tools and _common.sh"
done

echo
echo "flags-unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
