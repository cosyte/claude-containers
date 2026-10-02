#!/usr/bin/env bash
# Unit tests for the kit hook (bin/claude-kit): a plugin marketplace from a git URL, its
# plugins and an optional start command, declared by CLAUDE_EXTRA_MARKETPLACES /
# CLAUDE_EXTRA_PLUGINS / CLAUDE_EXTRA_START_CMD. NO docker daemon, NO root, NO network.
#
# What this covers:
#   - check: the three values parsed, a typo named, a pinned entry told from an unpinned one
#   - settings: the merge into settings.json: unpinned entries keep autoUpdate=true and let an
#     existing entry win (the behaviour before the hook); "#ref" pins the source and sets
#     autoUpdate=false, and the declared pin replaces an older entry of that name
#   - install: against a fake `claude` CLI: a marketplace is added once (url#ref), a plugin
#     installed once at user scope, nothing repeated on the next boot, a moved pin warned
#     about and left alone, a failing CLI is a warning and exit 0 (it never fails a boot)
#   - start: the command runs once, detached, as given, with its output in the log
#   - the wiring: the entrypoint calls settings -> install (before sessions) -> start (after
#     them), each non-fatal; the image bakes the script; the generator and the launcher emit
#     and validate the values (--marketplace with #ref, --plugin, --start-cmd, --pids)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

KIT="$REPO_ROOT/bin/claude-kit"
EP="$REPO_ROOT/entrypoint.sh"
GEN="$REPO_ROOT/bin/claude-compose-gen"
LAUNCH="$REPO_ROOT/bin/claude-launch"
unset CLAUDE_EXTRA_MARKETPLACES CLAUDE_EXTRA_PLUGINS CLAUDE_EXTRA_START_CMD
export CLAUDE_CONFIG_DIR="$TMPD/config"; mkdir -p "$CLAUDE_CONFIG_DIR"
kit() { env "${KENV[@]}" "$KIT" "$@"; }

# ======================================================================================
echo "== check: the declaration =="
KENV=(CLAUDE_EXTRA_MARKETPLACES='tools=https://git.example.com/org/kit.git#v1.2.0, skills=git@git.example.com:org/skills.git'
      CLAUDE_EXTRA_PLUGINS='helper@tools,lint@skills' CLAUDE_EXTRA_START_CMD='kit serve --ensure')
out="$(kit check 2>&1)"; rc=$?
check "a full declaration is valid" test "$rc" -eq 0
[[ "$out" == *"marketplace tools: https://git.example.com/org/kit.git pinned to v1.2.0 (autoUpdate off)"* ]] \
    && ok "'#ref' is read as a pin, with auto-update off" || bad "pinned entry: $out"
[[ "$out" == *"marketplace skills: git@git.example.com:org/skills.git on its default branch (autoUpdate on)"* ]] \
    && ok "an entry without '#ref' follows the default branch and auto-updates (an SSH url keeps its ':' and '@')" || bad "unpinned entry: $out"
[[ "$out" == *"plugin helper@tools"* && "$out" == *"start command: kit serve --ensure"* ]] \
    && ok "plugins and the start command are listed" || bad "check output: $out"
KENV=(CLAUDE_EXTRA_MARKETPLACES='nourl,=x,tools=https://e.invalid/k.git#bad ref' CLAUDE_EXTRA_PLUGINS='noat')
out="$(kit check 2>&1)"; rc=$?
[[ $rc -ne 0 && "$out" == *"'nourl' is not name=url[#ref]"* && "$out" == *"is not a branch or tag"* && "$out" == *"'noat' is not plugin@marketplace"* ]] \
    && ok "typos fail check and each is named" || bad "bad declaration not refused (rc=$rc): $out"
KENV=(CLAUDE_EXTRA_PLUGINS='helper@elsewhere')
out="$(kit check 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"note: plugin helper@elsewhere names marketplace 'elsewhere'"* ]] \
    && ok "a plugin from an undeclared marketplace is a note, not an error (it may be baked in)" || bad "undeclared marketplace: rc=$rc $out"
KENV=()
check "nothing declared: check prints nothing and exits 0" test -z "$(kit check 2>&1)"

# ======================================================================================
echo "== settings: the merge into settings.json =="
S="$TMPD/settings.json"
echo '{"model":"opus","extraKnownMarketplaces":{"skills":{"source":{"source":"git","url":"https://old.invalid/skills.git"},"autoUpdate":false}},"enabledPlugins":{"lint@skills":false}}' > "$S"
KENV=(CLAUDE_EXTRA_MARKETPLACES='plain=https://git.example.com/org/plain.git,skills=https://new.invalid/skills.git'
      CLAUDE_EXTRA_PLUGINS='a@plain,lint@skills')
kit settings "$S" >/dev/null 2>&1; rc=$?
check "settings exits 0" test "$rc" -eq 0
check "an unpinned marketplace is a git source with autoUpdate=true (as before the hook)" \
    test "$(jq -c '.extraKnownMarketplaces.plain' "$S")" = '{"source":{"source":"git","url":"https://git.example.com/org/plain.git"},"autoUpdate":true}'
check "an existing entry wins over an unpinned declaration" \
    test "$(jq -r '.extraKnownMarketplaces.skills.source.url' "$S")" = "https://old.invalid/skills.git"
check "an existing enabledPlugins value wins (a plugin switched off stays off)" \
    test "$(jq -c '.enabledPlugins' "$S")" = '{"a@plain":true,"lint@skills":false}'
check "other settings keys are untouched" test "$(jq -r .model "$S")" = opus
KENV=(CLAUDE_EXTRA_MARKETPLACES='skills=https://new.invalid/skills.git#v2.0.0' CLAUDE_EXTRA_PLUGINS='lint@skills')
kit settings "$S" >/dev/null 2>&1
check "'#ref' pins the source (ref) and sets autoUpdate=false: auto-update would move a pinned plugin" \
    test "$(jq -c '.extraKnownMarketplaces.skills' "$S")" = '{"source":{"source":"git","url":"https://new.invalid/skills.git","ref":"v2.0.0"},"autoUpdate":false}'
KENV=(CLAUDE_EXTRA_MARKETPLACES='skills=https://new.invalid/skills.git#v2.1.0')
kit settings "$S" >/dev/null 2>&1
check "a pinned declaration replaces the older entry of that name (changing #ref moves the pin)" \
    test "$(jq -r '.extraKnownMarketplaces.skills.source.ref' "$S")" = "v2.1.0"
before="$(cat "$S")"; KENV=()
kit settings "$S" >/dev/null 2>&1
check "nothing declared: settings.json is not rewritten" test "$(cat "$S")" = "$before"
rm -f "$TMPD/new.json"
KENV=(CLAUDE_EXTRA_PLUGINS='a@plain'); kit settings "$TMPD/new.json" >/dev/null 2>&1
check "a missing settings.json is created" test "$(jq -c . "$TMPD/new.json")" = '{"extraKnownMarketplaces":{},"enabledPlugins":{"a@plain":true}}'
KENV=(CLAUDE_EXTRA_MARKETPLACES='bad entry,ok=https://e.invalid/ok.git')
out="$(kit settings "$TMPD/new.json" 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"WARNING"*"skipped"* && "$(jq -r '.extraKnownMarketplaces.ok.source.url' "$TMPD/new.json")" == "https://e.invalid/ok.git" ]] \
    && ok "a bad entry is skipped with a warning; the good ones still land" || bad "bad entry handling: rc=$rc $out"

# ======================================================================================
echo "== install: against a fake claude CLI =="
# A fake `claude`: keeps its marketplaces and plugins as JSON files, records every call.
FAKE="$TMPD/fake"; mkdir -p "$FAKE/bin"
cat > "$FAKE/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE/calls"
[[ -f "$FAKE/mk.json" ]] || echo '[]' > "$FAKE/mk.json"
[[ -f "$FAKE/pl.json" ]] || echo '[]' > "$FAKE/pl.json"
[[ -n "${FAKE_SLEEP:-}" ]] && sleep "$FAKE_SLEEP"
case "$1 $2 ${3:-}" in
    "plugin marketplace list") cat "$FAKE/mk.json" ;;
    "plugin marketplace add")
        [[ -n "${FAKE_FAIL_ADD:-}" ]] && { echo "fatal: could not read from remote repository" >&2; exit 1; }
        src="$4"; url="${src%%#*}"; ref=""; [[ "$src" == *"#"* ]] && ref="${src#*#}"
        name="$(basename "${url%.git}")"; [[ -n "${FAKE_NAME:-}" ]] && name="$FAKE_NAME"
        jq --arg n "$name" --arg u "$url" --arg r "$ref" \
            '. + [{name: $n, source: "git", url: $u} + (if $r == "" then {} else {ref: $r} end)]' "$FAKE/mk.json" > "$FAKE/mk.tmp" && mv "$FAKE/mk.tmp" "$FAKE/mk.json" ;;
    "plugin list "*|"plugin list") cat "$FAKE/pl.json" ;;
    "plugin install "*)
        [[ -n "${FAKE_FAIL_INSTALL:-}" ]] && { echo "Plugin not found in marketplace" >&2; exit 1; }
        jq --arg p "$3" '. + [{id: $p, version: "1.0.0", scope: "user", enabled: true}]' "$FAKE/pl.json" > "$FAKE/pl.tmp" && mv "$FAKE/pl.tmp" "$FAKE/pl.json" ;;
esac
exit 0
EOF
chmod +x "$FAKE/bin/claude"
export FAKE
reset_fake() { rm -f "$FAKE/calls" "$FAKE/mk.json" "$FAKE/pl.json"; }
calls() { grep -c -- "$1" "$FAKE/calls" 2>/dev/null; }
KENV=(PATH="$FAKE/bin:$PATH" CLAUDE_EXTRA_MARKETPLACES='kit=https://git.example.com/org/kit.git#v1.2.0'
      CLAUDE_EXTRA_PLUGINS='helper@kit')
reset_fake
out="$(kit install 2>&1)"; rc=$?
check "install exits 0" test "$rc" -eq 0
check "the marketplace is added from url#ref (the CLI's own pin syntax)" \
    grep -qxF 'plugin marketplace add https://git.example.com/org/kit.git#v1.2.0' "$FAKE/calls"
check "the plugin is installed at user scope" grep -qxF 'plugin install helper@kit --scope user' "$FAKE/calls"
[[ "$out" == *"marketplace kit: added"* && "$out" == *"plugin helper@kit: installed"* ]] \
    && ok "the boot log says what was added and installed" || bad "install output: $out"
out="$(kit install 2>&1)"
[[ "$(calls 'marketplace add')" == 1 && "$(calls 'plugin install')" == 1 && "$out" == *"already registered"* && "$out" == *"already installed"* ]] \
    && ok "the next boot adds and installs nothing again (idempotent)" || bad "second install repeated work: $(cat "$FAKE/calls")"
KENV=(PATH="$FAKE/bin:$PATH" CLAUDE_EXTRA_MARKETPLACES='kit=https://git.example.com/org/kit.git#v1.3.0' CLAUDE_EXTRA_PLUGINS='helper@kit')
out="$(kit install 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"registered at 'v1.2.0', the container declares '#v1.3.0'"* && "$(calls 'marketplace add')" == 1 && "$(calls 'marketplace remove')" == 0 ]] \
    && ok "a moved pin is a warning that names both refs; nothing is removed behind the operator's back" || bad "moved pin: rc=$rc $out"
reset_fake
KENV=(PATH="$FAKE/bin:$PATH" FAKE_NAME=other CLAUDE_EXTRA_MARKETPLACES='kit=https://git.example.com/org/kit.git')
out="$(kit install 2>&1)"
[[ "$out" == *"does not call itself 'kit'"* ]] && ok "a marketplace that names itself differently is called out" || bad "name mismatch not reported: $out"
reset_fake
KENV=(PATH="$FAKE/bin:$PATH" FAKE_FAIL_ADD=1 FAKE_FAIL_INSTALL=1 CLAUDE_EXTRA_MARKETPLACES='kit=https://git.example.com/org/kit.git' CLAUDE_EXTRA_PLUGINS='helper@kit')
out="$(kit install 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"WARNING: marketplace kit: could not add"*"could not read from remote repository"* && "$out" == *"WARNING: plugin helper@kit: could not install"* ]] \
    && ok "an unreachable kit is two warnings and exit 0: it never fails a boot" || bad "failing CLI: rc=$rc $out"
reset_fake
KENV=(PATH="$FAKE/bin:$PATH" FAKE_SLEEP=5 CLAUDE_KIT_TIMEOUT=1 CLAUDE_EXTRA_MARKETPLACES='kit=https://git.example.com/org/kit.git' CLAUDE_EXTRA_PLUGINS='helper@kit')
s=$SECONDS; out="$(kit install 2>&1)"; rc=$?
[[ $rc -eq 0 && $((SECONDS - s)) -lt 15 && "$out" == *"WARNING"* ]] \
    && ok "a hung CLI is cut off by CLAUDE_KIT_TIMEOUT, with a warning" || bad "timeout: rc=$rc took $((SECONDS - s))s: $out"
KENV=(PATH="/usr/bin:/bin" CLAUDE_KIT_CLAUDE_BIN=no-such-claude CLAUDE_EXTRA_PLUGINS='helper@kit')
out="$(kit install 2>&1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"no 'no-such-claude' on PATH"* ]] && ok "no CLI on PATH is a warning, not a failure" || bad "missing CLI: rc=$rc $out"
reset_fake; KENV=(PATH="$FAKE/bin:$PATH")
kit install >/dev/null 2>&1
check "nothing declared: the CLI is never called" test ! -e "$FAKE/calls"

# ======================================================================================
echo "== start: the optional start command =="
LOG="$TMPD/kit-start.log"; mkdir -p "$TMPD/ws"
KENV=(CLAUDE_KIT_START_LOG="$LOG" CLAUDE_WORKSPACE="$TMPD/ws" MARK="$TMPD/mark"
      CLAUDE_EXTRA_START_CMD='echo "started in $PWD"; sleep 0.3; echo done > "$MARK"')
out="$(kit start 2>&1)"; rc=$?
check "start returns at once (the command runs in the background)" test ! -e "$TMPD/mark"
for _ in $(seq 1 50); do [[ -e "$TMPD/mark" ]] && break; sleep 0.1; done
check "start exits 0 and the command ran to its end, detached" bash -c "(( $rc == 0 )) && [[ -e '$TMPD/mark' ]]"
check "its output is in the log, under a dated header, run from the workspace" \
    bash -c "grep -q '^== .*Z start command ==\$' '$LOG' && grep -qxF 'started in $TMPD/ws' '$LOG'"
out="$("$KIT" start 2>&1; echo "rc=$?")"
check "no start command: nothing runs, exit 0" test "$out" = "rc=0"
head -c 1200000 /dev/zero | tr '\0' 'x' > "$LOG"
KENV=(CLAUDE_KIT_START_LOG="$LOG" CLAUDE_EXTRA_START_CMD='true'); kit start >/dev/null 2>&1; sleep 0.3
check "the log is trimmed once it passes 1 MiB" bash -c "(( \$(stat -c %s '$LOG') < 400000 ))"

# ======================================================================================
echo "== the wiring: entrypoint, image, generator, launcher =="
ln_of() { grep -n -- "$1" "$EP" | head -1 | cut -d: -f1; }
set_l="$(ln_of 'claude-kit settings')"; ins_l="$(ln_of 'claude-kit install')"; sta_l="$(ln_of 'claude-kit start')"
prep_l="$(ln_of '/usr/local/bin/claude-sessions prepare')"; boot_l="$(ln_of 'claude-sessions boot --no-reconcile')"
check "the entrypoint merges settings, installs before any session exists, starts the command after them" \
    bash -c "(( ${set_l:-0} > 0 && ${set_l:-0} < ${ins_l:-0} && ${ins_l:-0} < ${prep_l:-0} && ${boot_l:-0} < ${sta_l:-0} ))"
check "install and start run as the agent user and can never fail the boot" \
    bash -c "grep -q 'asclaude /usr/local/bin/claude-kit install \\\\$' '$EP' && grep -q 'asclaude /usr/local/bin/claude-kit start \\\\$' '$EP' && [[ \$(grep -c 'WARNING: claude-kit' '$EP') -ge 3 ]]"
check "the entrypoint keeps one mechanism: no second jq merge of the two variables" \
    bash -c "! grep -q '_MKT_ENTRIES' '$EP'"
check "the image bakes claude-kit and makes it executable" \
    bash -c "grep -q '^COPY bin/claude-kit /usr/local/bin/claude-kit' '$REPO_ROOT/Dockerfile' && grep -q '/usr/local/bin/claude-kit' <(sed -n '/^RUN chmod +x/,/[^\\\\]\$/p' '$REPO_ROOT/Dockerfile')"

STUBD="$TMPD/stub"; mkdir -p "$STUBD"
cat > "$STUBD/docker" <<'STUB'
#!/usr/bin/env bash
d="${STUB_STATE:?}"
case "$1" in
    info)    echo "ok" ;;
    inspect) [[ -e "$d/created" ]] && { echo running; exit 0; }; exit 1 ;;
    image)   [[ "$*" == *Labels* ]] && echo 0; exit 0 ;;
    run)     shift; printf '%s\n' "$@" > "$d/run-args"; touch "$d/created"; echo deadbeef ;;
    *)       exit 0 ;;
esac
STUB
chmod +x "$STUBD/docker"
svc_block() { awk -v s="  $2:" 'index($0,s)==1{f=1;next} f && /^  [a-z0-9-]+:$/{exit} f{print}' "$1"; }
gen() { env -u CLAUDE_SESSIONS STUB_STATE="$TMPD" PATH="$STUBD:$PATH" CLAUDE_PORTS_USED_OVERRIDE= "$GEN" "$@" >"$TMPD/gen.log" 2>&1; }
gen --out "$TMPD/c.yml" acme/site acme/api \
    --marketplace 'site=kit=https://git.example.com/org/kit.git#v1.2.0' --plugin 'site=helper@kit' \
    --start-cmd 'site=kit serve --ensure "$HOME"' --pids 'site=8192'; rc=$?
st="$(svc_block "$TMPD/c.yml" site)"; ap="$(svc_block "$TMPD/c.yml" api)"
check "the generator emits the pinned marketplace and the plugin" \
    bash -c "(( $rc == 0 )) && grep -qxF '      CLAUDE_EXTRA_MARKETPLACES: \"kit=https://git.example.com/org/kit.git#v1.2.0\"' <<<\"\$1\" && grep -qxF '      CLAUDE_EXTRA_PLUGINS: \"helper@kit\"' <<<\"\$1\"" _ "$st"
check "--start-cmd is emitted escaped (\$\$ for compose, \\\" for YAML)" \
    grep -qxF '      CLAUDE_EXTRA_START_CMD: "kit serve --ensure \"$$HOME\""' <<<"$st"
check "--pids sets that service's pids_limit only" \
    bash -c "grep -qxF '    pids_limit: 8192' <<<\"\$1\" && ! grep -q 'pids_limit: 8192' <<<\"\$2\"" _ "$st" "$ap"
check "the other service gets none of it" bash -c "! grep -qE 'CLAUDE_EXTRA_(MARKETPLACES|PLUGINS|START_CMD)' <<<\"\$1\"" _ "$ap"
grep -q '+start-cmd +pids(8192)' "$TMPD/gen.log" && ok "the summary names the start command and the pids limit" || bad "summary: $(grep site "$TMPD/gen.log")"
gen --out "$TMPD/d.yml" acme/site --plugin 'site=noat' ; rc=$?
check "an invalid --plugin fails the generator and writes nothing" bash -c "(( $rc != 0 )) && [[ ! -e '$TMPD/d.yml' ]] && grep -q \"is not plugin@marketplace\" '$TMPD/gen.log'"
gen --out "$TMPD/d.yml" acme/site --pids 'site=lots'; rc=$?
check "--pids takes a positive integer" bash -c "(( $rc != 0 )) && grep -q 'positive integer' '$TMPD/gen.log'"
gen --out "$TMPD/d.yml" acme/site --env 'site=CLAUDE_EXTRA_START_CMD=x'; rc=$?
check "--env refuses CLAUDE_EXTRA_START_CMD (it has its own flag)" bash -c "(( $rc != 0 )) && grep -q 'use its own flag' '$TMPD/gen.log'"

mkdir -p "$TMPD/lws"
rm -f "$TMPD/run-args" "$TMPD/created"
env STUB_STATE="$TMPD" PATH="$STUBD:$PATH" CLAUDE_PORTS_USED_OVERRIDE="" "$LAUNCH" kittest --workspace "$TMPD/lws" --port 2298 \
    --marketplace 'kit=https://git.example.com/org/kit.git#v1.2.0' --plugin helper@kit --start-cmd 'kit serve --ensure' >"$TMPD/launch.log" 2>&1; rc=$?
args="$(cat "$TMPD/run-args" 2>/dev/null)"
(( rc == 0 )) && grep -qxF 'CLAUDE_EXTRA_MARKETPLACES=kit=https://git.example.com/org/kit.git#v1.2.0' <<<"$args" \
    && grep -qxF 'CLAUDE_EXTRA_PLUGINS=helper@kit' <<<"$args" && grep -qxF 'CLAUDE_EXTRA_START_CMD=kit serve --ensure' <<<"$args" \
    && ok "claude-launch passes the three values to the container" || bad "launch (rc=$rc): $(tail -3 "$TMPD/launch.log")"
rm -f "$TMPD/run-args" "$TMPD/created"
env STUB_STATE="$TMPD" PATH="$STUBD:$PATH" CLAUDE_PORTS_USED_OVERRIDE="" "$LAUNCH" kittest --workspace "$TMPD/lws" --port 2298 \
    --plugin noat >"$TMPD/launch.log" 2>&1; rc=$?
check "claude-launch refuses an invalid --plugin before docker run" bash -c "(( $rc != 0 )) && [[ ! -e '$TMPD/run-args' ]] && grep -q 'is not plugin@marketplace' '$TMPD/launch.log'"

echo
echo "kit-unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
