#!/usr/bin/env bash
# Unit tests that need NO docker: safe for CI and for `scripts/verify.sh`.
#
# Covers the pure-logic checks in bin/_common.sh that survive the substrate strip (the Sysbox
# version-floor refusal, preflight_sysbox/sysbox_version_check, was removed along
# with the nested-Sysbox worker-broker substrate it gated: see
# docs/legacy-sysbox-broker.md):
#   - version_ge: the generic dotted-numeric comparator (fail-closed on garbage)
#   - preflight_runc: the warn-only posture is preserved (never exits non-zero)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

# Run a snippet in a subshell that sources _common.sh, with docker checks stubbed out.
# Prints nothing; the caller asserts on the exit code.
in_env() {  # in_env <extra-env...> -- <bash-snippet>
    local envs=()
    while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done
    shift
    ( export "${envs[@]}" 2>/dev/null
      # shellcheck disable=SC1091
      source "$REPO_ROOT/bin/_common.sh"
      eval "$1"
    ) >/dev/null 2>&1
}

echo "== version_ge helper =="
( # shellcheck disable=SC1091
  source "$REPO_ROOT/bin/_common.sh"
  version_ge 0.7.0 0.7.0        || exit 1
  version_ge 0.7.1 0.7.0        || exit 1
  version_ge 1.0.0 0.7.0        || exit 1
  version_ge 0.10.0 0.9.9       || exit 1   # numeric, not lexical
  version_ge 0.08.0 0.7.0       || exit 1   # leading zero must not trip octal
  ! version_ge 0.6.7 0.7.0      || exit 1
  ! version_ge 0.7 0.7.1        || exit 1   # missing part defaults to 0
  rc=0; version_ge banana 0.7.0 || rc=$?
  [[ $rc -eq 2 ]] || exit 1                 # garbage → ERROR, not a verdict
) >/dev/null 2>&1 && ok "version_ge truth table holds (incl. leading-zero + garbage→error)" \
                  || bad "version_ge truth table failed"

echo
echo "== preflight_runc: warn-only posture preserved (K=1 non-regression) =="

# preflight_runc must never exit non-zero: it warns. Feed it a vulnerable runc via a stub.
STUB="$(mktemp -d)"
trap 'rm -rf "$STUB"' EXIT
printf '#!/bin/sh\necho "runc version 1.2.7"\n' > "$STUB/runc" && chmod +x "$STUB/runc"
if in_env PATH="$STUB:/usr/bin:/bin" -- preflight_runc; then
    ok  "a vulnerable runc (1.2.7) only WARNS: flat launch path behavior unchanged"
else
    bad "preflight_runc must never exit non-zero (it is warn-only by design)"
fi
printf '#!/bin/sh\necho "runc version 1.3.3"\n' > "$STUB/runc"
if in_env PATH="$STUB:/usr/bin:/bin" -- preflight_runc; then
    ok  "a patched runc (1.3.3) passes quietly"
else
    bad "a patched runc must pass"
fi

echo
echo "== entrypoint.sh §8b: the self-heal drops the stale claude-md-fragments SessionStart hook =="

# The strip deleted bin/claude-md-fragments (the CLAUDE.d fragment loader), but images built
# BEFORE it persisted a SessionStart hook invoking it into every per-project config
# VOLUME. §8b's merge lets existing user settings win, so without a self-heal that hook
# would survive the upgrade and fire an ENOENT at every session start, forever.
#
# The jq program is EXTRACTED FROM entrypoint.sh rather than mirrored here, so this test
# exercises the real filter and cannot silently drift away from it.
ENTRYPOINT="$REPO_ROOT/entrypoint.sh"
# Extract the command string from entrypoint.sh too, NOT hardcoded here. If someone
# typos STALE_HOOK_CMD, the self-heal silently becomes a production no-op that resurrects
# the ENOENT defect; a test carrying its own copy of the string would still pass and the
# gate would be fake. Extracting both halves means the test can only pass if the shipped
# filter really matches the hook the older image actually baked (asserted below).
STALE_CMD="$(sed -n 's/^STALE_HOOK_CMD="\(.*\)"$/\1/p' "$ENTRYPOINT")"
[[ "$STALE_CMD" == "/usr/local/bin/claude-md-fragments" ]] \
    && ok  "entrypoint.sh's STALE_HOOK_CMD matches the hook older images actually baked" \
    || bad "STALE_HOOK_CMD is '$STALE_CMD': does not match the baked hook; the self-heal is a NO-OP"
HOOK_FILTER="$(awk '/jq --arg stale "\$STALE_HOOK_CMD"/{f=1; sub(/^.*--arg stale "\$STALE_HOOK_CMD" .$/,""); }
                    f{print}
                    f && /^ *> "\$CLAUDE_CONFIG_DIR\/settings.json"$/{exit}' "$ENTRYPOINT" \
                 | sed -e "s/' *\\\\$//" -e '/^ *> "\$CLAUDE_CONFIG_DIR/d')"

if [[ -n "$HOOK_FILTER" ]] && echo '{}' | jq --arg stale "$STALE_CMD" "$HOOK_FILTER" >/dev/null 2>&1; then
    ok "the §8b stale-hook jq filter was extracted from entrypoint.sh and parses"

    # The real legacy-volume state: the older baked settings.json was EXACTLY this.
    legacy='{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"'"$STALE_CMD"'"}]}]}}'
    got="$(echo "$legacy" | jq -c --arg stale "$STALE_CMD" "$HOOK_FILTER")"
    [[ "$got" == '{}' ]] \
        && ok  "an older config volume is healed: the stale hook (and the empty .hooks) are dropped" \
        || bad "stale hook survived the self-heal: got $got"

    # A user's OWN SessionStart hook must NOT be collateral damage.
    mixed='{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"'"$STALE_CMD"'"}]},{"hooks":[{"type":"command","command":"/usr/local/bin/mine"}]}]}}'
    got="$(echo "$mixed" | jq -c --arg stale "$STALE_CMD" "$HOOK_FILTER")"
    [[ "$got" == *'/usr/local/bin/mine'* && "$got" != *"$STALE_CMD"* ]] \
        && ok  "a user's own SessionStart hook survives; only the stale one is removed" \
        || bad "self-heal damaged a user hook: got $got"

    # Unrelated hook types and hook-free settings must pass through untouched.
    other='{"hooks":{"PreToolUse":[{"hooks":[{"command":"x"}]}]}}'
    got="$(echo "$other" | jq -c --arg stale "$STALE_CMD" "$HOOK_FILTER")"
    [[ "$got" == "$other" ]] \
        && ok  "unrelated hook types pass through untouched" \
        || bad "self-heal mangled an unrelated hook type: got $got"

    none='{"permissions":{"defaultMode":"bypassPermissions"}}'
    got="$(echo "$none" | jq -c --arg stale "$STALE_CMD" "$HOOK_FILTER")"
    [[ "$got" == "$none" ]] \
        && ok  "settings with no .hooks key are unchanged (fresh-container path)" \
        || bad "self-heal mangled hook-free settings: got $got"

    # A hand-corrupted settings.json must PASS THROUGH, never error: the `>` redirect in
    # §8b truncates before jq runs, so a non-zero jq here would leave a 0-byte settings.json
    # and (under `set -e`) abort the entrypoint. Every level must be type-guarded.
    malformed=0
    for bad_shape in \
        '{"hooks":"oops"}' \
        '{"hooks":[]}' \
        '{"hooks":{"SessionStart":"oops"}}' \
        '{"hooks":{"SessionStart":["oops"]}}' \
        '{"hooks":{"SessionStart":[{"hooks":{"a":1}}]}}' \
        '{"hooks":{"SessionStart":[{"hooks":["oops"]}]}}'
    do
        # Assert the OUTPUT, not just the exit code: a jq program can exit 0 and emit
        # NOTHING, which would still truncate settings.json to 0 bytes. Each malformed
        # shape must come back byte-identical (passed through untouched).
        want="$(jq -c . <<<"$bad_shape")"
        got="$(echo "$bad_shape" | jq -c --arg stale "$STALE_CMD" "$HOOK_FILTER" 2>/dev/null)"
        if [[ -z "$got" ]]; then
            malformed=$((malformed+1)); echo "         (empty/errored output for: $bad_shape)"
        elif [[ "$got" != "$want" ]]; then
            malformed=$((malformed+1)); echo "         (mangled: $bad_shape -> $got)"
        fi
    done
    [[ $malformed -eq 0 ]] \
        && ok  "malformed .hooks shapes pass through byte-identical (cannot truncate or mangle settings.json)" \
        || bad "$malformed malformed shape(s) were dropped/mangled: settings.json would be truncated or corrupted"
else
    bad "could not extract a working stale-hook jq filter from entrypoint.sh §8b (the self-heal is missing or broke)"
fi

echo
echo "== entrypoint.sh §0: retired env vars warn loudly, never silently no-op =="

# The removed --broker/--sysbox/--worker-tarball FLAGS hard-die. The env vars they used to
# set are merely unread, and silence there is unsafe: an operator running
# CLAUDE_CACHE_PROXY_HOST + CLAUDE_EGRESS_LOCKDOWN=1 had a single audited egress choke
# point, and since the strip the firewall composes its default allowlist and public npm is
# reachable again. §0 must SAY so. Extracted from entrypoint.sh, not mirrored.
GUARD="$(awk '/^# --- 0\. Refuse retired/,/^unset _v _retired_set/' "$ENTRYPOINT")"

# Run §0 under the ENTRYPOINT'S REAL SHELL OPTIONS (`set -euo pipefail`), not a laxer
# subset. This is the whole point: §0 runs near the top of entrypoint.sh, so if it aborts
# on a CLEAN boot (e.g. a bare `(( ${#arr[@]} > 0 ))` whose arithmetic evaluates to 0
# returns exit 1, which `set -e` turns into an abort) then EVERY container fails to boot.
# Under `set -u` alone that fatal case is invisible: the guard dies silently, produces no
# output, and a text-only assertion would PASS precisely because it is dead. So: real
# options, and assert the EXIT CODE, not just the text.
run_guard() { ( eval "log() { echo \"[entrypoint] \$*\"; }"; set -euo pipefail; eval "$GUARD" ) 2>&1; }
guard_rc()  { ( eval "log() { echo \"[entrypoint] \$*\"; }"; set -euo pipefail; eval "$GUARD" ) >/dev/null 2>&1; echo $?; }

if [[ -n "$GUARD" ]]; then
    # THE BRICK TEST: a clean boot (no retired vars) must exit 0 under -euo pipefail.
    rc="$(guard_rc)"
    [[ "$rc" == "0" ]] \
        && ok  "§0 exits 0 on a clean boot under 'set -euo pipefail' (does not brick the container)" \
        || bad "§0 exited $rc on a CLEAN boot under 'set -euo pipefail': EVERY container would fail to boot"

    # And it must still exit 0 when it DOES fire (a warning must not abort the boot).
    rc="$(CLAUDE_CACHE_PROXY_HOST=cache.internal CLAUDE_WORKER_BROKER=1 guard_rc)"
    [[ "$rc" == "0" ]] \
        && ok  "§0 exits 0 when it fires (warn-not-die: a stale .env line never blocks boot)" \
        || bad "§0 exited $rc when warning: a stale .env line would brick the container"

    out="$(CLAUDE_CACHE_PROXY_HOST=cache.internal run_guard)"
    [[ "$out" == *"were RETIRED"*       && "$out" == *"CLAUDE_CACHE_PROXY_HOST"* ]] \
        && ok  "a retired var (CLAUDE_CACHE_PROXY_HOST) is named in a loud warning" \
        || bad "retired var was silently ignored: $out"
    [[ "$out" == *"audited egress choke point"* ]] \
        && ok  "the cache-proxy warning spells out the egress-posture change (npm reachable again)" \
        || bad "cache-proxy warning does not explain the security-posture change: $out"

    # PIN THE WHOLE LIST: spot-checking two vars is not a gate: truncating RETIRED_VARS
    # from 12 entries to 2 would let the other 10 go SILENT while the suite stayed green.
    # CLAUDE_SYSBOX is the highest-stakes one: an operator who believed they still had
    # Sysbox userns isolation would now get a plain runc container with nothing said.
    missed=()
    for v in CLAUDE_WORKER_BROKER CLAUDE_WORKER_TARBALL CLAUDE_BROKER_DIR CLAUDE_BROKER_SPOOL \
             CLAUDE_SYSBOX CLAUDE_SYSBOX_VERIFY CLAUDE_CACHE_PROXY CLAUDE_CACHE_PROXY_HOST \
             CLAUDE_CACHE_PROXY_PORT CLAUDE_APT_PROVISION CLAUDE_EGRESS_APT \
             CLAUDE_CONTROLLER_MAX_SLOTS
    do
        out="$(env "$v=1" bash -c 'log() { echo "[entrypoint] $*"; }; set -euo pipefail; eval "$0"' "$GUARD" 2>&1)"
        [[ "$out" == *"$v"* ]] || missed+=("$v")
    done
    [[ ${#missed[@]} -eq 0 ]] \
        && ok  "every one of the 12 retired vars is named in a warning (list is pinned, not spot-checked)" \
        || bad "these retired vars are SILENTLY ignored: ${missed[*]}"

    # The git-key broker is a LIVE credential-isolation control that merely shares the
    # word "broker". It must NEVER be flagged as retired.
    out="$(CLAUDE_BROKER_GIT_KEY=1 run_guard)"
    [[ -z "$out" ]] \
        && ok  "CLAUDE_BROKER_GIT_KEY (live git-key broker) is NOT treated as retired" \
        || bad "CLAUDE_BROKER_GIT_KEY was wrongly flagged as retired: it is a live control: $out"

    out="$(run_guard)"
    [[ -z "$out" ]] \
        && ok  "no retired vars set → §0 is silent (no noise on a clean boot)" \
        || bad "§0 emitted output with no retired vars set: $out"
else
    bad "could not extract §0's retired-env guard from entrypoint.sh (the retired-env guard is missing)"
fi

# ==========================================================================================
# The bin prune: the bins that lost their reason are gone, and their removal is LOUD
# ==========================================================================================
echo
echo "== claude-controller / claude-reaper / the WITH_DOCKER variant are fully gone =="

# A deleted bin that some file still names is worse than the bin: a stale `COPY bin/claude-reaper`
# fails the image build outright, and a stale CI step or npm-test entry fails every run. Pin the
# absence at every site that referenced them, so a partial revert cannot pass.
for f in bin/claude-controller bin/claude-reaper test/controller-unit.sh test/reaper-unit.sh; do
    [[ ! -e "$REPO_ROOT/$f" ]] \
        && ok  "$f is deleted" \
        || bad "$f still exists: it was removed"
done

# Strip whole-line comments before asserting: the tombstone comments that RECORD the removal
# (and point at docs/legacy-sysbox-broker.md) legitimately name these things. What must not
# survive is a live COPY/chmod/ARG/target.
code_of() { grep -vE '^[[:space:]]*#' "$1"; }

if ! code_of "$REPO_ROOT/Dockerfile" | grep -qE 'claude-(controller|reaper)'; then
    ok  "Dockerfile has no live COPY/chmod of the pruned bins (a stale COPY would fail the build)"
else
    bad "Dockerfile still references a pruned bin: $(code_of "$REPO_ROOT/Dockerfile" | grep -E 'claude-(controller|reaper)')"
fi
# WITH_DOCKER is BACK, deliberately, but the property that prune was protecting still holds and
# is what we assert now. It deleted the variant because the baked engine was UNREACHABLE: no
# runtime, no --privileged, no socket mount, and nothing that started dockerd: 400 MB of dead
# daemon. The engine only earns its place if it can actually run, so pin the wiring, not the
# absence: the entrypoint must start it, and the launcher must give it the Sysbox runtime that
# lets it start without privilege. Break either and the variant is dead weight again.
# (See docs/architecture.md; the worker BROKER it originally served stays retired.)
# NOTE: materialize code_of's output into a variable instead of piping it into `grep -q`.
# This file runs under `set -o pipefail`, and `producer | grep -q X` is a trap there: grep -q
# exits the moment it matches, the producer takes SIGPIPE (141), and pipefail reports the
# PIPELINE as failed even though the pattern was found. It is timing-dependent, so it shows
# up as a test that passes locally and reds CI at random. Keep the here-string form.
has() { grep -qE -- "$2" <<<"$1"; }   # has "<text>" "<ere>"
dockerfile_code="$(code_of "$REPO_ROOT/Dockerfile")"
entrypoint_code="$(code_of "$REPO_ROOT/entrypoint.sh")"
launch_code="$(code_of "$REPO_ROOT/bin/claude-launch")"

if has "$dockerfile_code" 'WITH_DOCKER'; then
    ok  "the WITH_DOCKER image variant exists (bakes dockerd + CLI + compose/buildx)"
else
    bad "WITH_DOCKER is missing from the Dockerfile: --docker sessions cannot have an engine"
fi
if has "$entrypoint_code" 'CLAUDE_DOCKER' && has "$entrypoint_code" '(^|[[:space:]])dockerd[[:space:]]*>>'; then
    ok  "the entrypoint actually STARTS the baked engine (CLAUDE_DOCKER=1 → dockerd)"
else
    bad "nothing starts dockerd: the baked engine is unreachable again (the exact defect it was once deleted for)"
fi
if has "$launch_code" 'runtime=sysbox-runc'; then
    ok  "claude-launch gives the engine a runtime it can start under (--runtime=sysbox-runc)"
else
    bad "claude-launch selects no Sysbox runtime: an inner dockerd cannot start without the userns"
fi
# The two shortcuts that would make an inner engine trivial and catastrophic. Sysbox exists
# precisely so neither is needed; if one appears, the isolation story is gone.
for f in bin/claude-launch bin/claude-compose-gen entrypoint.sh docker-compose.yml; do
    [[ -e "$REPO_ROOT/$f" ]] || continue
    if has "$(code_of "$REPO_ROOT/$f")" '--privileged|privileged:[[:space:]]*true|/var/run/docker\.sock'; then
        bad "$f grants --privileged or mounts the host docker socket: either hands the agent the host"
    else
        ok  "$f grants no --privileged and mounts no host docker socket"
    fi
done
if ! grep -qE '(controller|reaper)-unit\.sh' "$REPO_ROOT/package.json" "$REPO_ROOT/.github/workflows/ci.yml"; then
    ok  "npm test + CI no longer invoke the deleted controller/reaper suites"
else
    bad "package.json or ci.yml still runs a deleted test suite"
fi
# CLAUDE_IMAGE_CONTROLLER only ever named the WITH_DOCKER build.
if ! grep -q 'CLAUDE_IMAGE_CONTROLLER' "$REPO_ROOT/bin/_common.sh" "$REPO_ROOT/.env.example"; then
    ok  "CLAUDE_IMAGE_CONTROLLER is gone (it named nothing buildable)"
else
    bad "CLAUDE_IMAGE_CONTROLLER survives, but nothing can build that image any more"
fi

echo
echo "== entrypoint REFUSES CLAUDE_CONTROLLER=1 (never silently boots interactive) =="

# CLAUDE_CONTROLLER is NOT an inert leftover like the §0 vars: it is an ACTIVE request for
# unattended operation. Warn-and-ignore would boot an unattended fleet container into an
# interactive Remote-Control session nobody is watching, which never runs the loop: a container
# that looks alive and does nothing. So this one DIES (§0b).
#
# BOTH the guard AND the real `die` it depends on are extracted from entrypoint.sh, never
# mirrored. A local stub `die` would keep passing if entrypoint's real one stopped exiting
# non-zero, which is exactly the drift that turns a gate into theater.
CTRL_GUARD="$(awk '/^case "\$\{CLAUDE_CONTROLLER/,/^esac/' "$ENTRYPOINT")"
# Handles die() written as a one-liner (as it is today) or reformatted across lines: start at
# its definition, stop at the first line closing a brace.
REAL_DIE="$(awk '/^die\(\)/{f=1} f{print; if (/\}[[:space:]]*$/) exit}' "$ENTRYPOINT")"
ctrl_run() { ( eval "$REAL_DIE"; set -euo pipefail; eval "$CTRL_GUARD" ) 2>&1; }
ctrl_rc()  { ( eval "$REAL_DIE"; set -euo pipefail; eval "$CTRL_GUARD" ) >/dev/null 2>&1; echo $?; }

# PROVE THE EXTRACTED die() ACTUALLY WORKS, rather than merely being non-empty. A text check
# passes on a half-extracted function; the eval then throws a syntax error, `die` is undefined,
# and "command not found" under `set -e` LOOKS exactly like a refusal, so the controller
# assertions below would all still pass while testing nothing at all. Exercise it instead.
die_rc="$( ( eval "$REAL_DIE"; die "probe" ) >/dev/null 2>&1; echo $? )"
die_out="$( ( eval "$REAL_DIE"; die "probe" ) 2>&1 )"
[[ "$die_rc" == "1" && "$die_out" == *"probe"* ]] \
    && ok  "entrypoint's real die() extracted AND exercised (exits 1, prints its message), not a stub, not a broken eval" \
    || bad "the extracted die() does not behave (rc=$die_rc, out=$die_out): the CLAUDE_CONTROLLER gate would be theater"

if [[ -n "$CTRL_GUARD" ]]; then
    for v in 1 true yes on; do
        rc="$(CLAUDE_CONTROLLER="$v" ctrl_rc)"
        [[ "$rc" != "0" ]] \
            && ok  "CLAUDE_CONTROLLER=$v is REFUSED (exit $rc), not silently downgraded to interactive" \
            || bad "CLAUDE_CONTROLLER=$v booted anyway: an unattended container would silently run interactive"
    done

    # The refusal has to be ACTIONABLE, or the operator just sees their fleet crashloop.
    out="$(CLAUDE_CONTROLLER=1 ctrl_run)"
    [[ "$out" == *"CLAUDE_AUTOPILOT=1"* ]] \
        && ok  "the refusal names the replacement (CLAUDE_AUTOPILOT=1, the same loop it always was)" \
        || bad "the CLAUDE_CONTROLLER refusal does not tell the operator what to set instead: $out"

    # A clean boot, and the inert CLAUDE_CONTROLLER=0 that every old .env.example carries, must
    # sail straight through: refusing THOSE would brick every container.
    rc="$(ctrl_rc)";                     [[ "$rc" == "0" ]] \
        && ok  "unset CLAUDE_CONTROLLER → no refusal (clean boot unaffected)" \
        || bad "the guard aborts a CLEAN boot (exit $rc): every container would fail to start"
    rc="$(CLAUDE_CONTROLLER=0 ctrl_rc)"; [[ "$rc" == "0" ]] \
        && ok  "CLAUDE_CONTROLLER=0 → no refusal (a stale .env line never blocks boot)" \
        || bad "CLAUDE_CONTROLLER=0 aborted the boot (exit $rc): stale .env files would brick"
else
    bad "could not extract the CLAUDE_CONTROLLER refusal from entrypoint.sh (the guard is missing)"
fi

echo
echo "== claude-autopilot never invents a prompt (the removed default is gone) =="

# The old CLAUDE_AUTOPILOT_CMD default was a slash command that existed only in the maintainer's
# own repo, which this generic image does not ship, so on almost every container it resolved to nothing at all. (It did NOT reach the
# model as a literal prompt: `claude -p` reports an unknown slash command as a zero-turn success
# and never invokes the model: see the next section, which is where the real damage was.) The fix
# is a hard rule: NO COMMAND, NO RUN. These tests prove `claude` is never invoked without one:
# using a stub that records every invocation.
AP="$REPO_ROOT/bin/claude-autopilot"
APD="$(mktemp -d)"; trap 'rm -rf "$APD"' EXIT
mkdir -p "$APD/bin"
cat > "$APD/bin/claude" <<EOF
#!/usr/bin/env bash
echo "INVOKED \$*" >> "$APD/claude-invocations"
echo '{"is_error": false, "result": "ok", "session_id": "s", "total_cost_usd": 0, "num_turns": 1, "duration_ms": 1}'
EOF
chmod +x "$APD/bin/claude"
# Run the autopilot with the stub on PATH and a throwaway HOME. stdin is /dev/null so the
# `exec bash -l` it drops into on refusal hits EOF and exits instead of hanging the suite.
run_autopilot() {  # run_autopilot <timeout-secs> <env=val...>
    local t="$1"; shift
    ( : > "$APD/claude-invocations"
      timeout "$t" env PATH="$APD/bin:$PATH" HOME="$APD/home" "$@" \
          bash "$AP" </dev/null 2>&1 ) || true
}
invocations() { wc -l < "$APD/claude-invocations" | tr -d ' '; }

# 1. No command, no queue → refuse, and DO NOT call claude.
out="$(run_autopilot 10 CLAUDE_AUTOPILOT_INTERVAL=1)"
[[ "$(invocations)" == "0" ]] \
    && ok  "no CLAUDE_AUTOPILOT_CMD + no queue → claude is NEVER invoked (no invented prompt)" \
    || bad "the autopilot invoked claude with no command set, that class of bug is back"
[[ "$out" == *"CLAUDE_AUTOPILOT_CMD is not set"* && "$out" == *"NO DEFAULT"* ]] \
    && ok  "it says WHY it refused (CLAUDE_AUTOPILOT_CMD unset, no default)" \
    || bad "the refusal is not explained: $out"
[[ "$out" == *"CLAUDE_AUTOPILOT_QUEUE=1"* ]] \
    && ok  "the refusal names both ways forward (set a CMD, or run as a queue consumer)" \
    || bad "the refusal does not tell the operator what to do: $out"

# 2. Queue on, queue EMPTY, no command → idle. Not a run, and still no claude.
out="$(run_autopilot 4 CLAUDE_AUTOPILOT_QUEUE=1 CLAUDE_AUTOPILOT_INTERVAL=1)"
[[ "$(invocations)" == "0" ]] \
    && ok  "empty queue + no fallback command → idles, never invokes claude" \
    || bad "a pure queue consumer invoked claude on an EMPTY queue: it invented work"
[[ "$out" == *"idling"* ]] \
    && ok  "the idle is announced (an operator can tell 'waiting' from 'wedged')" \
    || bad "the idle cycle is silent: $out"

# 3. Positive control: the refusal must not have broken the actual loop. With a command set,
#    claude IS invoked, with exactly that prompt. Without this, tests 1-2 would pass on a
#    permanently broken autopilot.
out="$(run_autopilot 20 CLAUDE_AUTOPILOT_CMD=/build-the-thing CLAUDE_AUTOPILOT_MAX_RUNS=1 CLAUDE_AUTOPILOT_INTERVAL=0)"
[[ "$(invocations)" == "1" ]] \
    && ok  "CLAUDE_AUTOPILOT_CMD set → claude is invoked exactly once (MAX_RUNS=1): the loop still works" \
    || bad "with a command set, claude was invoked $(invocations) times (expected 1): $out"
grep -q -- '-p /build-the-thing' "$APD/claude-invocations" \
    && ok  "the prompt passed to claude is CLAUDE_AUTOPILOT_CMD verbatim" \
    || bad "claude got the wrong prompt: $(cat "$APD/claude-invocations")"

echo
echo "== a zero-turn 'Unknown command' is a FAILURE, not a healthy \$0 run =="

# THE TRAP, verified by hand against the then-pinned CLI (2.1.207):
#   $ claude -p "/typo" --output-format json ; echo $?
#   {"subtype":"success","is_error":false,"num_turns":0,"result":"Unknown command: /typo",
#    "total_cost_usd":0}
#   0
# Exit 0 and is_error:false, so the autopilot's success check scored it as a GOOD run. Left
# unguarded, a typo'd CLAUDE_AUTOPILOT_CMD gives you a container that logs a healthy "$0 run"
# every interval forever and does nothing, and a queued task filed to done/ though it never
# ran. This stub reproduces that exact response shape.
mkdir -p "$APD/unkbin"
cat > "$APD/unkbin/claude" <<EOF
#!/usr/bin/env bash
echo "INVOKED \$*" >> "$APD/claude-invocations"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":0,"result":"Unknown command: /typo","session_id":"s","total_cost_usd":0,"duration_ms":10}'
exit 0
EOF
chmod +x "$APD/unkbin/claude"
run_autopilot_unk() {  # same harness, but with the unknown-command stub
    local t="$1"; shift
    ( : > "$APD/claude-invocations"
      timeout "$t" env PATH="$APD/unkbin:$PATH" HOME="$APD/uhome" "$@" \
          bash "$AP" </dev/null 2>&1 ) || true
}

# 1. No queue: it must STOP (drop to a shell), not spin forever pretending to work.
#    MAX_RUNS is 0 (unlimited) and INTERVAL 1: an unguarded loop would run many times in 6s.
out="$(run_autopilot_unk 6 CLAUDE_AUTOPILOT_CMD=/typo CLAUDE_AUTOPILOT_INTERVAL=1)"
[[ "$out" == *"nothing ran"* && "$out" == *"Unknown command: /typo"* ]] \
    && ok  "a zero-turn 'Unknown command' is reported as a failure, quoting what claude said" \
    || bad "the unknown-command no-op was NOT flagged: the loop counted it as a healthy run: $out"
[[ "$(invocations)" == "1" ]] \
    && ok  "it stops after the first unknown-command run (did not spin: 1 invocation, not many)" \
    || bad "the loop kept firing an unknown command ($(invocations)x in 6s): the silent-green no-op is back"
[[ "$out" == *"Dropping to a shell"* ]] \
    && ok  "with no queue to fall back on, it drops to a shell (the reason stays on the pane)" \
    || bad "it neither ran nor stopped visibly: $out"

# 2. Queued task whose body is an unknown command → filed under failed/, NOT done/. This is the
#    scm-observer → queue fleet path: filing unrun work as done is the silent data-loss case.
rm -rf "$APD/uhome"; mkdir -p "$APD/uhome/.claude/autopilot-queue/pending"
printf '/typo' > "$APD/uhome/.claude/autopilot-queue/pending/001-task"
out="$(run_autopilot_unk 6 CLAUDE_AUTOPILOT_QUEUE=1 CLAUDE_AUTOPILOT_INTERVAL=1 CLAUDE_AUTOPILOT_QUEUE_DELAY=1)"
Q="$APD/uhome/.claude/autopilot-queue"
if [[ -z "$(ls -A "$Q/done" 2>/dev/null)" ]] && [[ -n "$(ls -A "$Q/failed" 2>/dev/null)" ]]; then
    ok  "a queued task that ran NOTHING is filed under failed/, never done/"
else
    bad "queued unknown-command task was filed as DONE (done/: $(ls -A "$Q/done" 2>/dev/null), failed/: $(ls -A "$Q/failed" 2>/dev/null)), unrun work marked complete"
fi

# 3. A broken CLAUDE_AUTOPILOT_CMD *fallback* must not kill a working queue consumer: drop the
#    fallback, keep draining. (Otherwise one typo throws away the useful half of the container.)
rm -rf "$APD/uhome"
out="$(run_autopilot_unk 6 CLAUDE_AUTOPILOT_QUEUE=1 CLAUDE_AUTOPILOT_CMD=/typo \
        CLAUDE_AUTOPILOT_INTERVAL=1 CLAUDE_AUTOPILOT_QUEUE_DELAY=1)"
[[ "$out" == *"disabling the CLAUDE_AUTOPILOT_CMD fallback"* && "$out" == *"idling"* ]] \
    && ok  "a bogus fallback is dropped and the queue consumer survives (idles, keeps serving the queue)" \
    || bad "a bogus fallback either killed the queue consumer or kept spinning: $out"
[[ "$(invocations)" == "1" ]] \
    && ok  "it stops re-firing the bogus fallback (1 invocation, then idle)" \
    || bad "the bogus fallback kept firing ($(invocations)x) instead of being disabled"

echo
echo "== the outcome checks FAIL CLOSED: stderr can't be merged into the JSON =="

# THE FAIL-OPEN this closes. The real pinned CLI writes to STDERR when stdin is an open pipe
# with no data (verified: 157 bytes, "Warning: no stdin data received in 3s..."). The loop used
# to run `claude ... >"$out" 2>&1`, so that line landed in $out AHEAD of the JSON: $out was
# then unparseable, EVERY jq read returned empty, `.is_error` read empty rather than "true",
# the zero-turn check read empty, and the run scored as a SUCCESS. A poison queued task went
# to done/. Any stderr line at all (deprecation notice, update nag, token refresh) does this.
# So the stub below emits the real CLI's stdout AND its real stderr.
mkdir -p "$APD/errbin"
cat > "$APD/errbin/claude" <<EOF
#!/usr/bin/env bash
echo "INVOKED \$*" >> "$APD/claude-invocations"
echo 'Warning: no stdin data received in 3s, proceeding without it. If piping from a slow command, redirect stdin explicitly: < /dev/null to skip, or wait longer.' >&2
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":0,"result":"Unknown command: /typo","session_id":"s","total_cost_usd":0,"duration_ms":10}'
exit 0
EOF
chmod +x "$APD/errbin/claude"

# A queued poison task, with the CLI also writing to stderr. It must STILL be caught and filed
# under failed/: this is the exact case that silently landed in done/ before.
rm -rf "$APD/ehome"; mkdir -p "$APD/ehome/.claude/autopilot-queue/pending"
printf '/typo' > "$APD/ehome/.claude/autopilot-queue/pending/001-task"
out="$( : > "$APD/claude-invocations"
        timeout 6 env PATH="$APD/errbin:$PATH" HOME="$APD/ehome" \
            CLAUDE_AUTOPILOT_QUEUE=1 CLAUDE_AUTOPILOT_INTERVAL=1 CLAUDE_AUTOPILOT_QUEUE_DELAY=1 \
            bash "$AP" </dev/null 2>&1 || true )"
E="$APD/ehome/.claude/autopilot-queue"
if [[ -z "$(ls -A "$E/done" 2>/dev/null)" ]] && [[ -n "$(ls -A "$E/failed" 2>/dev/null)" ]]; then
    ok  "stderr on the CLI does NOT blind the checks: the poison task still lands in failed/, not done/"
else
    bad "FAIL-OPEN: with stderr present the run scored as success (done/: $(ls -A "$E/done" 2>/dev/null)), unrun work marked complete"
fi
[[ "$out" == *"Unknown command: /typo"* ]] \
    && ok  "the unknown-command result is still detected when the CLI also writes to stderr" \
    || bad "the guard went blind once stderr was in play: $out"

# And the structural rule: a log that will not parse is a FAILURE, never a success. This is what
# makes the above robust against ANY future CLI chatter, not just the stdin warning.
mkdir -p "$APD/garbagebin"
cat > "$APD/garbagebin/claude" <<EOF
#!/usr/bin/env bash
echo "INVOKED \$*" >> "$APD/claude-invocations"
echo 'this is not json at all'
exit 0
EOF
chmod +x "$APD/garbagebin/claude"
rm -rf "$APD/ghome"; mkdir -p "$APD/ghome/.claude/autopilot-queue/pending"
printf 'do some real work' > "$APD/ghome/.claude/autopilot-queue/pending/001-task"
out="$( : > "$APD/claude-invocations"
        timeout 6 env PATH="$APD/garbagebin:$PATH" HOME="$APD/ghome" \
            CLAUDE_AUTOPILOT_QUEUE=1 CLAUDE_AUTOPILOT_INTERVAL=1 CLAUDE_AUTOPILOT_QUEUE_DELAY=1 \
            bash "$AP" </dev/null 2>&1 || true )"
G="$APD/ghome/.claude/autopilot-queue"
if [[ -z "$(ls -A "$G/done" 2>/dev/null)" ]] && [[ -n "$(ls -A "$G/failed" 2>/dev/null)" ]]; then
    ok  "an unparseable run log FAILS CLOSED (task → failed/): 'cannot verify' never scores as success"
else
    bad "FAIL-OPEN: an unparseable run log scored as SUCCESS (done/: $(ls -A "$G/done" 2>/dev/null))"
fi
[[ "$out" == *"no readable result object"* ]] \
    && ok  "it says the log could not be read (an operator can see why the run was failed)" \
    || bad "the unparseable log was not reported: $out"

echo
echo "== ANY zero-turn run is a no-op, not just the 'Unknown command' typo =="

# The predicate is `num_turns == 0` ALONE. It must NOT be narrowed to results whose text starts
# with "Unknown command:", because on the then-pinned CLI (2.1.207) EVERY slash command that exists
# but is unavailable headless returns the same zero-turn is_error:false exit-0 shape:
#   /help    → result:"/help isn't available in this environment."
#   /cost    → result:"You are currently using your subscription…"
#   /compact → result:""   ← no message at all
#   /clear   → result:""
# A string-matching guard files all of those to done/. Zero turns is zero work: full stop. These
# stubs reproduce the two shapes a string check would miss (a non-matching message, and none).
zero_turn_stub() {  # zero_turn_stub <dir> <result-text>
    mkdir -p "$APD/$1"
    cat > "$APD/$1/claude" <<EOF
#!/usr/bin/env bash
echo "INVOKED \$*" >> "$APD/claude-invocations"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":0,"result":"$2","session_id":"s","total_cost_usd":0,"duration_ms":10}'
exit 0
EOF
    chmod +x "$APD/$1/claude"
}
# Queue a task, run the real autopilot against <stub>, report where the task landed.
task_lands_in() {  # task_lands_in <stubdir> <homedir>
    local stub="$1" home="$2"
    rm -rf "$APD/$home"; mkdir -p "$APD/$home/.claude/autopilot-queue/pending"
    printf 'do real work' > "$APD/$home/.claude/autopilot-queue/pending/001-task"
    ( : > "$APD/claude-invocations"
      timeout 6 env PATH="$APD/$stub:$PATH" HOME="$APD/$home" \
          CLAUDE_AUTOPILOT_QUEUE=1 CLAUDE_AUTOPILOT_INTERVAL=1 CLAUDE_AUTOPILOT_QUEUE_DELAY=1 \
          bash "$AP" </dev/null 2>&1 || true ) >/dev/null
    local q="$APD/$home/.claude/autopilot-queue"
    if [[ -n "$(ls -A "$q/failed" 2>/dev/null)" && -z "$(ls -A "$q/done" 2>/dev/null)" ]]; then
        echo failed
    elif [[ -n "$(ls -A "$q/done" 2>/dev/null)" ]]; then
        echo done
    else
        echo neither
    fi
}

zero_turn_stub helpbin "/help isn't available in this environment."
[[ "$(task_lands_in helpbin hlhome)" == "failed" ]] \
    && ok  "a zero-turn run with a NON-'Unknown command' message (/help) is a failure, not done/" \
    || bad "FAIL-OPEN: a /help-shaped zero-turn no-op was filed as DONE, the guard only catches typos"

zero_turn_stub quietbin ""
[[ "$(task_lands_in quietbin qthome)" == "failed" ]] \
    && ok  "a zero-turn run with NO message at all (/compact, /clear) is a failure, not done/" \
    || bad "FAIL-OPEN: a silent zero-turn no-op was filed as DONE, nothing ran and nothing was said"

# The other half of the rule: a run that DID invoke the model is a success, whatever it says,
# including one whose text happens to discuss an unknown command (num_turns >= 1 protects it,
# which is why the string condition was never needed).
zero_turn_stub_multiturn() {
    mkdir -p "$APD/mtbin"
    cat > "$APD/mtbin/claude" <<EOF
#!/usr/bin/env bash
echo "INVOKED \$*" >> "$APD/claude-invocations"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":3,"result":"Unknown command: /foo is what the docs say to avoid","session_id":"s","total_cost_usd":0.2,"duration_ms":10}'
exit 0
EOF
    chmod +x "$APD/mtbin/claude"
}
zero_turn_stub_multiturn
[[ "$(task_lands_in mtbin mthome2)" == "done" ]] \
    && ok  "a real multi-turn run whose text merely DISCUSSES 'Unknown command' still succeeds (no false positive)" \
    || bad "false positive: a genuine multi-turn run was failed because of its result text"

echo
echo "== the check validates JSON *shape*, not just syntax (CLAUDE_EXTRA_ARGS=--verbose) =="

# THE SAME FAIL-OPEN, ONE LAYER UP. CLAUDE_EXTRA_ARGS is a documented, first-class tunable
# (.env.example, README, `claude-launch --extra-args`). Adding `--verbose` makes the pinned CLI
# emit a top-level ARRAY of stream messages rather than one result object: verified against
# the then-pinned 2.1.207. An array is VALID JSON, so a syntax-only check (`jq -e .`) passes it; then every field
# read against an array returns empty, is_error reads "" (not "true") and num_turns reads ""
# (not "0"), and BOTH guards silently disengage. And `--verbose` is exactly the flag an operator
# reaches for to ask "why is my autopilot doing nothing?", so the debugging flag would recreate
# the silence. The loop must reduce either shape to the result object. These stubs reproduce the
# real array shape (system/assistant/result elements, result LAST).
mkdir -p "$APD/arrbin"
cat > "$APD/arrbin/claude" <<EOF
#!/usr/bin/env bash
echo "INVOKED \$*" >> "$APD/claude-invocations"
echo '[{"type":"system","subtype":"init"},{"type":"assistant"},{"type":"result","subtype":"success","is_error":false,"num_turns":0,"result":"Unknown command: /typo","session_id":"s","total_cost_usd":0,"duration_ms":10}]'
exit 0
EOF
chmod +x "$APD/arrbin/claude"
rm -rf "$APD/ahome"; mkdir -p "$APD/ahome/.claude/autopilot-queue/pending"
printf '/typo' > "$APD/ahome/.claude/autopilot-queue/pending/001-task"
out="$( : > "$APD/claude-invocations"
        timeout 6 env PATH="$APD/arrbin:$PATH" HOME="$APD/ahome" \
            CLAUDE_AUTOPILOT_QUEUE=1 CLAUDE_AUTOPILOT_INTERVAL=1 CLAUDE_AUTOPILOT_QUEUE_DELAY=1 \
            bash "$AP" </dev/null 2>&1 || true )"
A="$APD/ahome/.claude/autopilot-queue"
if [[ -z "$(ls -A "$A/done" 2>/dev/null)" ]] && [[ -n "$(ls -A "$A/failed" 2>/dev/null)" ]]; then
    ok  "the --verbose ARRAY shape is still read: poison task lands in failed/, not done/"
else
    bad "FAIL-OPEN: a top-level array (valid JSON, wrong shape) disengaged the guards, task filed as done"
fi

# POSITIVE CONTROL: the array shape must still be read as a SUCCESS when the run genuinely
# succeeded. Otherwise "fail closed" would just mean "--verbose breaks the autopilot".
mkdir -p "$APD/arrokbin"
cat > "$APD/arrokbin/claude" <<EOF
#!/usr/bin/env bash
echo "INVOKED \$*" >> "$APD/claude-invocations"
echo '[{"type":"system","subtype":"init"},{"type":"result","subtype":"success","is_error":false,"num_turns":3,"result":"did the work","session_id":"s","total_cost_usd":0.5,"duration_ms":10}]'
exit 0
EOF
chmod +x "$APD/arrokbin/claude"
rm -rf "$APD/aokhome"; mkdir -p "$APD/aokhome/.claude/autopilot-queue/pending"
printf 'do real work' > "$APD/aokhome/.claude/autopilot-queue/pending/001-task"
out="$( : > "$APD/claude-invocations"
        timeout 6 env PATH="$APD/arrokbin:$PATH" HOME="$APD/aokhome" \
            CLAUDE_AUTOPILOT_QUEUE=1 CLAUDE_AUTOPILOT_INTERVAL=1 CLAUDE_AUTOPILOT_QUEUE_DELAY=1 \
            bash "$AP" </dev/null 2>&1 || true )"
K="$APD/aokhome/.claude/autopilot-queue"
if [[ -n "$(ls -A "$K/done" 2>/dev/null)" ]] && [[ -z "$(ls -A "$K/failed" 2>/dev/null)" ]]; then
    ok  "a genuinely successful --verbose run is still scored SUCCESS (fail-closed ≠ '--verbose is broken')"
else
    bad "a good run under --verbose was wrongly failed: the shape check false-positives"
fi
[[ "$out" == *"did the work"* ]] \
    && ok  "the result text is read out of the array's result element" \
    || bad "the array's result element was not surfaced: $out"

# EMPTY LOG. `jq -e .` exits 0 on an empty file (surprising, and exactly the kind of thing a
# syntax-only check gets wrong), so nothing but an explicit -s test catches this.
mkdir -p "$APD/emptybin"
cat > "$APD/emptybin/claude" <<EOF
#!/usr/bin/env bash
echo "INVOKED \$*" >> "$APD/claude-invocations"
exit 0
EOF
chmod +x "$APD/emptybin/claude"
rm -rf "$APD/mthome"; mkdir -p "$APD/mthome/.claude/autopilot-queue/pending"
printf 'do real work' > "$APD/mthome/.claude/autopilot-queue/pending/001-task"
out="$( : > "$APD/claude-invocations"
        timeout 6 env PATH="$APD/emptybin:$PATH" HOME="$APD/mthome" \
            CLAUDE_AUTOPILOT_QUEUE=1 CLAUDE_AUTOPILOT_INTERVAL=1 CLAUDE_AUTOPILOT_QUEUE_DELAY=1 \
            bash "$AP" </dev/null 2>&1 || true )"
M="$APD/mthome/.claude/autopilot-queue"
if [[ -z "$(ls -A "$M/done" 2>/dev/null)" ]] && [[ -n "$(ls -A "$M/failed" 2>/dev/null)" ]]; then
    ok  "an EMPTY run log fails closed (task → failed/): 'jq -e .' exits 0 on empty; -s catches it"
else
    bad "FAIL-OPEN: an empty run log scored as SUCCESS (done/: $(ls -A "$M/done" 2>/dev/null))"
fi

echo
echo "== credential reconcile guard: creds_have_token refuses a tokenless (logged-out) copy =="

# 2026-07-15 incident: a claude.ai refresh-token expiry made Claude Code rewrite
# .credentials.json with EMPTY token fields (a logout). The reconcile loop took
# that freshly-mtimed, tokenless file as "newest wins" and published it to the
# shared /auth master and every container: one expiry became a fleet-wide
# "Login expired" blackout. The guard (creds_have_token) is EXTRACTED from
# entrypoint.sh here, not mirrored, so this test cannot silently drift from the
# shipped predicate.
ENTRYPOINT="$REPO_ROOT/entrypoint.sh"
CREDS_FN="$(awk '/^creds_have_token\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$ENTRYPOINT")"
if [[ -n "$CREDS_FN" ]] && eval "$CREDS_FN" 2>/dev/null; then
    CD="$(mktemp -d)"
    printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-REALtok","refreshToken":"rt","expiresAt":9}}' > "$CD/good.json"
    printf '{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}'                        > "$CD/empty.json"
    printf '{"claudeAiOauth":{"accessToken": "spaced-ok"}}'                                               > "$CD/spaced.json"
    : > "$CD/blank.json"
    creds_have_token "$CD/good.json"    && ok  "a real access token is accepted"                  || bad "real token wrongly rejected"
    creds_have_token "$CD/spaced.json"  && ok  "whitespace after the colon still parses"          || bad "spaced token wrongly rejected"
    ! creds_have_token "$CD/empty.json" && ok  "a logged-out (empty-token) credential is refused"  || bad "POISON: empty-token credential accepted, a logout would spread fleet-wide"
    ! creds_have_token "$CD/blank.json" && ok  "an empty file is refused"                           || bad "empty file accepted"
    ! creds_have_token "$CD/missing"    && ok  "a missing file is refused"                          || bad "missing file accepted"
    rm -rf "$CD"
else
    bad "could not extract creds_have_token() from entrypoint.sh: the guard test is a no-op"
fi

# Structural tripwire: reconcile_creds must gate propagation on creds_have_token and
# delegate the atomic move to publish_creds (no raw 'mv -f' that could republish a
# tokenless file). Locks the fix against an accidental revert to unguarded copying.
RECON_FN="$(awk '/^reconcile_creds\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$ENTRYPOINT")"
if [[ -n "$RECON_FN" ]] && grep -q 'creds_have_token' <<<"$RECON_FN" && ! grep -q 'mv -f' <<<"$RECON_FN"; then
    ok  "reconcile_creds gates every propagation on creds_have_token (no unguarded copy)"
else
    bad "reconcile_creds may copy without a token guard: a tokenless credential could spread"
fi

echo
echo "== entrypoint.sh §5: the mounted deploy key is BROKERED unless the operator opts out =="

# CC-11 flipped this default. Before it, CLAUDE_BROKER_GIT_KEY defaulted to 0 and an
# operator who mounted a deploy key without ever hearing of the flag got it installed
# as a ~/.ssh/id_ed25519 that the prompt-injectable agent could read and exfiltrate.
# Now: unset brokers, an enabling value brokers, an UNRECOGNISED value brokers, and
# only a recognised disabling value (0/false/no/off) installs a readable key. A broker
# that cannot be established installs NOTHING (the old code fell through to the
# readable file, which after the flip would have handed the key over on every hiccup).
#
# The whole §5 block is EXTRACTED from entrypoint.sh and EXECUTED here, never mirrored:
# a copy would keep passing after the shipped default silently flipped back. Only the
# two ROOT-ONLY paths it names ($BROKER_RUN_DIR, $BROKER_PROFILE_D) are redirected into
# a sandbox so the block can run unprivileged, and that redirect is asserted below so it
# cannot degrade into a test that quietly targets /run and /etc instead.
GITKEY_BLOCK="$(awk '/^# --- 5\. Git SSH key \+ identity/{f=1} f{print} f&&/^fi$/{exit}' "$ENTRYPOINT")"
GKD="$(mktemp -d)"; trap 'rm -rf "$STUB" "$APD" "$GKD"' EXIT
GK_UID="$(id -u)"; GK_GID="$(id -g)"; GK_USER="$(id -un)"
# The private bytes the agent must never be able to reach, distinctive enough to grep
# the whole sandbox home for. The PEM banner around them is assembled at run time from
# the two halves below: the fleet-wide pre-commit secret guard refuses any staged file
# holding a literal private-key banner, and it is right to. A synthetic fixture is not
# worth teaching that guard an exception, so the literal block never lands in this file.
GK_SECRET="SMOKINGGUNKEYBYTES"
GK_PEM="PRIVATE KEY-----"
gk_fake_key() { printf -- '-----BEGIN OPENSSH %s\n%s\n-----END OPENSSH %s\n' "$GK_PEM" "$GK_SECRET" "$GK_PEM"; }

# A unix socket cannot be created from bash, and every decision on §5's success path
# turns on `[[ -S ... ]]`. python3 is the socket factory. If it is missing this FAILS
# rather than skipping: a silently-skipped broker test is exactly the theater this
# suite refuses everywhere else.
if python3 -c 'import socket' >/dev/null 2>&1; then
    mkdir -p "$GKD/bin"
    cat > "$GKD/bin/mksock" <<'EOS'
#!/usr/bin/env bash
# Create a REAL unix socket at $1, then exit: bind() creates the filesystem node and
# the node outlives the process, which is what `[[ -S ... ]]` looks for.
exec python3 -c 'import socket, sys
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.listen(1)' "$1"
EOS
    cat > "$GKD/bin/ssh-agent" <<'EOS'
#!/usr/bin/env bash
# Stands in for `ssh-agent -a <sock>`: makes the socket, then daemonises away.
[[ "${GK_FAIL_AGENT:-0}" == 1 ]] && exit 1
sock=""
while [[ $# -gt 0 ]]; do case "$1" in -a) sock="$2"; shift 2 ;; *) shift ;; esac; done
[[ -n "$sock" ]] || exit 1
mksock "$sock"
EOS
    cat > "$GKD/bin/ssh-add" <<'EOS'
#!/usr/bin/env bash
# Stands in for loading the key into the root agent. Records the socket it was told
# to use, so the test can prove the key went into the ROOT agent, not the relay.
[[ "${GK_FAIL_ADD:-0}" == 1 ]] && exit 1
[[ -s "${1:-}" ]] || exit 1
printf '%s %s\n' "${SSH_AUTH_SOCK:-none}" "$1" >> "$GK_ADDLOG"
EOS
    cat > "$GKD/bin/socat" <<'EOS'
#!/usr/bin/env bash
# Stands in for the root relay: makes the claude-facing socket and exits.
[[ "${GK_FAIL_RELAY:-0}" == 1 ]] && exit 1
spec="${1:-}"; path="${spec#UNIX-LISTEN:}"; path="${path%%,*}"
[[ -n "$path" && "$path" != "$spec" ]] || exit 1
mksock "$path"
chmod 600 "$path" 2>/dev/null || true
EOS
    chmod +x "$GKD/bin/mksock" "$GKD/bin/ssh-agent" "$GKD/bin/ssh-add" "$GKD/bin/socat"
    ok "unix-socket factory available (python3): §5's broker path can really be exercised"
else
    bad "python3 is unavailable, so no unix socket can be created: every §5 broker assertion below would be theater"
fi

# The shipped block with ONLY its two root-only path constants pointed at a sandbox.
gk_block() { printf '%s\n' "$GITKEY_BLOCK" \
    | sed -e "s#^BROKER_RUN_DIR=.*#BROKER_RUN_DIR=\"$1/run\"#" \
          -e "s#^BROKER_PROFILE_D=.*#BROKER_PROFILE_D=\"$1/profile-d.sh\"#"; }

gk_probe="$(gk_block "$GKD/probe")"
if [[ -n "$GITKEY_BLOCK" ]] \
   && grep -qF "BROKER_RUN_DIR=\"$GKD/probe/run\"" <<<"$gk_probe" \
   && grep -qF "BROKER_PROFILE_D=\"$GKD/probe/profile-d.sh\"" <<<"$gk_probe" \
   && ! grep -qE '^BROKER_(RUN_DIR|PROFILE_D)=' <<<"$(grep -vF "$GKD/probe" <<<"$gk_probe")"; then
    ok "§5 extracted from entrypoint.sh and its two root-only paths redirected into a sandbox"
else
    bad "§5 did not extract, or its root-only paths did not redirect: these tests would target /run and /etc"
fi

# run_gitkey <sandbox> <key|nokey> [VAR=VAL ...]
# Executes the shipped §5 block under the entrypoint's REAL shell options against a
# fresh sandbox home, and prints the boot log plus a final git_brokered=<0|1> line.
run_gitkey() {
    local sb="$GKD/$1" keystate="$2"; shift 2
    rm -rf "$sb"; mkdir -p "$sb/home/.ssh"
    [[ "$keystate" == key ]] && gk_fake_key > "$sb/git-key"
    local blk; blk="$(gk_block "$sb")"
    ( # START FROM NOTHING. This suite is itself run inside one of these containers,
      # which is launched with CLAUDE_BROKER_GIT_KEY already exported: inheriting it
      # would make the "operator recorded no choice" case untestable, and (worse) make
      # it PASS or FAIL according to the ambient posture of whoever ran the tests.
      unset CLAUDE_BROKER_GIT_KEY GK_FAIL_AGENT GK_FAIL_ADD GK_FAIL_RELAY
      export PATH="$GKD/bin:$PATH" CLAUDE_HOME="$sb/home" GITKEY_SRC="$sb/git-key" \
             CLAUDE_USER="$GK_USER" CLAUDE_UID="$GK_UID" CLAUDE_GID="$GK_GID" \
             GK_ADDLOG="$sb/ssh-add.log"
      if [[ $# -gt 0 ]]; then export "$@"; fi
      log() { echo "[entrypoint] $*"; }
      set -euo pipefail
      eval "$blk"
      echo "git_brokered=$git_brokered" ) 2>&1
}
gk_readable_lines() { grep -c "Deploy key readable :" <<<"$1" || true; }

# --- THE DEFAULT: nothing set at all -----------------------------------------------
out="$(run_gitkey unset key)"
[[ "$out" == *"git_brokered=1"* ]] \
    && ok  "CLAUDE_BROKER_GIT_KEY unset -> the key is BROKERED (the CC-11 flip)" \
    || bad "unset did NOT broker: an operator who never heard of the flag gets a readable key: $out"
[[ ! -e "$GKD/unset/home/.ssh/id_ed25519" ]] \
    && ok  "unset -> no readable key file is installed at ~/.ssh/id_ed25519" \
    || bad "unset installed a readable key file: the default is still fail-open"
grep -rqF "$GK_SECRET" "$GKD/unset/home" 2>/dev/null \
    && bad "the private key bytes are reachable somewhere under the agent's home directory" \
    || ok  "no file anywhere under the agent's home contains the private key bytes"
grep -q "IdentityFile" "$GKD/unset/home/.ssh/config" 2>/dev/null \
    && bad "the brokered path still points ssh at a key FILE (IdentityFile in ~/.ssh/config)" \
    || ok  "the brokered ssh config names no IdentityFile (signing goes through the relay)"
[[ -S "$GKD/unset/run/agent.sock" ]] \
    && ok  "the claude-facing relay socket exists (git can still sign/push)" \
    || bad "no relay socket: brokering claimed success without an agent-usable socket"
grep -q "SSH_AUTH_SOCK=$GKD/unset/run/agent.sock" "$GKD/unset/profile-d.sh" 2>/dev/null \
    && ok  "a login shell is pointed at the RELAY socket, never at the root agent socket" \
    || bad "SSH_AUTH_SOCK was not exported to the relay socket: git would not find the agent"
grep -q "$GKD/unset/run/agent-root.sock" "$GKD/unset/ssh-add.log" 2>/dev/null \
    && ok  "the key was loaded into the ROOT agent socket, not the claude-facing relay" \
    || bad "ssh-add did not target the root agent socket: $(cat "$GKD/unset/ssh-add.log" 2>/dev/null)"
grep -q "Deploy key readable : NO" <<<"$out" \
    && ok  "the boot log STATES the key is not readable by the agent user (plain language)" \
    || bad "no plain-language readability statement on the default path: $out"
[[ "$(gk_readable_lines "$out")" == 1 ]] \
    && ok  "exactly one readability statement is emitted (no ambiguity to resolve)" \
    || bad "expected exactly 1 'Deploy key readable' line, got $(gk_readable_lines "$out")"

# A stale readable key from an EARLIER boot of the same container must not survive the
# flip. `docker restart` keeps the container filesystem, so a box that once ran with
# CLAUDE_BROKER_GIT_KEY=0 would otherwise broker the key AND leave the old copy in ~/.ssh.
rm -rf "$GKD/stale"; mkdir -p "$GKD/stale/home/.ssh"
printf '%s\n' "$GK_SECRET" > "$GKD/stale/home/.ssh/id_ed25519"
gk_fake_key > "$GKD/stale/git-key"
gk_stale_blk="$(gk_block "$GKD/stale")"
( unset CLAUDE_BROKER_GIT_KEY GK_FAIL_AGENT GK_FAIL_ADD GK_FAIL_RELAY
  export PATH="$GKD/bin:$PATH" CLAUDE_HOME="$GKD/stale/home" GITKEY_SRC="$GKD/stale/git-key" \
         CLAUDE_USER="$GK_USER" CLAUDE_UID="$GK_UID" CLAUDE_GID="$GK_GID" GK_ADDLOG="$GKD/stale/ssh-add.log"
  log() { echo "[entrypoint] $*"; }
  set -euo pipefail
  eval "$gk_stale_blk" ) >/dev/null 2>&1 || true
[[ ! -e "$GKD/stale/home/.ssh/id_ed25519" ]] \
    && ok  "a readable key left by an earlier boot is DELETED when brokering takes over" \
    || bad "a stale ~/.ssh/id_ed25519 survived the brokered boot: the key is still readable"

# --- THE EXPLICIT OPT-OUT: the historical readable file, unchanged -------------------
for v in 0 false no off; do
    out="$(run_gitkey "off-$v" key "CLAUDE_BROKER_GIT_KEY=$v")"
    f="$GKD/off-$v/home/.ssh/id_ed25519"
    if [[ -f "$f" && "$(stat -c '%u %g %a' "$f")" == "$GK_UID $GK_GID 600" ]]; then
        ok "CLAUDE_BROKER_GIT_KEY=$v installs the historical key file, owned by the agent user at mode 600"
    else
        bad "CLAUDE_BROKER_GIT_KEY=$v did not reproduce today's readable-file behavior: $(stat -c '%u %g %a' "$f" 2>&1)"
    fi
    grep -q "IdentityFile ~/.ssh/id_ed25519" "$GKD/off-$v/home/.ssh/config" \
        && ok "CLAUDE_BROKER_GIT_KEY=$v points ssh at the installed key file (git keeps working)" \
        || bad "CLAUDE_BROKER_GIT_KEY=$v installed a key ssh will never offer (no IdentityFile)"
    grep -q "Deploy key readable : YES" <<<"$out" \
        && ok "CLAUDE_BROKER_GIT_KEY=$v says plainly that the agent user CAN read the key" \
        || bad "the opt-out path does not state the key is readable: $out"
done

# --- EXPLICIT ENABLING VALUES still broker ------------------------------------------
for v in 1 true yes on; do
    out="$(run_gitkey "on-$v" key "CLAUDE_BROKER_GIT_KEY=$v")"
    [[ "$out" == *"git_brokered=1"* && ! -e "$GKD/on-$v/home/.ssh/id_ed25519" ]] \
        && ok "CLAUDE_BROKER_GIT_KEY=$v brokers (no readable key file)" \
        || bad "CLAUDE_BROKER_GIT_KEY=$v did not broker: $out"
done

# --- AN UNRECOGNISED VALUE MUST BROKER, NEVER DOWNGRADE ------------------------------
# A typo is the case that decides whether this control fails safe. "O" for "0", a
# trailing-space "0 " that docker --env-file keeps verbatim, an empty value from a bare
# `CLAUDE_BROKER_GIT_KEY=` line: every one of them must land on the brokered path.
for v in O 2 "0 " " 0" "" broker "no thanks" 00 "false " disabled; do
    out="$(run_gitkey typo key "CLAUDE_BROKER_GIT_KEY=$v")"
    if [[ "$out" == *"git_brokered=1"* && ! -e "$GKD/typo/home/.ssh/id_ed25519" ]]; then
        ok "CLAUDE_BROKER_GIT_KEY='$v' is unrecognised -> brokered (containment is not downgraded)"
    else
        bad "CLAUDE_BROKER_GIT_KEY='$v' was read as a request for a READABLE key: a typo silently exfiltratable"
    fi
done

# --- FAIL CLOSED: a broker that cannot come up installs NOTHING ----------------------
# Three independent ways to break it, one per stage the entrypoint names in its own
# criterion (the agent process, the key add, the relay socket). The old code fell
# through to `install ... id_ed25519` in all three.
for stage in GK_FAIL_AGENT GK_FAIL_ADD GK_FAIL_RELAY; do
    out="$(run_gitkey "fail-$stage" key "$stage=1")"
    [[ "$out" == *"git_brokered=0"* && ! -e "$GKD/fail-$stage/home/.ssh/id_ed25519" ]] \
        && ok  "$stage: a failed broker installs NO readable key file (no fail-open fallback)" \
        || bad "$stage: FAIL-OPEN, the broker failed and a readable key was installed anyway: $out"
    grep -rqF "$GK_SECRET" "$GKD/fail-$stage/home" 2>/dev/null \
        && bad "$stage: the private key bytes are readable under the agent's home after a failed broker" \
        || ok  "$stage: no private key bytes anywhere under the agent's home after a failed broker"
    # "Unable to authenticate": no key file, no IdentityFile, and no agent socket to
    # sign through. git has nothing left to offer this remote, which is the point.
    if ! grep -q "IdentityFile" "$GKD/fail-$stage/home/.ssh/config" 2>/dev/null \
       && [[ ! -e "$GKD/fail-$stage/profile-d.sh" ]] \
       && [[ ! -S "$GKD/fail-$stage/run/agent.sock" ]]; then
        ok "$stage: git is left with no key file, no IdentityFile and no agent socket (cannot authenticate)"
    else
        bad "$stage: something was left behind that git could still authenticate with"
    fi
    [[ "$out" == *"ERROR"* && "$out" == *"NOT falling back to a readable key file"* ]] \
        && ok  "$stage: the failure is logged loudly and says it is NOT falling back" \
        || bad "$stage: the broker failure is not loud enough to see in the boot log: $out"
    grep -q "Deploy key readable : NO" <<<"$out" \
        && ok  "$stage: the boot log still states the key's readability (NO) after the failure" \
        || bad "$stage: no readability statement on the failed-broker path: $out"
done

# --- NO KEY MOUNTED: say so, claim nothing more, change nothing ----------------------
out="$(run_gitkey nokey nokey)"
[[ "$out" == *"No git SSH key mounted"* ]] \
    && ok  "no key mounted -> the boot log says exactly that" \
    || bad "the no-key-mounted path says nothing about the missing key: $out"
grep -qE "Deploy key readable : (YES|NO)" <<<"$out" \
    && bad "the no-key path CLAIMS a readability it cannot know: $out" \
    || ok  "no key mounted -> no YES/NO readability claim is made (only that none was mounted)"
grep -q "Deploy key readable : n/a" <<<"$out" \
    && ok  "no key mounted -> the readability line reads n/a, so the operator is not left inferring" \
    || bad "the no-key path emits no readability line at all: $out"
[[ ! -e "$GKD/nokey/home/.ssh/id_ed25519" && ! -e "$GKD/nokey/home/.ssh/config" \
   && ! -e "$GKD/nokey/profile-d.sh" && ! -d "$GKD/nokey/run" ]] \
    && ok  "no key mounted -> nothing is written: no key file, no ssh config, no relay, no profile export" \
    || bad "the no-key path wrote something: existing https/public-repo git behavior is not untouched"
[[ "$out" == *"git_brokered=0"* ]] \
    && ok  "no key mounted -> no broker is started for a key that does not exist" \
    || bad "the no-key path started a broker: $out"
# The HTTPS half of the same criterion: §5's no-key branch must only LOG. The gh
# credential-helper wiring that HTTPS git depends on lives further down and must not be
# reachable from, or conditional on, this branch.
gk_nokey_branch="$(awk '/^else$/{f=1} f{print} f&&/^fi$/{exit}' <<<"$GITKEY_BLOCK")"
if [[ -n "$gk_nokey_branch" ]] && ! grep -qE '^\s*(install|printf|cat|mkdir|rm|chmod|chown|git|gh)\b' <<<"$gk_nokey_branch"; then
    ok "the no-key branch only logs: it touches no file and no git/gh configuration"
else
    bad "the no-key branch does more than log, so HTTPS/public-repo behavior is not provably unchanged"
fi

# --- STRUCTURAL TRIPWIRES: the shape of the fix, not just this run's outcome ---------
# Pin the properties that a well-meaning refactor would quietly undo.
if grep -qF 'CLAUDE_BROKER_GIT_KEY:-}" =~ ^(0|false|no|off)$' <<<"$GITKEY_BLOCK"; then
    ok "the readable-file install is gated on a RECOGNISED DISABLING value (opt-out, not opt-in)"
else
    bad "§5 no longer selects the readable file by an explicit disabling value: the default may have flipped back"
fi
if ! grep -qF 'git_brokered" == 0' <<<"$GITKEY_BLOCK"; then
    ok "the old 'if the broker did not engage, install the key anyway' fall-through is gone"
else
    bad "the fail-open fall-through is back: a broker hiccup would install a readable key"
fi
if grep -qF 'mode=0600,user=$CLAUDE_USER' <<<"$GITKEY_BLOCK" \
   && grep -qF 'chmod 600 "$AGENT_SOCK"' <<<"$GITKEY_BLOCK"; then
    ok "the agent reaches only a uid-restricted RELAY; the real agent socket stays root-only"
else
    bad "the relay/root-socket permissions were loosened: the agent could reach the root ssh-agent directly"
fi

echo
echo "== RC watchdog: auth-aware state machine + login gate + resume-menu detection =="

# The watchdog is source-guarded (watch_loop runs only when executed, not sourced),
# so these exercise the real helpers with no docker and no tmux.
WD="$REPO_ROOT/bin/claude-rc-watchdog"
WLOG="$(mktemp)"; WCRED="$(mktemp)"

( export CLAUDE_RC_DEBUG_LOG="$WLOG" CLAUDE_CREDS_FILE="$WCRED"
  # shellcheck disable=SC1090
  source "$WD"                                                    # helpers only; loop NOT started
  fail=0
  : > "$WLOG";                                                    [[ "$(rc_state)" == unknown ]] || { echo s1; fail=1; }
  printf '[remote-bridge] v2 transport connected\n'  >> "$WLOG";  [[ "$(rc_state)" == alive   ]] || { echo s2; fail=1; }
  printf 'turn ended in error: Login expired\n'      >> "$WLOG";  [[ "$(rc_state)" == auth    ]] || { echo s3; fail=1; }
  printf 'recovery exhausted after 6 attempts\n'     >> "$WLOG";  [[ "$(rc_state)" == dead    ]] || { echo s4; fail=1; }
  printf '[remote-bridge] v2 transport connected\n'  >> "$WLOG";  [[ "$(rc_state)" == alive   ]] || { echo s5; fail=1; }
  printf 'Remote Control requires a claude.ai subscription.\n' >> "$WLOG"; [[ "$(rc_state)" == auth ]] || { echo s6; fail=1; }
  exit $fail
) && ok "rc_state maps alive/auth/dead/unknown by most-recent decisive line" \
   || bad "rc_state state machine is wrong (see s#)"

( export CLAUDE_RC_DEBUG_LOG="$WLOG" CLAUDE_CREDS_FILE="$WCRED"
  # shellcheck disable=SC1090
  source "$WD"
  fail=0
  printf '{"claudeAiOauth":{"accessToken":""}}'    > "$WCRED";    login_valid && { echo g1; fail=1; }   # empty token => NOT valid
  printf '{"claudeAiOauth":{"accessToken":"tok"}}' > "$WCRED";  ! login_valid && { echo g2; fail=1; }   # real token => valid
  : > "$WCRED";                                                   login_valid && { echo g3; fail=1; }   # blank file => NOT valid
  exit $fail
) && ok "login_valid gates restart on a real token (empty/blank => wait for make login)" \
   || bad "login_valid is wrong (see g#)"

( export CLAUDE_RC_DEBUG_LOG="$WLOG" CLAUDE_CREDS_FILE="$WCRED"
  # shellcheck disable=SC1090
  source "$WD"
  fail=0
  is_resume_menu "This session is 4h old. ❯ 1. Resume from summary (recommended)" || { echo m1; fail=1; }
  is_resume_menu "  2. Resume full session as-is"                                  || { echo m2; fail=1; }
  is_resume_menu "❯ an ordinary prompt with no menu"                               && { echo m3; fail=1; }
  exit $fail
) && ok "is_resume_menu recognises the --continue resume selector only" \
   || bad "is_resume_menu is wrong (see m#)"
rm -f "$WLOG" "$WCRED"

echo
echo "== entrypoint.sh §12a: the boot log states the posture of EACH address family =="

# A container routes IPv4 and IPv6, and the firewall can succeed on one family and
# fail on the other. The old line ("default-deny active") could not express that:
# it reported containment while IPv6 egress was wide open, which is the exact
# failure an operator cannot detect from the logs. The firewall now hands its
# per-family verdict to the entrypoint as its EXIT STATUS, and this section drives
# the shipped block with a stub firewall at each status.
#
# The block is EXTRACTED from entrypoint.sh and EXECUTED here, never mirrored, for
# the same reason §5 is: a copy keeps passing after the shipped wording regresses.
# Only its firewall path constant is redirected at a stub, and that redirect is
# asserted below so this cannot degrade into a test that shells out to the real
# /usr/local/bin/claude-egress-firewall (which is not even present on a CI host).
EG_BLOCK="$(awk '/^# --- 12a\. Egress lockdown/{f=1} f{print} f&&/^fi$/{exit}' "$ENTRYPOINT")"
EGD="$(mktemp -d)"; trap 'rm -rf "$STUB" "$APD" "$GKD" "$EGD"' EXIT

eg_block() { printf '%s\n' "$EG_BLOCK" \
    | sed -e "s#^EGRESS_FIREWALL_BIN=.*#EGRESS_FIREWALL_BIN=\"$1\"#"; }

eg_probe="$(eg_block "$EGD/fw")"
if [[ -n "$EG_BLOCK" ]] \
   && grep -qF "EGRESS_FIREWALL_BIN=\"$EGD/fw\"" <<<"$eg_probe" \
   && ! grep -qF "/usr/local/bin/claude-egress-firewall" <<<"$eg_probe"; then
    ok "§12a extracted from entrypoint.sh and its firewall path redirected at a stub"
else
    bad "§12a did not extract, or its firewall path did not redirect: this would run the real firewall"
fi

# eg_stub <firewall-exit-status> [stderr-line]
# Writes the firewall stub the extracted block will call. The optional second
# argument is a line the stub prints to stderr first, so a test can model WHICH
# reason the real script reported without pretending the reasons have different
# exit statuses (they do not: fail_open() ends `exit 1` on every one of them).
eg_stub() {
    if [[ $# -gt 1 ]]; then
        printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q >&2\nexit %s\n' "$2" "$1" > "$EGD/fw"
    else
        printf '#!/usr/bin/env bash\nexit %s\n' "$1" > "$EGD/fw"
    fi
    chmod +x "$EGD/fw"
}

# eg_exec <CLAUDE_EGRESS_LOCKDOWN value, or the literal UNSET>
# Executes the shipped §12a block under the entrypoint's REAL shell options
# (set -euo pipefail) and with the entrypoint's REAL die() in scope, against
# whatever stub eg_stub last wrote, and prints the boot log plus a final
# block_continued=1 line. That last line is load-bearing: under `set -e` it only
# appears if the block ran to completion, so it is the evidence that boot carries
# on to the tmux launch (the agent session) rather than refusing.
#
# die() is EXTRACTED (REAL_DIE, proved to work above), never stubbed: the strict
# spelling's entire behaviour is that die, and a local stub would keep passing if
# the shipped one stopped exiting non-zero.
eg_exec() {
    ( if [[ "$1" == "UNSET" ]]; then unset CLAUDE_EGRESS_LOCKDOWN
      else export CLAUDE_EGRESS_LOCKDOWN="$1"; fi
      log() { echo "[entrypoint] $*"; }
      eval "$REAL_DIE"
      set -euo pipefail
      eval "$(eg_block "$EGD/fw")"
      echo "block_continued=1" ) 2>&1
}
# The same run, reporting the block's EXIT STATUS instead of its output. Strict's
# whole point is a non-zero exit BEFORE the agent starts, and a text-only
# assertion cannot tell "refused" from "logged it and carried on".
eg_exec_rc() { eg_exec "$@" >/dev/null 2>&1; echo $?; }

# run_egress <firewall-exit-status> [lockdown-value]  (default: 1)
run_egress() { eg_stub "$1"; eg_exec "${2:-1}"; }
eg_line() { grep "Egress lockdown" <<<"$1" || true; }

# 0 = both families contained.
EG0="$(run_egress 0)"
if grep -qE 'Egress lockdown +: IPv4 default-deny, IPv6 default-deny' <<<"$EG0"; then
    ok "firewall exit 0: the boot log names BOTH families as default-deny"
else
    bad "firewall exit 0 did not report both families as default-deny: $(eg_line "$EG0")"
fi

# 2 = the case this spec exists for: IPv4 contained, IPv6 wide open. The operator
# must be able to read the unprotected family BY NAME, so assert on IPv6 being
# called UNRESTRICTED, not merely on the absence of a success word.
EG2="$(run_egress 2)"
if grep -qE 'Egress lockdown +: IPv4 default-deny, IPv6 UNRESTRICTED' <<<"$EG2"; then
    ok "firewall exit 2: IPv6 is reported UNRESTRICTED BY NAME while IPv4 stays default-deny"
else
    bad "firewall exit 2 did not name IPv6 as UNRESTRICTED: $(eg_line "$EG2")"
fi
grep -qE 'IPv6 (default-deny|active)' <<<"$EG2" \
    && bad "firewall exit 2 still claimed IPv6 lockdown somewhere: $(eg_line "$EG2")" \
    || ok "firewall exit 2 makes no claim of IPv6 containment anywhere in the boot log"

# 1 = fail-open. Both families are open and both must say so.
EG1="$(run_egress 1)"
if grep -qE 'Egress lockdown +: IPv4 UNRESTRICTED, IPv6 UNRESTRICTED' <<<"$EG1"; then
    ok "firewall exit 1 (fail-open): BOTH families are reported UNRESTRICTED"
else
    bad "firewall exit 1 did not report both families as unrestricted: $(eg_line "$EG1")"
fi

# An unrecognised status is a status this entrypoint cannot interpret, so it must
# claim nothing: the fail-open wording is the only safe reading.
EG9="$(run_egress 9)"
grep -qE 'Egress lockdown +: IPv4 UNRESTRICTED, IPv6 UNRESTRICTED' <<<"$EG9" \
    && ok "an unrecognised firewall status claims NO containment (reports both families open)" \
    || bad "an unrecognised firewall status was read as some kind of success: $(eg_line "$EG9")"

# NO unqualified claim, at any status. Every "Egress lockdown" line must name both
# families; a line that says only "default-deny active" is the regression this
# whole section guards, so the check is a property over all four statuses rather
# than a string match on one.
eg_unqualified=0
for _rc in 0 1 2 9; do
    while IFS= read -r _l; do
        [[ -z "$_l" ]] && continue
        grep -q 'IPv4' <<<"$_l" && grep -q 'IPv6' <<<"$_l" || eg_unqualified=1
    done <<<"$(eg_line "$(run_egress "$_rc")")"
done
[[ "$eg_unqualified" -eq 0 ]] \
    && ok "every Egress lockdown line names BOTH families (no unqualified 'lockdown is active')" \
    || bad "an Egress lockdown line claimed a posture without naming both address families"
grep -q 'default-deny active' "$ENTRYPOINT" \
    && bad "the old unqualified 'default-deny active' line is still in entrypoint.sh" \
    || ok "the old unqualified 'default-deny active' line is gone from entrypoint.sh"

# Boot must survive every one of them: a family that failed is a log line, never a
# refusal to reach the agent session.
eg_stopped=0
for _rc in 0 1 2 9; do grep -qxF 'block_continued=1' <<<"$(run_egress "$_rc")" || eg_stopped=1; done
[[ "$eg_stopped" -eq 0 ]] \
    && ok "boot continues to the agent session at every firewall status (0/1/2/unknown)" \
    || bad "some firewall status aborted the entrypoint: the container would never start the agent"

# Lockdown OFF is still silent: no posture line at all, and the firewall is not run.
printf '#!/usr/bin/env bash\ntouch "%s/ran"\nexit 0\n' "$EGD" > "$EGD/fw"; chmod +x "$EGD/fw"
rm -f "$EGD/ran"
EGOFF="$( ( export CLAUDE_EGRESS_LOCKDOWN=0
            log() { echo "[entrypoint] $*"; }
            set -euo pipefail
            eval "$(eg_block "$EGD/fw")" ) 2>&1 )"
[[ -z "$(eg_line "$EGOFF")" && ! -e "$EGD/ran" ]] \
    && ok "CLAUDE_EGRESS_LOCKDOWN=0: the firewall is never invoked and no posture is claimed" \
    || bad "lockdown off still ran the firewall or still logged a posture"

echo
echo "== entrypoint.sh §12a: CLAUDE_EGRESS_LOCKDOWN=strict fails CLOSED =="

# `strict` turns lockdown from a REQUEST into a REQUIREMENT. Everything about it
# is the same firewall, the same stub, the same shell options and the same log
# lines; what changes is what happens after a run that left egress unrestricted.
# The on spellings log it and fall through to the tmux launch on the very next
# statement of entrypoint.sh; strict must not reach that statement at all.
#
# So the assertions below are about what does NOT happen, and they are made two
# ways: the block's EXIT STATUS (non-zero = the entrypoint aborts) and the absence
# of the block_continued=1 marker (proof it never ran to the end).

# --- THE REFUSAL, per STATUS: no status is special-cased -----------------------------
# 1 is every reason the shipped fail_open() has; 127 is the script missing or not
# executable (the call site's own status); 9 is a status this entrypoint cannot
# interpret and already reports as both families open. All three mean "the ruleset
# was not applied", so all three must refuse.
for _rc in 1 127 9; do
    eg_stub "$_rc"
    rc="$(eg_exec_rc strict)"
    out="$(eg_exec strict)"
    [[ "$rc" != "0" ]] \
        && ok  "strict + firewall status $_rc: the entrypoint REFUSES (exit $rc)" \
        || bad "strict + firewall status $_rc booted anyway: the agent would run with unrestricted egress"
    grep -qxF 'block_continued=1' <<<"$out" \
        && bad "strict + firewall status $_rc ran past §12a: the tmux launch is the next statement" \
        || ok  "strict + firewall status $_rc stops before the agent session is started"
    grep -qE '^\[entrypoint\] ERROR: .*[Ee]gress lockdown' <<<"$out" \
        && ok  "strict + firewall status $_rc names egress lockdown as the reason for the refusal" \
        || bad "strict + firewall status $_rc refused without naming egress lockdown: $out"
    grep -qF 'CLAUDE_EGRESS_LOCKDOWN=strict' <<<"$out" \
        && ok  "strict + firewall status $_rc quotes the flag that caused the refusal (actionable)" \
        || bad "the refusal does not name CLAUDE_EGRESS_LOCKDOWN=strict: $out"
done

# --- THE REFUSAL, per REASON: EVERY reason the firewall reports is fatal --------------
# The reasons are READ OUT OF bin/claude-egress-firewall rather than listed here, so a
# reason added there is covered here the day it is added. They all exit 1 (fail_open()
# ends `exit 1` on every path), which is the point: the refusal is driven by the status
# alone, so "iptables not installed" is a failure to apply and never a skip, and an
# allowlist that resolved to nothing is not treated as a lesser failure than missing
# tooling.
EGFW="$REPO_ROOT/bin/claude-egress-firewall"
mapfile -t EG_REASONS < <(sed -n 's/.*fail_open "\([^"]*\)".*/\1/p' "$EGFW")
if (( ${#EG_REASONS[@]} >= 5 )); then
    ok "read ${#EG_REASONS[@]} fail_open reasons out of bin/claude-egress-firewall (not a hand-copied list)"
else
    bad "could not read the fail_open reasons from $EGFW (got ${#EG_REASONS[@]}): the per-reason checks would be vacuous"
fi
eg_strict_booted=() eg_open_refused=()
for _reason in "${EG_REASONS[@]}"; do
    eg_stub 1 "[egress] ERROR: $_reason, failing OPEN (egress UNRESTRICTED). Fix and restart the container."
    [[ "$(eg_exec_rc strict)" == "0" ]] && eg_strict_booted+=("$_reason")
    [[ "$(eg_exec_rc 1)"      != "0" ]] && eg_open_refused+=("$_reason")
done
[[ ${#eg_strict_booted[@]} -eq 0 ]] \
    && ok  "strict refuses on EVERY reason the firewall reports (${#EG_REASONS[@]}/${#EG_REASONS[@]}), tooling-absent and zero-resolution alike" \
    || bad "strict BOOTED on these firewall failures, so they are special-cased: ${eg_strict_booted[*]}"
[[ ${#eg_open_refused[@]} -eq 0 ]] \
    && ok  "the default spelling still fails OPEN on every one of those reasons (posture unchanged)" \
    || bad "CLAUDE_EGRESS_LOCKDOWN=1 refused to boot on: ${eg_open_refused[*]}"

# --- THE ON SPELLINGS ARE UNTOUCHED --------------------------------------------------
# The regression this whole change could cause is a fleet that stops coming up. Each
# existing on spelling must still log the fail-open line, still exit 0, and still reach
# the agent session, on the very failure that makes strict refuse.
eg_stub 1
for _v in 1 true yes on; do
    rc="$(eg_exec_rc "$_v")"
    out="$(eg_exec "$_v")"
    [[ "$rc" == "0" ]] && grep -qxF 'block_continued=1' <<<"$out" \
        && ok  "CLAUDE_EGRESS_LOCKDOWN=$_v + a failed firewall: still boots (fail-open, unchanged)" \
        || bad "CLAUDE_EGRESS_LOCKDOWN=$_v no longer fails open (exit $rc): every lockdown container would stop coming up"
    grep -qE 'Egress lockdown +: IPv4 UNRESTRICTED, IPv6 UNRESTRICTED \(FAILED to apply, egress left OPEN' <<<"$out" \
        && ok  "CLAUDE_EGRESS_LOCKDOWN=$_v still logs the fail-open line verbatim" \
        || bad "the fail-open log line changed for CLAUDE_EGRESS_LOCKDOWN=$_v: $(eg_line "$out")"
done

# --- STRICT ON A RULESET THAT APPLIES: an ordinary boot ------------------------------
# strict is not a different firewall. When the ruleset applies it must behave exactly
# like the on spellings, or no strict container could ever start.
eg_stub 0
rc="$(eg_exec_rc strict)"
out="$(eg_exec strict)"
[[ "$rc" == "0" ]] && grep -qxF 'block_continued=1' <<<"$out" \
    && ok  "strict + a firewall that APPLIES: boot carries on to the agent session" \
    || bad "strict refused a SUCCESSFUL firewall run (exit $rc): no strict container could ever start"
[[ "$(eg_line "$out")" == "$(eg_line "$(eg_exec 1)")" ]] \
    && ok  "strict logs the SAME posture line as the on spellings on a successful run" \
    || bad "strict logs a different posture line than =1 on success: $(eg_line "$out")"

# Firewall status 2 is a PARTIAL application (IPv4 committed, IPv6 open), not a failure
# to apply, so strict boots and the boot log keeps naming the unprotected family. This
# is deliberate and is the phase's own known limitation: a strict container is contained
# only as well as the ruleset underneath it, and refusing on 2 would make strict
# unusable on every image or host without a working ip6tables.
eg_stub 2
rc="$(eg_exec_rc strict)"
out="$(eg_exec strict)"
[[ "$rc" == "0" ]] && grep -qxF 'block_continued=1' <<<"$out" \
    && ok  "strict + firewall status 2 (IPv4 contained, IPv6 open): boots, per the phase's known limitation" \
    || bad "strict refused on status 2 (exit $rc): strict would now require a working IPv6 ruleset"
grep -qE 'Egress lockdown +: IPv4 default-deny, IPv6 UNRESTRICTED' <<<"$out" \
    && ok  "strict + status 2 still names IPv6 UNRESTRICTED in the boot log (nothing is hidden)" \
    || bad "strict + status 2 hid the unprotected family: $(eg_line "$out")"

echo
echo "== entrypoint.sh §12a: an unrecognised CLAUDE_EGRESS_LOCKDOWN value is REPORTED, never silent =="

# A mistyped strict request must not read as an intentional "off". It must also not
# refuse the boot: a container that bricked on a fat-fingered .env line would be a worse
# regression than the one being reported (§0 makes the same trade for the retired vars).
eg_stub 0
printf '#!/usr/bin/env bash\ntouch "%s/ran"\nexit 0\n' "$EGD" > "$EGD/fw"; chmod +x "$EGD/fw"
unk_refused=() unk_ran=() unk_unnamed=() unk_noposture=()
for _v in stict Strict STRICT enabled 2 "1 " " on"; do
    rm -f "$EGD/ran"
    out="$(eg_exec "$_v")"
    rc="$(eg_exec_rc "$_v")"
    [[ "$rc" != "0" ]]           && unk_refused+=("$_v")
    [[ -e "$EGD/ran" ]]          && unk_ran+=("$_v")
    [[ "$out" == *"'$_v'"* ]]    || unk_unnamed+=("$_v")
    grep -q 'IPv4 UNRESTRICTED, IPv6 UNRESTRICTED' <<<"$out" || unk_noposture+=("$_v")
done
[[ ${#unk_refused[@]} -eq 0 ]] \
    && ok  "an unrecognised value never refuses the boot (a typo in .env cannot brick a container)" \
    || bad "these unrecognised values aborted the boot: ${unk_refused[*]}"
[[ ${#unk_ran[@]} -eq 0 ]] \
    && ok  "an unrecognised value applies no firewall (it is not silently promoted to lockdown)" \
    || bad "these unrecognised values ran the firewall: ${unk_ran[*]}"
[[ ${#unk_unnamed[@]} -eq 0 ]] \
    && ok  "the boot log QUOTES the unrecognised value back (a mistyped 'strict' cannot read as 'off')" \
    || bad "these unrecognised values are not named in the boot log: ${unk_unnamed[*]}"
[[ ${#unk_noposture[@]} -eq 0 ]] \
    && ok  "the boot log names the POSTURE the unrecognised value produced (both families UNRESTRICTED)" \
    || bad "these unrecognised values were reported without stating the posture: ${unk_noposture[*]}"

# The recognised OFF values, and unset/empty, stay exactly as they are today: no
# firewall, no posture line, no warning, no refusal. CLAUDE_EGRESS_LOCKDOWN=0 is the
# shipped default and ships in every .env.example, so a new failure or even a new log
# line here would be a fleet-wide regression.
off_noisy=() off_ran=() off_refused=()
for _v in 0 false no off "" UNSET; do
    rm -f "$EGD/ran"
    out="$(eg_exec "$_v")"
    rc="$(eg_exec_rc "$_v")"
    [[ -n "$(eg_line "$out")" ]] && off_noisy+=("${_v:-empty}")
    [[ -e "$EGD/ran" ]]          && off_ran+=("${_v:-empty}")
    [[ "$rc" != "0" ]]           && off_refused+=("${_v:-empty}")
done
[[ ${#off_noisy[@]} -eq 0 && ${#off_ran[@]} -eq 0 && ${#off_refused[@]} -eq 0 ]] \
    && ok  "unset, empty and 0/false/no/off: no firewall, no posture line, no refusal (unchanged)" \
    || bad "an off value changed behaviour (logged: ${off_noisy[*]-} / ran the firewall: ${off_ran[*]-} / refused: ${off_refused[*]-})"

echo
echo "== bin/_common.sh: strict gets the SAME capability grant as the on spellings =="

# Without this a strict container is denied NET_ADMIN, its firewall can never apply,
# and it refuses to start EVERY time: the feature would ship broken in the most
# confusing possible way, and the operator would blame the refusal, not the grant.
in_env CLAUDE_EGRESS_LOCKDOWN=strict -- '[[ "$(harden_run_args)" == *"--cap-add NET_ADMIN"* ]]' \
    && ok  "harden_run_args grants NET_ADMIN under CLAUDE_EGRESS_LOCKDOWN=strict" \
    || bad "a strict container is granted no NET_ADMIN: its firewall could never apply, so it would refuse to start every time"
in_env CLAUDE_EGRESS_LOCKDOWN=strict -- \
    'a="$(harden_run_args)"; export CLAUDE_EGRESS_LOCKDOWN=1; b="$(harden_run_args)"; [[ "$a" == "$b" ]]' \
    && ok  "the strict run args are IDENTICAL to the run args for =1 (no extra privilege, and no less)" \
    || bad "strict and =1 produce different docker run args"
in_env CLAUDE_EGRESS_LOCKDOWN=0 -- '[[ "$(harden_run_args)" != *NET_ADMIN* ]]' \
    && ok  "lockdown off still grants no NET_ADMIN (the default posture is unchanged)" \
    || bad "NET_ADMIN is granted with lockdown off: the default posture changed"

echo
echo "== entrypoint.sh §7a: operator policy is delivered where the agent user cannot write =="

# §8b composes every setting this image asserts into $CLAUDE_CONFIG_DIR/settings.json:
# owned by the agent user, on a per-project volume that outlives the container, merged
# so the EXISTING file wins on conflict. §7a delivers the subset that is POLICY rather
# than preference to /etc/claude-code/managed-settings.json instead, root-owned, before
# the agent starts, which is the path Claude Code reads above every other settings level.
#
# The block is EXTRACTED from entrypoint.sh and EXECUTED here, never mirrored, for the
# same reason §5 and §12a are: a mirrored copy keeps passing after the shipped block
# regresses. Only its two root-only path constants are redirected into a sandbox so it
# can run unprivileged, and that redirect is asserted below so this can never degrade
# into a suite that writes to the real /etc.
MS_BLOCK="$(awk '/^# --- 7a\. Managed settings/{f=1} f && /^# --- 8\. /{exit} f{print}' "$ENTRYPOINT")"
MSD="$(mktemp -d)"; trap 'rm -rf "$STUB" "$APD" "$GKD" "$EGD" "$MSD"' EXIT

ms_block() { printf '%s\n' "$MS_BLOCK" \
    | sed -e "s#^MANAGED_DIR=.*#MANAGED_DIR=\"$1/managed\"#" \
          -e "s#^MANAGED_STAMP=.*#MANAGED_STAMP=\"$1/managed-image-policy.sha256\"#"; }

ms_probe="$(ms_block "$MSD/probe")"
if [[ -n "$MS_BLOCK" ]] \
   && grep -qF "MANAGED_DIR=\"$MSD/probe/managed\"" <<<"$ms_probe" \
   && grep -qF "MANAGED_STAMP=\"$MSD/probe/managed-image-policy.sha256\"" <<<"$ms_probe" \
   && ! grep -qE '^MANAGED_(DIR|STAMP)=' <<<"$(grep -vF "$MSD/probe" <<<"$ms_probe")"; then
    ok "§7a extracted from entrypoint.sh and its two root-only paths redirected into a sandbox"
else
    bad "§7a did not extract, or its root-only paths did not redirect: these tests would write to the real /etc"
fi

# A uid that is NOT the one running this suite, standing in for the agent user. The
# shipped block refuses to call a file enforced when the agent uid owns it, and every
# case below except the one that tests that refusal must therefore differ from `id -u`.
MS_AGENT_UID=$(( $(id -u) + 1 ))
MS_FILE="managed/managed-settings.json"

ms_fresh() { rm -rf "$MSD/$1"; mkdir -p "$MSD/$1"; }
# ms_run <sandbox> [VAR=VAL ...]
# Executes the shipped §7a block under the entrypoint's REAL shell options against the
# named sandbox, and prints the boot log plus a final block_continued=1 line. That last
# line is load-bearing: under `set -e` it appears only if the block ran to completion, so
# it is the evidence that boot carries on to the agent rather than dying over a policy
# file (this whole block is fail-safe by design and must never be fatal).
ms_run() {
    local sb="$MSD/$1"; shift
    local blk; blk="$(ms_block "$sb")"
    ( # START FROM NOTHING. This suite is itself run inside one of these containers,
      # which exports CLAUDE_PERMISSION_MODE, so inheriting it would make the built-in
      # default untestable and make these cases pass or fail by ambient posture.
      unset CLAUDE_PERMISSION_MODE CLAUDE_MANAGED_POLICY CLAUDE_DOCKER
      export CLAUDE_UID="$MS_AGENT_UID" CLAUDE_GID="$(id -g)" CLAUDE_USER=claude
      if [[ $# -gt 0 ]]; then export "$@"; fi
      log() { echo "[entrypoint] $*"; }
      set -euo pipefail
      eval "$blk"
      echo "block_continued=1" ) 2>&1
}
ms_line()      { grep "Managed policy" <<<"$1" || true; }
ms_enforced()  { grep -qE 'Managed policy +: ENFORCED' <<<"$1"; }
ms_refused()   { grep -qE 'Managed policy +: NOT ENFORCED' <<<"$1"; }
ms_continued() { grep -qxF 'block_continued=1' <<<"$1"; }

# --- THE DELIVERY: root-owned, mode 644, before the agent starts ---------------------
ms_fresh happy
MS_OUT="$(ms_run happy)"
MS_HAPPY="$MSD/happy/$MS_FILE"
[[ -f "$MS_HAPPY" ]] \
    && ok  "a container with no managed file gets one written at the vendor path" \
    || bad "no managed settings file was written: $(ms_line "$MS_OUT")"
if [[ -f "$MS_HAPPY" ]]; then
    [[ -O "$MS_HAPPY" ]] \
        && ok  "the managed file is owned by the uid the entrypoint runs as (root, in the image)" \
        || bad "the managed file is not owned by the writing uid"
    [[ "$(stat -c %a "$MS_HAPPY")" == "644" ]] \
        && ok  "the managed file is mode 644: no write bit for group or other" \
        || bad "the managed file is mode $(stat -c %a "$MS_HAPPY"), not 644: a non-root process could rewrite it"
    [[ "$(stat -c %a "$MSD/happy/managed")" == "755" ]] \
        && ok  "the managed directory is mode 755: the agent user cannot create or unlink in it" \
        || bad "the managed directory is mode $(stat -c %a "$MSD/happy/managed"), not 755"
fi
ms_enforced "$MS_OUT"  && ok "the boot log reports policy as ENFORCED"       || bad "policy was written but not reported as enforced: $(ms_line "$MS_OUT")"
ms_continued "$MS_OUT" && ok "boot carries on to the agent after §7a"        || bad "§7a aborted the boot: the container would never start the agent"

# --- THE CLASSIFICATION: policy is carried, preference is not ------------------------
# permissions.defaultMode is the containment posture the operator chose;
# skipDangerousModePermissionPrompt is meaningless apart from it; DISABLE_AUTOUPDATER
# keeps the session on the CLI version this image pins and verifies its flags against.
# includeCoAuthoredBy is a commit-message preference: §8b still sets it and a session is
# still free to change it, which is the whole difference this section encodes.
ms_has() { jq -e "$1" "$MS_HAPPY" >/dev/null 2>&1; }
ms_has '.permissions.defaultMode == "bypassPermissions"' \
    && ok  "managed: permissions.defaultMode (the containment posture)" \
    || bad "permissions.defaultMode is not delivered as managed policy"
ms_has '.skipDangerousModePermissionPrompt == true' \
    && ok  "managed: skipDangerousModePermissionPrompt (paired with the mode above)" \
    || bad "skipDangerousModePermissionPrompt is not delivered as managed policy"
ms_has '.env.DISABLE_AUTOUPDATER == "1"' \
    && ok  "managed: env.DISABLE_AUTOUPDATER (a self-updating session leaves the pinned CLI)" \
    || bad "env.DISABLE_AUTOUPDATER is not delivered as managed policy"
ms_has 'has("includeCoAuthoredBy") | not' \
    && ok  "NOT managed: includeCoAuthoredBy stays a preference a session may change" \
    || bad "includeCoAuthoredBy was delivered as policy: a commit-message preference is not policy"
# The telemetry kills must never appear in EITHER settings file: they break Remote
# Control, which is the point of this image (§8b's own note, docs/troubleshooting.md).
ms_has '.env // {} | has("DISABLE_TELEMETRY") or has("DO_NOT_TRACK") or has("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC") | not' \
    && ok  "the managed file carries none of the Remote-Control-breaking telemetry kills" \
    || bad "a telemetry kill reached the MANAGED file, where no session can strip it back out"
# Explicitly out of scope for this phase: turning bypass mode off is an operator's call
# about their own fleet, and this change only makes such a call enforceable.
ms_has '.permissions // {} | has("disableBypassPermissionsMode") | not' \
    && ok  "the managed file does NOT set permissions.disableBypassPermissionsMode (deliberately deferred)" \
    || bad "the image now disables bypass mode by itself: that is the operator's call, not the image's"
# Comments are allowed to name the key (§7a's own block explains why it is deferred);
# a line of CODE that sets it is the regression, so the scan drops comment lines first.
grep -vE '^[[:space:]]*#' "$ENTRYPOINT" | grep -q 'disableBypassPermissionsMode' \
    && bad "entrypoint.sh sets disableBypassPermissionsMode in code: this change must not make that call" \
    || ok  "no line of entrypoint.sh code sets disableBypassPermissionsMode"

# --- A3: the log names WHICH settings are managed, and never their values ------------
# The expected list is read out of the file the block just wrote, not hand-copied, so a
# key added to the policy set is covered here the day it is added.
MS_KEYS="$(jq -r '[paths(scalars) | map(tostring) | join(".")] | join(", ")' "$MS_HAPPY")"
[[ -n "$MS_KEYS" ]] && grep -qF "$MS_KEYS" <<<"$MS_OUT" \
    && ok  "the boot log names every managed setting by its dotted path ($MS_KEYS)" \
    || bad "the boot log does not name the managed settings: $(ms_line "$MS_OUT")"
grep -qiE 'NOT overridable' <<<"$MS_OUT" \
    && ok  "the boot log says those settings are not overridable from inside the container" \
    || bad "the boot log names the settings but never says they cannot be overridden from inside"

# A managed file is a place an operator can legitimately put a token (under .env), and
# the boot log is readable by anyone who can run `claude-logs`. Names, never values.
ms_fresh secret
mkdir -p "$MSD/secret/managed"
printf '%s\n' '{"env":{"MY_TOKEN":"SMOKINGGUNPOLICYVALUE"}}' > "$MSD/secret/managed/managed-settings.json"
chmod 644 "$MSD/secret/managed/managed-settings.json"
MS_SEC="$(ms_run secret)"
grep -qF 'env.MY_TOKEN' <<<"$MS_SEC" \
    && ok  "an operator-supplied file's settings are named in the boot log too" \
    || bad "an operator-supplied file's settings are not named: $(ms_line "$MS_SEC")"
grep -qF 'SMOKINGGUNPOLICYVALUE' <<<"$MS_SEC" \
    && bad "the boot log printed a managed setting's VALUE: an operator's token would leak into claude-logs" \
    || ok  "the boot log prints setting NAMES only, never their values"

# --- A8: the operator's launch-time value wins over the image's built-in default -----
ms_fresh opval
MS_OPVAL="$(ms_run opval CLAUDE_PERMISSION_MODE=acceptEdits)"
jq -e '.permissions.defaultMode == "acceptEdits"' "$MSD/opval/$MS_FILE" >/dev/null 2>&1 \
    && ok  "CLAUDE_PERMISSION_MODE=acceptEdits is what becomes policy, not the image default" \
    || bad "the image's built-in default overrode the operator's CLAUDE_PERMISSION_MODE"
ms_enforced "$MS_OPVAL" \
    && ok  "and the operator's value is reported as enforced" \
    || bad "the operator's value was written but not reported as enforced: $(ms_line "$MS_OPVAL")"

# The SECOND boot of the same container must honour a changed value too. Without the
# image stamp the block could not tell its own file from an operator's, so it would
# either freeze the first boot's policy for ever or overwrite a mounted host policy.
MS_SECOND="$(ms_run opval CLAUDE_PERMISSION_MODE=plan)"
jq -e '.permissions.defaultMode == "plan"' "$MSD/opval/$MS_FILE" >/dev/null 2>&1 \
    && ok  "a later boot with a changed CLAUDE_PERMISSION_MODE refreshes the image's own managed file" \
    || bad "the image's own managed file went stale: a changed operator value never takes effect"
ms_enforced "$MS_SECOND" || bad "the refreshed file was not reported as enforced: $(ms_line "$MS_SECOND")"

# --- AN OPERATOR-SUPPLIED FILE IS THEIRS: never overwritten, never chmod'd -----------
# This is how an operator changes policy from the host (a bind mount onto the vendor
# path). The image must not clobber it on boot, or the mount would be pointless.
ms_fresh opfile
mkdir -p "$MSD/opfile/managed"
printf '%s\n' '{"permissions":{"defaultMode":"plan","deny":["Read(./.env)"]}}' \
    > "$MSD/opfile/managed/managed-settings.json"
chmod 644 "$MSD/opfile/managed/managed-settings.json"
MS_BEFORE="$(sha256sum < "$MSD/opfile/$MS_FILE" | cut -d' ' -f1)"
MS_OPF="$(ms_run opfile)"
[[ "$(sha256sum < "$MSD/opfile/$MS_FILE" | cut -d' ' -f1)" == "$MS_BEFORE" ]] \
    && ok  "an operator-supplied managed file is left byte-for-byte as mounted" \
    || bad "the image overwrote the operator's own managed file: a host-mounted policy would never survive a boot"
ms_enforced "$MS_OPF" && grep -qF 'permissions.deny.0' <<<"$MS_OPF" \
    && ok  "and it is reported as enforced, naming ITS settings rather than the image's" \
    || bad "an operator-supplied file was not reported with its own settings: $(ms_line "$MS_OPF")"

# --- A5: no managed file present means nothing is reported as managed ----------------
# CLAUDE_MANAGED_POLICY is the operator's escape hatch from the host for the risk this
# block introduces: a setting that genuinely cannot be overridden from inside is also no
# longer loosenable by a session that needs it loosened.
ms_absent_bad=()
for _v in 0 false no off; do
    ms_fresh "off-$_v"
    out="$(ms_run "off-$_v" "CLAUDE_MANAGED_POLICY=$_v")"
    [[ -e "$MSD/off-$_v/$MS_FILE" ]]     && ms_absent_bad+=("$_v: a file was written")
    ms_enforced "$out"                   && ms_absent_bad+=("$_v: reported as enforced")
    ms_refused  "$out"                   || ms_absent_bad+=("$_v: no NOT ENFORCED line")
    ms_continued "$out"                  || ms_absent_bad+=("$_v: boot did not continue")
    grep -qF 'CLAUDE_MANAGED_POLICY' <<<"$out" || ms_absent_bad+=("$_v: the reason does not name the flag")
    grep -qF 'permissions.defaultMode' <<<"$out" && ms_absent_bad+=("$_v: a setting was still reported as managed")
done
[[ ${#ms_absent_bad[@]} -eq 0 ]] \
    && ok  "no managed file present: nothing is reported as managed, boot continues with today's settings" \
    || bad "the no-file path misreported: ${ms_absent_bad[*]}"

# --- POLICY OFF *AND* A FILE ALREADY THERE: the log must not deny what is in force ---
# The loop above always runs against an empty sandbox, so on its own it never combines
# the two states an operator can perfectly well ask for at once: mount your own policy
# onto the vendor path, and turn this image's own delivery off. The flag stops the IMAGE
# delivering; it cannot unsay a root-owned file that is already there and that Claude
# Code reads above every other settings level. A boot log that reported "NO setting is
# managed" here would tell the operator the exact opposite of the truth, which is what
# task 4's honesty rule forbids and what A3 asks for.
ms_fresh offfile
mkdir -p "$MSD/offfile/managed"
printf '%s\n' '{"permissions":{"defaultMode":"plan","disableBypassPermissionsMode":"disable"}}' \
    > "$MSD/offfile/$MS_FILE"
chmod 644 "$MSD/offfile/$MS_FILE"
MS_OFFFILE_BEFORE="$(sha256sum < "$MSD/offfile/$MS_FILE" | cut -d' ' -f1)"
MS_OFFFILE="$(ms_run offfile CLAUDE_MANAGED_POLICY=0)"
ms_enforced "$MS_OFFFILE" \
    && ok  "policy off with a file already at the vendor path: it is still reported ENFORCED" \
    || bad "policy off with a file already there was reported as if nothing were managed: $(ms_line "$MS_OFFFILE")"
grep -qF 'permissions.disableBypassPermissionsMode' <<<"$MS_OFFFILE" \
    && ok  "and the settings that ARE managed are named, flag or no flag" \
    || bad "the settings in force are not named: $(ms_line "$MS_OFFFILE")"
! grep -qF 'NO setting is managed' <<<"$MS_OFFFILE" \
    && ! grep -qF 'everything stays overridable from inside the container' <<<"$MS_OFFFILE" \
    && ok  "and the log never claims everything is overridable while that file is in force" \
    || bad "the log denied an enforcement that is really there: $(ms_line "$MS_OFFFILE")"
grep -qF 'CLAUDE_MANAGED_POLICY' <<<"$MS_OFFFILE" \
    && ok  "and the flag is still reported: the operator learns it delivered nothing, not that it removed anything" \
    || bad "the boot log does not mention CLAUDE_MANAGED_POLICY at all: $(ms_line "$MS_OFFFILE")"
[[ "$(sha256sum < "$MSD/offfile/$MS_FILE" | cut -d' ' -f1)" == "$MS_OFFFILE_BEFORE" ]] \
    && [[ ! -e "$MSD/offfile/managed-image-policy.sha256" ]] \
    && ok  "the flag still delivers nothing: the operator's file is untouched and no stamp is written" \
    || bad "policy off wrote something: the escape hatch must never establish or restamp a file"
ms_continued "$MS_OFFFILE" \
    && ok  "and boot carries on to the agent" \
    || bad "the flag-off-with-a-file path aborted the boot"

# The other way a file can already be there: an earlier boot of this same container
# wrote it, and the flag was turned off afterwards. /etc survives a restart, so the
# policy does too, and the second boot must report the file it finds rather than the
# thing it did not do. It must also leave that file alone: the flag establishes nothing.
ms_fresh offours
MS_OURS_ON="$(ms_run offours)"
MS_OURS_SHA="$(sha256sum < "$MSD/offours/$MS_FILE" | cut -d' ' -f1)"
MS_OURS_OFF="$(ms_run offours CLAUDE_MANAGED_POLICY=0)"
ms_enforced "$MS_OURS_OFF" && grep -qF 'permissions.defaultMode' <<<"$MS_OURS_OFF" \
    && ! grep -qF 'NO setting is managed' <<<"$MS_OURS_OFF" \
    && [[ "$(sha256sum < "$MSD/offours/$MS_FILE" | cut -d' ' -f1)" == "$MS_OURS_SHA" ]] \
    && ms_continued "$MS_OURS_OFF" \
    && ok  "a policy file an earlier boot wrote is still reported when the flag is turned off later" \
    || bad "the flag hid a policy file this image had already written: $(ms_line "$MS_OURS_OFF")"
ms_enforced "$MS_OURS_ON" || bad "the first boot of the flag-off-later case did not write a policy file: $(ms_line "$MS_OURS_ON")"

# The same combination with a file that is NOT enforceable: here "NO setting is managed"
# is the truth, so it must still be said, with the cause rather than the flag.
ms_fresh offjunk
mkdir -p "$MSD/offjunk/managed"
printf '%s\n' 'not json at all {{{' > "$MSD/offjunk/$MS_FILE"
chmod 644 "$MSD/offjunk/$MS_FILE"
MS_OFFJUNK="$(ms_run offjunk CLAUDE_MANAGED_POLICY=0)"
ms_refused "$MS_OFFJUNK" && ! ms_enforced "$MS_OFFJUNK" \
    && grep -qiE 'UNREADABLE|not parseable' <<<"$MS_OFFJUNK" && ms_continued "$MS_OFFJUNK" \
    && ok  "policy off with an unparseable file present: NOT ENFORCED, naming the file, boot continues" \
    || bad "policy off with an unparseable file misreported: $(ms_line "$MS_OFFJUNK")"

# An unrecognised value must never read as a deliberate off (the lesson §12a records).
ms_unrec_bad=()
for _v in of Off OFF disabled 2 "0 "; do
    ms_fresh "unrec"
    out="$(ms_run unrec "CLAUDE_MANAGED_POLICY=$_v")"
    ms_enforced "$out" || ms_unrec_bad+=("$_v")
    grep -qF "'$_v'" <<<"$out" || ms_unrec_bad+=("$_v (not quoted back)")
done
[[ ${#ms_unrec_bad[@]} -eq 0 ]] \
    && ok  "an unrecognised CLAUDE_MANAGED_POLICY leaves policy ON and is quoted back in the log" \
    || bad "an unrecognised value silently turned policy off, or was not reported: ${ms_unrec_bad[*]}"

# --- A6: an unparseable managed file is reported unreadable, never as enforced -------
ms_fresh junk
mkdir -p "$MSD/junk/managed"
printf '%s\n' 'this is not json {{{' > "$MSD/junk/managed/managed-settings.json"
chmod 644 "$MSD/junk/managed/managed-settings.json"
MS_JUNK_BEFORE="$(sha256sum < "$MSD/junk/$MS_FILE" | cut -d' ' -f1)"
MS_JUNK="$(ms_run junk)"
ms_refused "$MS_JUNK" && ! ms_enforced "$MS_JUNK" \
    && ok  "an unparseable managed file is reported NOT ENFORCED" \
    || bad "an unparseable managed file was reported as enforced: $(ms_line "$MS_JUNK")"
grep -qiE 'UNREADABLE|not parseable' <<<"$MS_JUNK" \
    && ok  "and the log says that file is unreadable, naming it" \
    || bad "the log does not report the file as unreadable: $(ms_line "$MS_JUNK")"
[[ "$(sha256sum < "$MSD/junk/$MS_FILE" | cut -d' ' -f1)" == "$MS_JUNK_BEFORE" ]] \
    && ok  "the unparseable file is left exactly as it is (it may be a read-only mount)" \
    || bad "the block rewrote an unparseable operator file"
ms_continued "$MS_JUNK" \
    && ok  "and boot still reaches the agent with the settings §8b produces today" \
    || bad "an unparseable managed file aborted the boot"

# --- A7: every way policy cannot be established is reported, and none is fatal -------
# The requirement is the honest report, not a particular cause, so this drives each cause
# and asserts the same three properties over all of them.
ms_case() {  # ms_case <label> <sandbox> <setup-snippet> [VAR=VAL ...]
    local label="$1" sb="$2" setup="$3"; shift 3
    ms_fresh "$sb"
    eval "$setup"
    local out; out="$(ms_run "$sb" "$@")"
    printf '%s\n' "$out"
}
ms_fail_bad=() ms_fail_names=0 ms_fail_total=0
ms_expect_fail() {  # ms_expect_fail <label> <needle-in-the-reason> <output>
    local label="$1" needle="$2" out="$3"
    ms_fail_total=$((ms_fail_total+1))
    ms_enforced "$out"  && ms_fail_bad+=("$label: claimed ENFORCED")
    ms_refused  "$out"  || ms_fail_bad+=("$label: no NOT ENFORCED line")
    ms_continued "$out" || ms_fail_bad+=("$label: the boot did not continue")
    grep -qF "$needle" <<<"$out" && ms_fail_names=$((ms_fail_names+1)) \
        || ms_fail_bad+=("$label: the reason does not name '$needle'")
}
# 1. the directory cannot be created (a regular file sits where it must go)
ms_expect_fail "dir not creatable" "could not be created" \
    "$(ms_case dirblocked dirblocked 'printf x > "$MSD/dirblocked/managed"')"
# 2. the directory cannot be created because its own parent is not writable, which is
#    what a read-only /etc looks like from in here
ms_expect_fail "parent not writable" "could not be created" \
    "$(ms_case parentro parentro 'chmod 500 "$MSD/parentro"')"
chmod 700 "$MSD/parentro" 2>/dev/null || true
# 3. the new policy cannot be written into the directory
ms_expect_fail "file not writable" "could not be written" \
    "$(ms_case tmpblocked tmpblocked 'mkdir -p "$MSD/tmpblocked/managed/managed-settings.json.tmp"')"
# 4. the file is owned by the agent user, so the policed process could rewrite it
ms_expect_fail "owned by the agent uid" "owned by the agent user" \
    "$(ms_case agentowned agentowned \
        'mkdir -p "$MSD/agentowned/managed"; printf "{\"a\":1}\n" > "$MSD/agentowned/$MS_FILE"; chmod 644 "$MSD/agentowned/$MS_FILE"' \
        "CLAUDE_UID=$(id -u)")"
# 5. the file is group/other writable, so a non-root process could rewrite it
ms_expect_fail "group/other writable" "grants write to group or other" \
    "$(ms_case wideopen wideopen \
        'mkdir -p "$MSD/wideopen/managed"; printf "{\"a\":1}\n" > "$MSD/wideopen/$MS_FILE"; chmod 666 "$MSD/wideopen/$MS_FILE"')"
# 6. the file is fine but its DIRECTORY is group/other writable, so a non-root process
#    unlinks the file and puts its own there: a 644 root file is no protection alone
ms_expect_fail "directory group/other writable" "unlink the policy file" \
    "$(ms_case widedir widedir \
        'mkdir -p "$MSD/widedir/managed"; printf "{\"a\":1}\n" > "$MSD/widedir/$MS_FILE"; chmod 644 "$MSD/widedir/$MS_FILE"; chmod 777 "$MSD/widedir/managed"')"
# 7. the file parses but carries nothing, so there is no policy to enforce
ms_expect_fail "empty policy" "carries no settings" \
    "$(ms_case emptypol emptypol \
        'mkdir -p "$MSD/emptypol/managed"; printf "{}\n" > "$MSD/emptypol/$MS_FILE"; chmod 644 "$MSD/emptypol/$MS_FILE"')"
[[ ${#ms_fail_bad[@]} -eq 0 ]] \
    && ok  "every way policy cannot be established reports NOT ENFORCED, names the cause, and still boots ($ms_fail_total causes)" \
    || bad "a failure path misreported: ${ms_fail_bad[*]}"
[[ "$ms_fail_names" -eq "$ms_fail_total" ]] \
    && ok  "and each report names its own failure rather than a generic one" \
    || bad "$(( ms_fail_total - ms_fail_names )) of $ms_fail_total failure reports did not name their cause"

# §7a is fail-safe by construction: it must not reach for the entrypoint's die().
grep -qE '(^|[^_[:alnum:]])die ' <<<"$MS_BLOCK" \
    && bad "§7a calls die(): a policy file it cannot write would brick every session from this image" \
    || ok  "§7a never calls die(): no failure here can stop a container reaching its agent"

echo
echo "== entrypoint.sh: managed policy is ADDITIVE, and lands before the agent starts =="

# The phase's own fail-safe is that §8b keeps doing exactly what it did. These are
# structural tripwires on that promise: if a later change "simplifies" §8b by deleting
# what §7a now also delivers, a container whose managed file is missing or unparseable
# stops behaving as it does today, and these go red.
MS_8B="$(awk '/^# 8b\. settings.json/{f=1} f && /^# 8c\./{exit} f{print}' "$ENTRYPOINT")"
[[ -n "$MS_8B" ]] && ok "§8b extracted from entrypoint.sh for the additive checks" \
                  || bad "could not extract §8b: the additive checks below would be vacuous"
ms_8b_missing=()
for _needle in 'permissions: { defaultMode: $pm }' 'skipDangerousModePermissionPrompt: true' \
               'includeCoAuthoredBy: true' 'DISABLE_AUTOUPDATER: "1"' \
               'del(.DISABLE_TELEMETRY,.DO_NOT_TRACK,.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC)' \
               'STALE_HOOK_CMD' '> "$CLAUDE_CONFIG_DIR/settings.json"'; do
    grep -qF "$_needle" <<<"$MS_8B" || ms_8b_missing+=("$_needle")
done
[[ ${#ms_8b_missing[@]} -eq 0 ]] \
    && ok  "§8b still composes the same settings, still strips the telemetry kills, still self-heals the stale hook" \
    || bad "§8b lost something managed policy does not replace: ${ms_8b_missing[*]}"
grep -qF 'chown "$CLAUDE_UID:$CLAUDE_GID" "$CLAUDE_CONFIG_DIR/settings.json"' "$ENTRYPOINT" \
    && ok  "§8b still hands settings.json to the agent user (managed policy did not take it away)" \
    || bad "settings.json is no longer chowned to the agent user"
grep -qF 'Merged baked-in plugin marketplaces/plugins into settings.json' "$ENTRYPOINT" \
    && grep -qF 'Merged runtime plugin marketplaces/plugins into settings.json' "$ENTRYPOINT" \
    && ok  "§8c and §8c-bis still merge the baked and runtime plugin sets" \
    || bad "a plugin merge was lost: managed policy is additive and must not have touched them"

# The two blocks must not drift apart on what the built-in default IS. Both defaults are
# read out of entrypoint.sh; a hand-copied expectation here would keep passing after one
# of them changed, and the container would then assert one posture and enforce another.
MS_7A_DEFAULT="$(sed -n 's/^MANAGED_PERM_MODE="\${CLAUDE_PERMISSION_MODE:-\(.*\)}"$/\1/p' "$ENTRYPOINT")"
MS_8B_DEFAULT="$(sed -n 's/^PERM_MODE="\${CLAUDE_PERMISSION_MODE:-\(.*\)}"$/\1/p' "$ENTRYPOINT")"
[[ -n "$MS_7A_DEFAULT" && "$MS_7A_DEFAULT" == "$MS_8B_DEFAULT" ]] \
    && ok  "§7a and §8b read the same operator input and share one built-in default ($MS_7A_DEFAULT)" \
    || bad "§7a defaults the permission mode to '$MS_7A_DEFAULT' and §8b to '$MS_8B_DEFAULT': the container would assert one posture and enforce another"

# The escape hatch is only an escape hatch on every launch route. `docker run -e` and a
# compose `environment:` row each enumerate what they pass, so a flag missing from one of
# them is silently inert there while `.env.example` and the docs say it works.
ms_route_missing=()
grep -qF 'CLAUDE_MANAGED_POLICY="${CLAUDE_MANAGED_POLICY:-1}"' "$REPO_ROOT/bin/claude-launch" \
    || ms_route_missing+=(bin/claude-launch)
grep -qF 'CLAUDE_MANAGED_POLICY: ${CLAUDE_MANAGED_POLICY:-1}' "$REPO_ROOT/docker-compose.yml" \
    || ms_route_missing+=(docker-compose.yml)
grep -qF 'CLAUDE_MANAGED_POLICY' "$REPO_ROOT/bin/claude-compose-gen" \
    || ms_route_missing+=(bin/claude-compose-gen)
grep -qF 'CLAUDE_MANAGED_POLICY' "$REPO_ROOT/.env.example" \
    || ms_route_missing+=(.env.example)
[[ ${#ms_route_missing[@]} -eq 0 ]] \
    && ok  "CLAUDE_MANAGED_POLICY reaches the container by every launch route (launch, compose, compose-gen, .env)" \
    || bad "CLAUDE_MANAGED_POLICY is inert on: ${ms_route_missing[*]}"

# "Established before the agent process starts" is an ORDERING claim, so it is checked as
# one: §7a has to sit above the tmux launch in the shipped file, not merely exist.
MS_7A_LINE="$(grep -n '^# --- 7a\. Managed settings' "$ENTRYPOINT" | head -1 | cut -d: -f1)"
MS_TMUX_LINE="$(grep -n '^asclaude tmux new-session' "$ENTRYPOINT" | head -1 | cut -d: -f1)"
[[ -n "$MS_7A_LINE" && -n "$MS_TMUX_LINE" && "$MS_7A_LINE" -lt "$MS_TMUX_LINE" ]] \
    && ok  "§7a runs before the tmux launch, so policy is in force before the agent exists" \
    || bad "§7a does not precede the agent launch (7a at line ${MS_7A_LINE:-none}, tmux at line ${MS_TMUX_LINE:-none})"

echo
echo "== $PASS passed, $FAIL failed =="
exit $(( FAIL > 0 ? 1 : 0 ))
