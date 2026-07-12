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

echo
echo "== $PASS passed, $FAIL failed =="
exit $(( FAIL > 0 ? 1 : 0 ))
