#!/usr/bin/env bash
# Unit tests for bin/claude-controller — NO docker, NO real umbrella, NO real claude.
#
# SC-5 removed the broker-dispatch tier (K>1 lease/worker-request/drain loop) this
# script used to run; what's left is a pass-through to claude-autopilot. Covers:
#   1. the launch it collapses to is BYTE-IDENTICAL to running claude-autopilot directly
#      (the one behavior this wrapper exists to preserve).
#   2. controller_run_autopilot execs the sibling bin/claude-autopilot verbatim — no flag
#      translation, no wrapper argv.
#   3. claude-controller never issues a git commit/push itself (it has no umbrella-writing
#      role at all now — a follow-up item, SC-6, decides whether this tier survives).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

PASS=0 FAIL=0
okp()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
badp() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

echo "== claude-controller: pass-through to claude-autopilot, BYTE-IDENTICAL launch =="

# Prove byte-identical by running the controller with a stub `claude` on PATH that never
# touches the network, and comparing its output against running bin/claude-autopilot
# (the real sibling script the controller execs) directly under the same stub.
FAKE_CLAUDE="$TMPD/fakebin"
mkdir -p "$FAKE_CLAUDE"
cat > "$FAKE_CLAUDE/claude" <<'EOF'
#!/usr/bin/env bash
# Never actually calls the network; emits a minimal valid JSON result so
# claude-autopilot's post-run accounting/logging path completes on one line.
echo '{"is_error": false, "result": "ok", "session_id": "stub-session", "total_cost_usd": 0, "num_turns": 1, "duration_ms": 1}'
EOF
chmod +x "$FAKE_CLAUDE/claude"

run_via_controller="$(env -i PATH="$FAKE_CLAUDE:$PATH" HOME="$TMPD/home-a" \
    CLAUDE_AUTOPILOT_MAX_RUNS=1 CLAUDE_AUTOPILOT_INTERVAL=0 \
    bash "$REPO_ROOT/bin/claude-controller" 2>&1)"
run_direct="$(env -i PATH="$FAKE_CLAUDE:$PATH" HOME="$TMPD/home-b" \
    CLAUDE_AUTOPILOT_MAX_RUNS=1 CLAUDE_AUTOPILOT_INTERVAL=0 \
    bash "$REPO_ROOT/bin/claude-autopilot" 2>&1)"

# What must be byte-identical is the AUTOPILOT PROCESS'S OWN launch (its argv/env and
# everything it prints) — not the controller wrapper's one-line banner before it execs, and
# not values that legitimately vary per invocation (a run timestamp, or a log path derived
# from a per-test HOME here — both containers/HOMEs use the identical $HOME/.claude/... shape
# in real deployment). So: drop the controller's own pre-exec banner line (it never reaches
# the real autopilot's stdout — `exec` replaces the process; this is purely the wrapper
# announcing what it's about to do), then normalize the run-timestamp and HOME-derived paths.
norm() {
    sed -E \
        -e '/^==> controller: pass-through to claude-autopilot/d' \
        -e 's/=== run #[0-9]+ \([0-9TZ]+\) ===/=== run ===/' \
        -e 's#/tmp/[^ ]*/home-[ab]#<HOME>#' \
        -e 's/^\[autopilot\] workspace:.*/[autopilot] workspace: <cwd>/' \
        <<<"$1"
}
if [[ "$(norm "$run_via_controller")" == "$(norm "$run_direct")" ]]; then
    okp "controller launch output is byte-identical to running claude-autopilot directly (mod timestamp/cwd/HOME)"
else
    badp "controller launch diverged from a direct claude-autopilot run:"
    diff <(norm "$run_via_controller") <(norm "$run_direct") | sed 's/^/        /' | head -20
fi

# Belt-and-suspenders on the ACTUAL non-regression claim ("the launch command + env are
# unchanged"): assert the controller's exec line names the exact same script bin/claude-autopilot
# invokes when run directly — grep the source rather than re-deriving argv, since `exec`
# leaves no separate child process to introspect from outside.
if grep -qE '^\s*exec bash "\$bin"' "$REPO_ROOT/bin/claude-controller" \
   && grep -qE 'bin="\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)/claude-autopilot"' "$REPO_ROOT/bin/claude-controller"; then
    okp "controller_run_autopilot execs the sibling bin/claude-autopilot verbatim (no flag translation, no wrapper argv)"
else
    badp "controller_run_autopilot must exec bin/claude-autopilot with no argv translation"
fi

echo
echo "== claude-controller: no umbrella-writing role — never commits/pushes itself =="
if ! grep -qE '\bgit (commit|push)\b' "$REPO_ROOT/bin/claude-controller"; then
    okp "claude-controller contains no direct git commit/push (it has no dispatch/drain role after SC-5)"
else
    badp "claude-controller must never commit/push directly"
fi

echo
echo "== $PASS passed, $FAIL failed =="
exit $(( FAIL > 0 ? 1 : 0 ))
