#!/usr/bin/env bash
# Unit tests that need NO docker — safe for CI and for `scripts/verify.sh`.
#
# Covers the pure-logic checks in bin/_common.sh that survive SC-5 (the Sysbox
# version-floor refusal, preflight_sysbox/sysbox_version_check, was removed along
# with the nested-Sysbox worker-broker substrate it gated — see
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

# preflight_runc must never exit non-zero — it warns. Feed it a vulnerable runc via a stub.
STUB="$(mktemp -d)"
trap 'rm -rf "$STUB"' EXIT
printf '#!/bin/sh\necho "runc version 1.2.7"\n' > "$STUB/runc" && chmod +x "$STUB/runc"
if in_env PATH="$STUB:/usr/bin:/bin" -- preflight_runc; then
    ok  "a vulnerable runc (1.2.7) only WARNS — flat launch path behavior unchanged"
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
echo "== entrypoint.sh §8b: SC-5 self-heal drops the stale claude-md-fragments SessionStart hook =="

# SC-5 deleted bin/claude-md-fragments (the CLAUDE.d fragment loader), but images built
# BEFORE SC-5 persisted a SessionStart hook invoking it into every per-project config
# VOLUME. §8b's merge lets existing user settings win, so without a self-heal that hook
# would survive the upgrade and fire an ENOENT at every session start, forever.
#
# The jq program is EXTRACTED FROM entrypoint.sh rather than mirrored here, so this test
# exercises the real filter and cannot silently drift away from it.
ENTRYPOINT="$REPO_ROOT/entrypoint.sh"
# Extract the command string from entrypoint.sh too — NOT hardcoded here. If someone
# typos STALE_HOOK_CMD, the self-heal silently becomes a production no-op that resurrects
# the ENOENT defect; a test carrying its own copy of the string would still pass and the
# gate would be fake. Extracting both halves means the test can only pass if the shipped
# filter really matches the hook the pre-SC-5 image actually baked (asserted below).
STALE_CMD="$(sed -n 's/^STALE_HOOK_CMD="\(.*\)"$/\1/p' "$ENTRYPOINT")"
[[ "$STALE_CMD" == "/usr/local/bin/claude-md-fragments" ]] \
    && ok  "entrypoint.sh's STALE_HOOK_CMD matches the hook pre-SC-5 images actually baked" \
    || bad "STALE_HOOK_CMD is '$STALE_CMD' — does not match the baked hook; the self-heal is a NO-OP"
HOOK_FILTER="$(awk '/jq --arg stale "\$STALE_HOOK_CMD"/{f=1; sub(/^.*--arg stale "\$STALE_HOOK_CMD" .$/,""); }
                    f{print}
                    f && /^ *> "\$CLAUDE_CONFIG_DIR\/settings.json"$/{exit}' "$ENTRYPOINT" \
                 | sed -e "s/' *\\\\$//" -e '/^ *> "\$CLAUDE_CONFIG_DIR/d')"

if [[ -n "$HOOK_FILTER" ]] && echo '{}' | jq --arg stale "$STALE_CMD" "$HOOK_FILTER" >/dev/null 2>&1; then
    ok "the §8b stale-hook jq filter was extracted from entrypoint.sh and parses"

    # The real legacy-volume state: the pre-SC-5 baked settings.json was EXACTLY this.
    legacy='{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"'"$STALE_CMD"'"}]}]}}'
    got="$(echo "$legacy" | jq -c --arg stale "$STALE_CMD" "$HOOK_FILTER")"
    [[ "$got" == '{}' ]] \
        && ok  "a pre-SC-5 config volume is healed: the stale hook (and the empty .hooks) are dropped" \
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
        || bad "$malformed malformed shape(s) were dropped/mangled — settings.json would be truncated or corrupted"
else
    bad "could not extract a working stale-hook jq filter from entrypoint.sh §8b (the SC-5 self-heal is missing or broke)"
fi

echo
echo "== entrypoint.sh §0: retired SC-5 env vars warn loudly, never silently no-op =="

# The removed --broker/--sysbox/--worker-tarball FLAGS hard-die. The env vars they used to
# set are merely unread — and silence there is unsafe: an operator running
# CLAUDE_CACHE_PROXY_HOST + CLAUDE_EGRESS_LOCKDOWN=1 had a single audited egress choke
# point, and post-SC-5 the firewall composes its default allowlist and public npm is
# reachable again. §0 must SAY so. Extracted from entrypoint.sh, not mirrored.
GUARD="$(awk '/^# --- 0\. Refuse retired/,/^unset _v _retired_set/' "$ENTRYPOINT")"

# Run §0 under the ENTRYPOINT'S REAL SHELL OPTIONS (`set -euo pipefail`), not a laxer
# subset. This is the whole point: §0 runs near the top of entrypoint.sh, so if it aborts
# on a CLEAN boot (e.g. a bare `(( ${#arr[@]} > 0 ))` whose arithmetic evaluates to 0
# returns exit 1, which `set -e` turns into an abort) then EVERY container fails to boot.
# Under `set -u` alone that fatal case is invisible — the guard dies silently, produces no
# output, and a text-only assertion would PASS precisely because it is dead. So: real
# options, and assert the EXIT CODE, not just the text.
run_guard() { ( eval "log() { echo \"[entrypoint] \$*\"; }"; set -euo pipefail; eval "$GUARD" ) 2>&1; }
guard_rc()  { ( eval "log() { echo \"[entrypoint] \$*\"; }"; set -euo pipefail; eval "$GUARD" ) >/dev/null 2>&1; echo $?; }

if [[ -n "$GUARD" ]]; then
    # THE BRICK TEST: a clean boot (no retired vars) must exit 0 under -euo pipefail.
    rc="$(guard_rc)"
    [[ "$rc" == "0" ]] \
        && ok  "§0 exits 0 on a clean boot under 'set -euo pipefail' (does not brick the container)" \
        || bad "§0 exited $rc on a CLEAN boot under 'set -euo pipefail' — EVERY container would fail to boot"

    # And it must still exit 0 when it DOES fire (a warning must not abort the boot).
    rc="$(CLAUDE_CACHE_PROXY_HOST=cache.internal CLAUDE_WORKER_BROKER=1 guard_rc)"
    [[ "$rc" == "0" ]] \
        && ok  "§0 exits 0 when it fires (warn-not-die: a stale .env line never blocks boot)" \
        || bad "§0 exited $rc when warning — a stale .env line would brick the container"

    out="$(CLAUDE_CACHE_PROXY_HOST=cache.internal run_guard)"
    [[ "$out" == *"RETIRED in SC-5"*   && "$out" == *"CLAUDE_CACHE_PROXY_HOST"* ]] \
        && ok  "a retired var (CLAUDE_CACHE_PROXY_HOST) is named in a loud warning" \
        || bad "retired var was silently ignored: $out"
    [[ "$out" == *"audited egress choke point"* ]] \
        && ok  "the cache-proxy warning spells out the egress-posture change (npm reachable again)" \
        || bad "cache-proxy warning does not explain the security-posture change: $out"

    # PIN THE WHOLE LIST — spot-checking two vars is not a gate: truncating RETIRED_VARS
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
        || bad "CLAUDE_BROKER_GIT_KEY was wrongly flagged as retired — it is a live control: $out"

    out="$(run_guard)"
    [[ -z "$out" ]] \
        && ok  "no retired vars set → §0 is silent (no noise on a clean boot)" \
        || bad "§0 emitted output with no retired vars set: $out"
else
    bad "could not extract §0's retired-env guard from entrypoint.sh (the SC-5 guard is missing)"
fi

# ==========================================================================================
# CC-BINS — the bins that lost their reason are gone, and their removal is LOUD
# ==========================================================================================
echo
echo "== CC-BINS: claude-controller / claude-reaper / the WITH_DOCKER variant are fully gone =="

# A deleted bin that some file still names is worse than the bin: a stale `COPY bin/claude-reaper`
# fails the image build outright, and a stale CI step or npm-test entry fails every run. Pin the
# absence at every site that referenced them, so a partial revert cannot pass.
for f in bin/claude-controller bin/claude-reaper test/controller-unit.sh test/reaper-unit.sh; do
    [[ ! -e "$REPO_ROOT/$f" ]] \
        && ok  "$f is deleted" \
        || bad "$f still exists — CC-BINS removed it"
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
# WITH_DOCKER is BACK, deliberately — but the property CC-BINS was protecting still holds and
# is what we assert now. It deleted the variant because the baked engine was UNREACHABLE: no
# runtime, no --privileged, no socket mount, and nothing that started dockerd — 400 MB of dead
# daemon. The engine only earns its place if it can actually run, so pin the wiring, not the
# absence: the entrypoint must start it, and the launcher must give it the Sysbox runtime that
# lets it start without privilege. Break either and the variant is dead weight again.
# (See docs/architecture.md; the worker BROKER it originally served stays retired.)
# NOTE — materialize code_of's output into a variable instead of piping it into `grep -q`.
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
    bad "WITH_DOCKER is missing from the Dockerfile — --docker sessions cannot have an engine"
fi
if has "$entrypoint_code" 'CLAUDE_DOCKER' && has "$entrypoint_code" '(^|[[:space:]])dockerd[[:space:]]*>>'; then
    ok  "the entrypoint actually STARTS the baked engine (CLAUDE_DOCKER=1 → dockerd)"
else
    bad "nothing starts dockerd — the baked engine is unreachable again (the exact defect CC-BINS deleted it for)"
fi
if has "$launch_code" 'runtime=sysbox-runc'; then
    ok  "claude-launch gives the engine a runtime it can start under (--runtime=sysbox-runc)"
else
    bad "claude-launch selects no Sysbox runtime — an inner dockerd cannot start without the userns"
fi
# The two shortcuts that would make an inner engine trivial and catastrophic. Sysbox exists
# precisely so neither is needed; if one appears, the isolation story is gone.
for f in bin/claude-launch bin/claude-compose-gen entrypoint.sh docker-compose.yml; do
    [[ -e "$REPO_ROOT/$f" ]] || continue
    if has "$(code_of "$REPO_ROOT/$f")" '--privileged|privileged:[[:space:]]*true|/var/run/docker\.sock'; then
        bad "$f grants --privileged or mounts the host docker socket — either hands the agent the host"
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
echo "== CC-BINS: entrypoint REFUSES CLAUDE_CONTROLLER=1 (never silently boots interactive) =="

# CLAUDE_CONTROLLER is NOT an inert leftover like the §0 vars — it is an ACTIVE request for
# unattended operation. Warn-and-ignore would boot an unattended fleet container into an
# interactive Remote-Control session nobody is watching, which never runs the loop: a container
# that looks alive and does nothing. So this one DIES (§0b).
#
# BOTH the guard AND the real `die` it depends on are extracted from entrypoint.sh — never
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
# and "command not found" under `set -e` LOOKS exactly like a refusal — so the controller
# assertions below would all still pass while testing nothing at all. Exercise it instead.
die_rc="$( ( eval "$REAL_DIE"; die "probe" ) >/dev/null 2>&1; echo $? )"
die_out="$( ( eval "$REAL_DIE"; die "probe" ) 2>&1 )"
[[ "$die_rc" == "1" && "$die_out" == *"probe"* ]] \
    && ok  "entrypoint's real die() extracted AND exercised (exits 1, prints its message) — not a stub, not a broken eval" \
    || bad "the extracted die() does not behave (rc=$die_rc, out=$die_out) — the CLAUDE_CONTROLLER gate would be theater"

if [[ -n "$CTRL_GUARD" ]]; then
    for v in 1 true yes on; do
        rc="$(CLAUDE_CONTROLLER="$v" ctrl_rc)"
        [[ "$rc" != "0" ]] \
            && ok  "CLAUDE_CONTROLLER=$v is REFUSED (exit $rc), not silently downgraded to interactive" \
            || bad "CLAUDE_CONTROLLER=$v booted anyway — an unattended container would silently run interactive"
    done

    # The refusal has to be ACTIONABLE, or the operator just sees their fleet crashloop.
    out="$(CLAUDE_CONTROLLER=1 ctrl_run)"
    [[ "$out" == *"CLAUDE_AUTOPILOT=1"* ]] \
        && ok  "the refusal names the replacement (CLAUDE_AUTOPILOT=1 — the same loop it always was)" \
        || bad "the CLAUDE_CONTROLLER refusal does not tell the operator what to set instead: $out"

    # A clean boot, and the inert CLAUDE_CONTROLLER=0 that every old .env.example carries, must
    # sail straight through — refusing THOSE would brick every container.
    rc="$(ctrl_rc)";                     [[ "$rc" == "0" ]] \
        && ok  "unset CLAUDE_CONTROLLER → no refusal (clean boot unaffected)" \
        || bad "the guard aborts a CLEAN boot (exit $rc) — every container would fail to start"
    rc="$(CLAUDE_CONTROLLER=0 ctrl_rc)"; [[ "$rc" == "0" ]] \
        && ok  "CLAUDE_CONTROLLER=0 → no refusal (a stale .env line never blocks boot)" \
        || bad "CLAUDE_CONTROLLER=0 aborted the boot (exit $rc) — stale .env files would brick"
else
    bad "could not extract the CLAUDE_CONTROLLER refusal from entrypoint.sh (CC-BINS guard is missing)"
fi

echo
echo "== CC-BINS: claude-autopilot never invents a prompt (the /next default is gone) =="

# The old CLAUDE_AUTOPILOT_CMD default was `/next` — a cosyte-cockpit command this generic image
# does not ship, so on almost every container it resolved to nothing at all. (It did NOT reach the
# model as a literal prompt: `claude -p` reports an unknown slash command as a zero-turn success
# and never invokes the model — see the next section, which is where the real damage was.) The fix
# is a hard rule: NO COMMAND, NO RUN. These tests prove `claude` is never invoked without one —
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
    || bad "the autopilot invoked claude with no command set — the /next class of bug is back"
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
    || bad "a pure queue consumer invoked claude on an EMPTY queue — it invented work"
[[ "$out" == *"idling"* ]] \
    && ok  "the idle is announced (an operator can tell 'waiting' from 'wedged')" \
    || bad "the idle cycle is silent: $out"

# 3. Positive control — the refusal must not have broken the actual loop. With a command set,
#    claude IS invoked, with exactly that prompt. Without this, tests 1-2 would pass on a
#    permanently broken autopilot.
out="$(run_autopilot 20 CLAUDE_AUTOPILOT_CMD=/build-the-thing CLAUDE_AUTOPILOT_MAX_RUNS=1 CLAUDE_AUTOPILOT_INTERVAL=0)"
[[ "$(invocations)" == "1" ]] \
    && ok  "CLAUDE_AUTOPILOT_CMD set → claude is invoked exactly once (MAX_RUNS=1) — the loop still works" \
    || bad "with a command set, claude was invoked $(invocations) times (expected 1): $out"
grep -q -- '-p /build-the-thing' "$APD/claude-invocations" \
    && ok  "the prompt passed to claude is CLAUDE_AUTOPILOT_CMD verbatim" \
    || bad "claude got the wrong prompt: $(cat "$APD/claude-invocations")"

echo
echo "== CC-BINS: a zero-turn 'Unknown command' is a FAILURE, not a healthy \$0 run =="

# THE TRAP, verified by hand against the then-pinned CLI (2.1.207):
#   $ claude -p "/typo" --output-format json ; echo $?
#   {"subtype":"success","is_error":false,"num_turns":0,"result":"Unknown command: /typo",
#    "total_cost_usd":0}
#   0
# Exit 0 and is_error:false — so the autopilot's success check scored it as a GOOD run. Left
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
#    MAX_RUNS is 0 (unlimited) and INTERVAL 1 — an unguarded loop would run many times in 6s.
out="$(run_autopilot_unk 6 CLAUDE_AUTOPILOT_CMD=/typo CLAUDE_AUTOPILOT_INTERVAL=1)"
[[ "$out" == *"nothing ran"* && "$out" == *"Unknown command: /typo"* ]] \
    && ok  "a zero-turn 'Unknown command' is reported as a failure, quoting what claude said" \
    || bad "the unknown-command no-op was NOT flagged — the loop counted it as a healthy run: $out"
[[ "$(invocations)" == "1" ]] \
    && ok  "it stops after the first unknown-command run (did not spin: 1 invocation, not many)" \
    || bad "the loop kept firing an unknown command ($(invocations)x in 6s) — the silent-green no-op is back"
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
    bad "queued unknown-command task was filed as DONE (done/: $(ls -A "$Q/done" 2>/dev/null), failed/: $(ls -A "$Q/failed" 2>/dev/null)) — unrun work marked complete"
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
echo "== CC-BINS: the outcome checks FAIL CLOSED — stderr can't be merged into the JSON =="

# THE FAIL-OPEN this closes. The real pinned CLI writes to STDERR when stdin is an open pipe
# with no data (verified: 157 bytes, "Warning: no stdin data received in 3s..."). The loop used
# to run `claude ... >"$out" 2>&1`, so that line landed in $out AHEAD of the JSON — $out was
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
# under failed/ — this is the exact case that silently landed in done/ before.
rm -rf "$APD/ehome"; mkdir -p "$APD/ehome/.claude/autopilot-queue/pending"
printf '/typo' > "$APD/ehome/.claude/autopilot-queue/pending/001-task"
out="$( : > "$APD/claude-invocations"
        timeout 6 env PATH="$APD/errbin:$PATH" HOME="$APD/ehome" \
            CLAUDE_AUTOPILOT_QUEUE=1 CLAUDE_AUTOPILOT_INTERVAL=1 CLAUDE_AUTOPILOT_QUEUE_DELAY=1 \
            bash "$AP" </dev/null 2>&1 || true )"
E="$APD/ehome/.claude/autopilot-queue"
if [[ -z "$(ls -A "$E/done" 2>/dev/null)" ]] && [[ -n "$(ls -A "$E/failed" 2>/dev/null)" ]]; then
    ok  "stderr on the CLI does NOT blind the checks — the poison task still lands in failed/, not done/"
else
    bad "FAIL-OPEN: with stderr present the run scored as success (done/: $(ls -A "$E/done" 2>/dev/null)) — unrun work marked complete"
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
echo "== CC-BINS: ANY zero-turn run is a no-op — not just the 'Unknown command' typo =="

# The predicate is `num_turns == 0` ALONE. It must NOT be narrowed to results whose text starts
# with "Unknown command:", because on the then-pinned CLI (2.1.207) EVERY slash command that exists
# but is unavailable headless returns the same zero-turn is_error:false exit-0 shape:
#   /help    → result:"/help isn't available in this environment."
#   /cost    → result:"You are currently using your subscription…"
#   /compact → result:""   ← no message at all
#   /clear   → result:""
# A string-matching guard files all of those to done/. Zero turns is zero work — full stop. These
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
    || bad "FAIL-OPEN: a /help-shaped zero-turn no-op was filed as DONE — the guard only catches typos"

zero_turn_stub quietbin ""
[[ "$(task_lands_in quietbin qthome)" == "failed" ]] \
    && ok  "a zero-turn run with NO message at all (/compact, /clear) is a failure, not done/" \
    || bad "FAIL-OPEN: a silent zero-turn no-op was filed as DONE — nothing ran and nothing was said"

# The other half of the rule: a run that DID invoke the model is a success, whatever it says —
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
echo "== CC-BINS: the check validates JSON *shape*, not just syntax (CLAUDE_EXTRA_ARGS=--verbose) =="

# THE SAME FAIL-OPEN, ONE LAYER UP. CLAUDE_EXTRA_ARGS is a documented, first-class tunable
# (.env.example, README, `claude-launch --extra-args`). Adding `--verbose` makes the pinned CLI
# emit a top-level ARRAY of stream messages rather than one result object — verified against
# the then-pinned 2.1.207. An array is VALID JSON, so a syntax-only check (`jq -e .`) passes it; then every field
# read against an array returns empty, is_error reads "" (not "true") and num_turns reads ""
# (not "0"), and BOTH guards silently disengage. And `--verbose` is exactly the flag an operator
# reaches for to ask "why is my autopilot doing nothing?" — so the debugging flag would recreate
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
    ok  "the --verbose ARRAY shape is still read — poison task lands in failed/, not done/"
else
    bad "FAIL-OPEN: a top-level array (valid JSON, wrong shape) disengaged the guards — task filed as done"
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
    bad "a good run under --verbose was wrongly failed — the shape check false-positives"
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
    ok  "an EMPTY run log fails closed (task → failed/) — 'jq -e .' exits 0 on empty; -s catches it"
else
    bad "FAIL-OPEN: an empty run log scored as SUCCESS (done/: $(ls -A "$M/done" 2>/dev/null))"
fi

echo
echo "== credential reconcile guard: creds_have_token refuses a tokenless (logged-out) copy =="

# 2026-07-15 incident: a claude.ai refresh-token expiry made Claude Code rewrite
# .credentials.json with EMPTY token fields (a logout). The reconcile loop took
# that freshly-mtimed, tokenless file as "newest wins" and published it to the
# shared /auth master and every container — one expiry became a fleet-wide
# "Login expired" blackout. The guard (creds_have_token) is EXTRACTED from
# entrypoint.sh here — not mirrored — so this test cannot silently drift from the
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
    ! creds_have_token "$CD/empty.json" && ok  "a logged-out (empty-token) credential is refused"  || bad "POISON: empty-token credential accepted — a logout would spread fleet-wide"
    ! creds_have_token "$CD/blank.json" && ok  "an empty file is refused"                           || bad "empty file accepted"
    ! creds_have_token "$CD/missing"    && ok  "a missing file is refused"                          || bad "missing file accepted"
    rm -rf "$CD"
else
    bad "could not extract creds_have_token() from entrypoint.sh — the guard test is a no-op"
fi

# Structural tripwire: reconcile_creds must gate propagation on creds_have_token and
# delegate the atomic move to publish_creds (no raw 'mv -f' that could republish a
# tokenless file). Locks the fix against an accidental revert to unguarded copying.
RECON_FN="$(awk '/^reconcile_creds\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$ENTRYPOINT")"
if [[ -n "$RECON_FN" ]] && grep -q 'creds_have_token' <<<"$RECON_FN" && ! grep -q 'mv -f' <<<"$RECON_FN"; then
    ok  "reconcile_creds gates every propagation on creds_have_token (no unguarded copy)"
else
    bad "reconcile_creds may copy without a token guard — a tokenless credential could spread"
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
echo "== $PASS passed, $FAIL failed =="
exit $(( FAIL > 0 ? 1 : 0 ))
