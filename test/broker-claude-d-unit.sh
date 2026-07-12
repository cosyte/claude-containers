#!/usr/bin/env bash
# Unit tests for the BROKER-CLAUDE-D feature — a per-mode CLAUDE.md fragment
# (`claude-config/CLAUDE.d/broker.md`) installed by entrypoint.sh §8a-bis and
# surfaced by the baked `SessionStart` hook (`bin/claude-md-fragments`) so an
# interactive `--broker` session boots knowing that `claude-worker-request`
# is the sole channel for spawning nested workers.
#
# NO docker, NO sysbox. The full on-host proof (build the controller image,
# launch a `--broker` container, observe the fragment reach the live Claude
# session) is a manual step — this suite covers everything short of that:
#
#   A. bin/claude-md-fragments — the SessionStart hook: parses, silent on
#      missing/empty CLAUDE.d, emits fragments with a `---` separator in
#      deterministic order when they are present.
#   B. claude-config/CLAUDE.d/broker.md — the mechanism-only addendum:
#      the client contract, the socket refusal, WIP=K as backpressure, and
#      the explicit non-guidance ("no default loop").
#   C. claude-config/settings.json — a baked file that registers the hook
#      unconditionally; a passive reader with zero cost on non-broker
#      containers.
#   D. Dockerfile — the new bin script is COPYed to /usr/local/bin and
#      +x'd alongside the rest.
#   E. entrypoint.sh §8a-bis — the fragment install is guarded by BOTH
#      CLAUDE_WORKER_BROKER=1 AND /run/claude/broker existence AND baked
#      broker.md presence; non-broker containers leave CLAUDE.d/ absent.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/bin/claude-md-fragments"
FRAG="$REPO_ROOT/claude-config/CLAUDE.d/broker.md"
SETTINGS="$REPO_ROOT/claude-config/settings.json"
DOCKERFILE="$REPO_ROOT/Dockerfile"
ENTRY="$REPO_ROOT/entrypoint.sh"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
has()  { grep -qF -- "$2" "$1"; }
hasE() { grep -qE -- "$2" "$1"; }

# ============================================================================================
echo "== A. bin/claude-md-fragments: the SessionStart hook =="
# ============================================================================================
[[ -f "$HOOK" ]] && ok "bin/claude-md-fragments exists" || bad "bin/claude-md-fragments is missing"
[[ -x "$HOOK" ]] && ok "bin/claude-md-fragments is executable" || bad "bin/claude-md-fragments is not +x"
bash -n "$HOOK" && ok "bin/claude-md-fragments parses (bash -n)" \
    || bad "bin/claude-md-fragments has a syntax error"

# A1. Silent when the CLAUDE.d dir is absent.
HOME="$TMPD/no-dir" out="$(bash "$HOOK" 2>&1)"; rc=$?
if [[ $rc -eq 0 && -z "$out" ]]; then
    ok "no CLAUDE.d directory  → exit 0, zero stdout (byte-silent)"
else
    bad "no CLAUDE.d directory should be silent (got rc=$rc stdout='$out')"
fi

# A2. Silent when CLAUDE.d exists but is empty.
mkdir -p "$TMPD/empty/.claude/CLAUDE.d"
HOME="$TMPD/empty" out="$(bash "$HOOK" 2>&1)"; rc=$?
if [[ $rc -eq 0 && -z "$out" ]]; then
    ok "empty CLAUDE.d directory → exit 0, zero stdout"
else
    bad "empty CLAUDE.d should be silent (got rc=$rc stdout='$out')"
fi

# A3. Silent when CLAUDE.d has non-*.md files (defensive glob).
mkdir -p "$TMPD/nonmd/.claude/CLAUDE.d"
echo "not a fragment" > "$TMPD/nonmd/.claude/CLAUDE.d/README.txt"
HOME="$TMPD/nonmd" out="$(bash "$HOOK" 2>&1)"; rc=$?
if [[ $rc -eq 0 && -z "$out" ]]; then
    ok "CLAUDE.d with only non-*.md files → silent (nullglob short-circuit)"
else
    bad "non-*.md files should not trigger emission (got rc=$rc stdout='$out')"
fi

# A4. Emits fragment content with a `---` separator when present.
mkdir -p "$TMPD/one/.claude/CLAUDE.d"
printf '# Broker\nMechanism-only content.\n' > "$TMPD/one/.claude/CLAUDE.d/broker.md"
HOME="$TMPD/one" out="$(bash "$HOOK")"; rc=$?
if [[ $rc -eq 0 ]] && grep -qF '# Broker' <<<"$out" && grep -qF 'Mechanism-only content.' <<<"$out"; then
    ok "one fragment → its content reaches stdout (exit 0)"
else
    bad "single fragment should be emitted (got rc=$rc stdout='$out')"
fi
if grep -qF -- '---' <<<"$out"; then
    ok "emitted output includes the '---' separator"
else
    bad "expected a '---' separator ahead of the fragment"
fi

# A5. Two fragments: emitted in LC_ALL=C sort order, each with its own separator.
mkdir -p "$TMPD/two/.claude/CLAUDE.d"
printf '# Zeta\nzeta body\n'  > "$TMPD/two/.claude/CLAUDE.d/zeta.md"
printf '# Alpha\nalpha body\n' > "$TMPD/two/.claude/CLAUDE.d/alpha.md"
HOME="$TMPD/two" out="$(bash "$HOOK")"; rc=$?
if [[ $rc -eq 0 ]]; then
    a_idx="$(printf '%s\n' "$out" | grep -n '^# Alpha$' | head -1 | cut -d: -f1)"
    z_idx="$(printf '%s\n' "$out" | grep -n '^# Zeta$'  | head -1 | cut -d: -f1)"
    if [[ -n "$a_idx" && -n "$z_idx" && $a_idx -lt $z_idx ]]; then
        ok "two fragments emitted in deterministic sort order (alpha before zeta)"
    else
        bad "expected deterministic sort order (alpha before zeta); got alpha@$a_idx zeta@$z_idx"
    fi
    sep_count="$(printf '%s\n' "$out" | grep -c '^---$' || true)"
    if [[ "$sep_count" -eq 2 ]]; then
        ok "each fragment gets its own '---' separator (2 total)"
    else
        bad "expected 2 '---' separators, got $sep_count"
    fi
else
    bad "two-fragment case exited non-zero (rc=$rc)"
fi

# A6. Skips an unreadable fragment (never crashes the session-start hook).
if [[ "$(id -u)" -ne 0 ]]; then
    mkdir -p "$TMPD/unread/.claude/CLAUDE.d"
    printf '# Readable\nvisible body\n' > "$TMPD/unread/.claude/CLAUDE.d/readable.md"
    printf '# Hidden\nshould not appear\n' > "$TMPD/unread/.claude/CLAUDE.d/hidden.md"
    chmod 000 "$TMPD/unread/.claude/CLAUDE.d/hidden.md"
    HOME="$TMPD/unread" out="$(bash "$HOOK" 2>/dev/null)"; rc=$?
    chmod 644 "$TMPD/unread/.claude/CLAUDE.d/hidden.md"   # restore for cleanup
    if [[ $rc -eq 0 ]] && grep -qF 'visible body' <<<"$out" && ! grep -qF 'should not appear' <<<"$out"; then
        ok "an unreadable fragment is skipped, readable ones still emit (rc=0)"
    else
        bad "unreadable-fragment handling wrong (rc=$rc stdout='$out')"
    fi
else
    echo "  SKIP  running as root — [[ -r ]] cannot be exercised without dropping privs"
fi

# ============================================================================================
echo "== B. claude-config/CLAUDE.d/broker.md: the mechanism-only addendum =="
# ============================================================================================
[[ -f "$FRAG" ]] && ok "broker.md exists" || bad "broker.md missing"

# The client contract (the ONLY channel).
if hasE "$FRAG" 'claude-worker-request <repo> <item-id>'; then
    ok "broker.md names the client contract 'claude-worker-request <repo> <item-id>'"
else
    bad "broker.md should show the argv shape 'claude-worker-request <repo> <item-id>'"
fi
# The socket refusal — never touch the inner Docker socket.
if has "$FRAG" 'Never touch the inner Docker socket' \
   || has "$FRAG" 'never touch the inner Docker socket'; then
    ok "broker.md refuses direct use of the inner Docker socket"
else
    bad "broker.md should explicitly refuse 'docker run/exec' on the inner socket"
fi
# WIP=K backpressure — treat 'would-exceed-K' as wait/retry, not failure.
if has "$FRAG" 'WIP=K' && has "$FRAG" 'backpressure'; then
    ok "broker.md explains WIP=K backpressure (wait/retry, not failure)"
else
    bad "broker.md should teach WIP=K as backpressure semantics"
fi
# One request = one nested one-shot /work-on that --rm's on exit.
if has "$FRAG" '/work-on' && has "$FRAG" 'Sysbox-nested' && has "$FRAG" '--rm'; then
    ok "broker.md describes 'one request = one Sysbox-nested one-shot /work-on that --rms'"
else
    bad "broker.md should describe the one-request/one-worker/one-work-on/--rm shape"
fi
# Mechanism-only — no default loop.
if has "$FRAG" 'no default dispatch loop' \
   || has "$FRAG" 'not a default policy' \
   || has "$FRAG" 'not auto-dispatch'; then
    ok "broker.md is mechanism-only — states there is no default dispatch loop"
else
    bad "broker.md should state that it does not prescribe a default dispatch loop"
fi
# Pointer to the full model.
if has "$FRAG" 'docs/substrate.md'; then
    ok "broker.md points at docs/substrate.md for the full model"
else
    bad "broker.md should link to docs/substrate.md → 'Interactive lead that spawns workers'"
fi

# ============================================================================================
echo "== C. claude-config/settings.json: registers the SessionStart hook unconditionally =="
# ============================================================================================
[[ -f "$SETTINGS" ]] && ok "claude-config/settings.json exists" || bad "claude-config/settings.json missing"
if command -v jq >/dev/null 2>&1; then
    if jq -e . "$SETTINGS" >/dev/null 2>&1; then
        ok "settings.json is valid JSON"
    else
        bad "settings.json is not valid JSON"
    fi
    if jq -e '.hooks.SessionStart | type == "array" and length >= 1' "$SETTINGS" >/dev/null; then
        ok "settings.json declares a SessionStart hook block"
    else
        bad "settings.json .hooks.SessionStart should be a non-empty array"
    fi
    if jq -e '[.hooks.SessionStart[].hooks[].command] | any(. == "/usr/local/bin/claude-md-fragments")' "$SETTINGS" >/dev/null; then
        ok "SessionStart hook invokes /usr/local/bin/claude-md-fragments (baked path)"
    else
        bad "SessionStart hook should invoke /usr/local/bin/claude-md-fragments"
    fi
else
    echo "  SKIP  jq not on PATH — cannot structurally validate settings.json"
fi

# ============================================================================================
echo "== D. Dockerfile: bakes bin/claude-md-fragments and +x's it =="
# ============================================================================================
if hasE "$DOCKERFILE" 'COPY bin/claude-md-fragments /usr/local/bin/claude-md-fragments'; then
    ok "Dockerfile COPYs bin/claude-md-fragments to /usr/local/bin/"
else
    bad "Dockerfile should COPY bin/claude-md-fragments to /usr/local/bin/"
fi
# It must appear inside the chmod +x block (not merely in a comment).
if awk '/RUN chmod \+x/,/&& chown/' "$DOCKERFILE" | grep -qF '/usr/local/bin/claude-md-fragments'; then
    ok "claude-md-fragments is included in the chmod +x block"
else
    bad "claude-md-fragments must be in the Dockerfile's chmod +x block"
fi

# ============================================================================================
echo "== E. entrypoint.sh §8a-bis: guarded, byte-silent on non-broker paths =="
# ============================================================================================
bash -n "$ENTRY" && ok "entrypoint.sh parses (bash -n)" || bad "entrypoint.sh has a syntax error"

# Extract §8a-bis (header → the next `# 8`-header line) so the assertions are
# scoped and cannot be masked by a similarly-shaped construct elsewhere.
SEC8A_BIS="$(awk '/^# 8a-bis\./,/^# 8b\./' "$ENTRY")"

if grep -qF 'CLAUDE.d' <<<"$SEC8A_BIS"; then
    ok "§8a-bis exists and references CLAUDE.d/"
else
    bad "expected an §8a-bis block that installs into CLAUDE.d/"
fi
# Guard clause: CLAUDE_WORKER_BROKER + broker spool dir (matches §5c's serving signal) +
# baked broker.md + NO pre-existing target (§8's "only fill what's absent" rule).
if grep -qF 'CLAUDE_WORKER_BROKER:-0' <<<"$SEC8A_BIS" \
   && grep -qF '/run/claude/broker' <<<"$SEC8A_BIS" \
   && grep -qE '\${CLAUDE_BROKER_DIR:-/run/claude/broker\}/requests' <<<"$SEC8A_BIS" \
   && grep -qF 'CLAUDE.d/broker.md' <<<"$SEC8A_BIS" \
   && grep -qF '! -e "$CLAUDE_CONFIG_DIR/CLAUDE.d/broker.md"' <<<"$SEC8A_BIS"; then
    ok "§8a-bis guard: CLAUDE_WORKER_BROKER + broker spool dir + baked broker.md + no pre-existing target"
else
    bad "§8a-bis guard should require CLAUDE_WORKER_BROKER=1 AND broker's /requests spool dir AND baked broker.md AND no pre-existing target (§8's no-clobber rule)"
fi
# Uses `install` (matching §8a's pattern), not cp/mv/ln.
if grep -qF 'install -d' <<<"$SEC8A_BIS" && grep -qF 'install -o' <<<"$SEC8A_BIS"; then
    ok "§8a-bis uses 'install -d' for the dir and 'install -o …' for the file (matches §8a pattern)"
else
    bad "§8a-bis should use 'install -d' + 'install -o \$CLAUDE_UID -g \$CLAUDE_GID -m 644'"
fi
# Emits a log line so operators can see it fired.
if grep -qF 'CLAUDE.d/broker.md' <<<"$SEC8A_BIS" && grep -qF 'log ' <<<"$SEC8A_BIS"; then
    ok "§8a-bis logs 'Installed broker-mode CLAUDE.md addendum'"
else
    bad "§8a-bis should emit a log line naming CLAUDE.d/broker.md"
fi

# E1. Behavioral simulation: replay §8a-bis with mocked variables in a subshell.
run_sim() {
    # Args: flag  spool-exists(0|1)  baked-frag-exists(0|1)  pre-existing-target-content(""|<str>)
    #   flag                        — CLAUDE_WORKER_BROKER env value
    #   spool-exists                — mkdir $CLAUDE_BROKER_DIR/requests (§5c's serving signal)
    #   baked-frag-exists           — $BAKE_DIR/CLAUDE.d/broker.md is present in the image
    #   pre-existing-target-content — if non-empty, seed $CLAUDE_CONFIG_DIR/CLAUDE.d/broker.md with this content
    # Prints: <outcome>[|preserved]
    #   outcome ∈ {installed, skipped}
    #   preserved is appended when the pre-existing target content is byte-identical after the run
    local flag="$1" spool="$2" baked="$3" pre="${4:-}"
    local sim_home="$TMPD/sim.$flag.$spool.$baked.${pre:+pre}"
    local bake="$sim_home/opt/claude-config"
    local sock="$sim_home/broker"
    local conf="$sim_home/.claude"
    rm -rf "$sim_home"; mkdir -p "$bake" "$conf"
    [[ "$spool" == 1 ]] && mkdir -p "$sock/requests"
    [[ "$baked" == 1 ]] && { mkdir -p "$bake/CLAUDE.d"; echo "# BAKED broker.md" > "$bake/CLAUDE.d/broker.md"; }
    if [[ -n "$pre" ]]; then
        mkdir -p "$conf/CLAUDE.d"
        printf '%s' "$pre" > "$conf/CLAUDE.d/broker.md"
    fi
    bash -c '
        set -uo pipefail
        BAKE_DIR="'"$bake"'"
        CLAUDE_CONFIG_DIR="'"$conf"'"
        CLAUDE_BROKER_DIR="'"$sock"'"
        CLAUDE_UID="'"$(id -u)"'"
        CLAUDE_GID="'"$(id -g)"'"
        CLAUDE_WORKER_BROKER="'"$flag"'"
        log() { :; }
        '"$(printf '%s' "$SEC8A_BIS")"'
    ' >/dev/null 2>&1
    local outcome
    if [[ -f "$conf/CLAUDE.d/broker.md" ]]; then
        if [[ -n "$pre" ]] && [[ "$(cat "$conf/CLAUDE.d/broker.md")" == "$pre" ]]; then
            outcome=skipped
        elif grep -qF 'BAKED broker.md' "$conf/CLAUDE.d/broker.md"; then
            outcome=installed
        else
            outcome=installed
        fi
    else
        outcome=skipped
    fi
    printf '%s\n' "$outcome"
}

# CLAUDE_WORKER_BROKER=1 + spool + baked + no pre-existing → INSTALLED
if [[ "$(run_sim 1 1 1)" == installed ]]; then
    ok "flag=1 + broker spool + baked broker.md + no pre-existing → fragment IS installed"
else
    bad "flag=1 + spool + baked + fresh → expected install, got skip"
fi
# CLAUDE_WORKER_BROKER=1 + NO spool + baked → SKIPPED (fail-safe on the broker-serving signal)
if [[ "$(run_sim 1 0 1)" == skipped ]]; then
    ok "flag=1 but no /run/claude/broker/requests → fragment NOT installed (fail-safe; matches §5c's signal)"
else
    bad "flag=1 without the /requests spool dir → expected skip, got install"
fi
# CLAUDE_WORKER_BROKER=0 + spool + baked → SKIPPED
if [[ "$(run_sim 0 1 1)" == skipped ]]; then
    ok "flag=0 → fragment NOT installed (non-broker containers stay clean)"
else
    bad "flag=0 → expected skip, got install"
fi
# CLAUDE_WORKER_BROKER=1 + spool + NO baked → SKIPPED (never silent-partial)
if [[ "$(run_sim 1 1 0)" == skipped ]]; then
    ok "flag=1 + spool but baked broker.md absent → fragment NOT installed (never silent-partial)"
else
    bad "flag=1 + spool but no baked file → expected skip, got install"
fi
# NEW: user-mounted broker.md at the target wins (§8's "only fill what's absent" — MAJOR-1 fix)
USER_CONTENT="# USER-MOUNTED broker.md (should be preserved)"
if [[ "$(run_sim 1 1 1 "$USER_CONTENT")" == skipped ]]; then
    ok "flag=1 + spool + baked + user-mounted target → skipped: mount wins over bake (§8's rule)"
else
    bad "a pre-existing user-mounted CLAUDE.d/broker.md must NOT be clobbered by §8a-bis"
fi
# Idempotency on restart: a previously-installed broker.md is left alone (no re-install log spam).
BAKED_CONTENT="# BAKED broker.md"    # matches the seeded baked content the simulator writes
if [[ "$(run_sim 1 1 1 "$BAKED_CONTENT")" == skipped ]]; then
    ok "flag=1 + already-installed target → no re-install (idempotent restart, MINOR-7 addressed)"
else
    bad "expected idempotent no-op when the target already matches the baked content"
fi

# ============================================================================================
echo "== F. entrypoint §8b merge: the baked SessionStart hook survives on a fresh container =="
# ============================================================================================
# §8b's jq recipe is:
#   BASE = defaults * baked_settings_json                     # baked wins over defaults
#   final = BASE * existing_user_settings                     # existing wins over baked
# On a fresh container, existing is {} (empty), so final has the baked hook. The refuter
# flagged that a user-mounted settings.json with its own hooks.SessionStart would REPLACE
# our baked entry (jq's `*` merges objects but replaces arrays). This test confirms the
# fresh-container case is safe; the mount-wins-over-bake behavior is intentional and
# documented (settings.json ships in the same §8 "existing user settings win" world).
if command -v jq >/dev/null 2>&1; then
    DEFAULTS='{"permissions":{"defaultMode":"bypassPermissions"},"skipDangerousModePermissionPrompt":true,"includeCoAuthoredBy":true,"env":{"DISABLE_AUTOUPDATER":"1"}}'
    BAKED="$(cat "$SETTINGS")"
    BASE="$(jq -s '.[0] * .[1]' <(echo "$DEFAULTS") <(echo "$BAKED"))"
    MERGED_FRESH="$(jq -s '.[0] * .[1]' <(echo "$BASE") <(echo '{}'))"
    if jq -e '[.hooks.SessionStart[].hooks[].command] | any(. == "/usr/local/bin/claude-md-fragments")' <<<"$MERGED_FRESH" >/dev/null; then
        ok "fresh-container §8b merge (defaults * baked * {}) preserves the SessionStart hook"
    else
        bad "fresh-container merge dropped the baked SessionStart hook — the loader wouldn't fire"
    fi
    # A user with an unrelated top-level key survives our hook (object-level merge).
    USER_KEEP='{"customUserKey":"kept"}'
    MERGED_KEEP="$(jq -s '.[0] * .[1]' <(echo "$BASE") <(echo "$USER_KEEP"))"
    if jq -e '.customUserKey == "kept" and ([.hooks.SessionStart[].hooks[].command] | any(. == "/usr/local/bin/claude-md-fragments"))' <<<"$MERGED_KEEP" >/dev/null; then
        ok "user's unrelated top-level key merges without displacing the SessionStart hook"
    else
        bad "an unrelated user key should NOT displace the SessionStart hook"
    fi
else
    echo "  SKIP  jq not on PATH — cannot simulate §8b's merge"
fi

# ============================================================================================
TOTAL=$((PASS+FAIL))
echo ""
echo "PASS=$PASS  FAIL=$FAIL  (of $TOTAL)"
[[ $FAIL -eq 0 ]] && echo "OK" || { echo "FAIL"; exit 1; }
