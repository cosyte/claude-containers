#!/usr/bin/env bash
# Unit tests for bin/claude-controller (CC-6) — NO docker, NO sysbox, NO real umbrella,
# NO real claude/broker/lease/bump-worker. Everything the controller shells out to
# (reconcile.sh, lease.sh, claude-worker-request, bump-worker.sh, claude-autopilot) is
# stubbed via a fixture umbrella + PATH.
#
# Covers:
#   1. slots = min(K, MAX_SLOTS); MAX_SLOTS defaults to 1 regardless of K, so a container
#      never auto-ramps past 1 just because K rose in the umbrella config.
#   2. slots==1 -> the autopilot path is chosen, and the launch it collapses to is
#      BYTE-IDENTICAL to running claude-autopilot directly (the headline non-regression).
#   3. CLAUDE_CONTROLLER_DRYRUN=1 prints the reconcile -> lease -> worker-request -> drain
#      plan for a stubbed K=2 frontier (two items, different repos) without touching
#      anything real.
#   4. The real controller_cycle path (slots=2, not DRYRUN) against stubbed
#      scripts/lease.sh + claude-worker-request + bump-worker.sh: exactly two dispatches
#      for two independent items, and exactly one drain call.
#   5. A refused lease.sh acquire on one item skips only that item — the loop continues
#      and still dispatches the other eligible item.
#   6. A multi-repo frontier line (comma-separated repo field) is skipped, never
#      mis-dispatched with a smuggled repo argument.
#   7. controller_frontier parses the real reconcile --frontier output shape, including
#      the cap line, "eligible-but-unpicked"/"promoted-by-aging" lines it must ignore, and
#      a reconcile error (fail-safe: no candidates, no crash).
#   8. Umbrella-absent dies (fail closed).
#
# The on-host proof (a real K=2 fixture with two real broker-launched workers, a third
# waiting for a slot, a real bump-worker drain, and a simulated controller-restart
# non-double-ship check) is bin/claude-controller-verify; deliberately NOT exercised here.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

PASS=0 FAIL=0
okp()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
badp() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

# ============================================================================================
# Part A — slots math + the K==1 byte-identical collapse (pure sourcing, no fixture needed)
# ============================================================================================
echo "== controller_slots: min(K, MAX_SLOTS); MAX_SLOTS defaults to 1 regardless of K =="

# A tiny umbrella config fixture so resolve_parallel_k (bin/_common.sh) has something to
# read — CLAUDE_PARALLEL_CONFIG points straight at it (an explicit path, per _common.sh's
# own lookup order), so this test never depends on the REAL umbrella's K.
CFG_K2="$TMPD/parallel-k2.json"; echo '{"K": 2}' > "$CFG_K2"
CFG_K4="$TMPD/parallel-k4.json"; echo '{"K": 4}' > "$CFG_K4"

t_slots() {  # t_slots <label> <cfg> <max-slots-env|""> <want>
    local label="$1" cfg="$2" maxenv="$3" want="$4" got
    got="$(env -i PATH="$PATH" HOME="$TMPD/home-slots" CLAUDE_PARALLEL_CONFIG="$cfg" ${maxenv:+CLAUDE_CONTROLLER_MAX_SLOTS="$maxenv"} \
        bash -c 'source "'"$REPO_ROOT"'/bin/claude-controller"; controller_slots' 2>/dev/null)"
    [[ "$got" == "$want" ]] && okp "$label (got $got)" || badp "$label (want $want, got '$got')"
}
t_slots "K=2, MAX_SLOTS unset (default 1) -> slots=1" "$CFG_K2" "" 1
t_slots "K=2, MAX_SLOTS=1 explicit -> slots=1" "$CFG_K2" 1 1
t_slots "K=4, MAX_SLOTS unset (default 1) -> slots=1 (never auto-ramps with K)" "$CFG_K4" "" 1
t_slots "K=2, MAX_SLOTS=5 -> slots=2 (min(K,MAX))" "$CFG_K2" 5 2
t_slots "K=4, MAX_SLOTS=2 -> slots=2 (min(K,MAX))" "$CFG_K4" 2 2

got_bad_max="$(env -i PATH="$PATH" HOME="$TMPD/home-slots" CLAUDE_PARALLEL_CONFIG="$CFG_K2" CLAUDE_CONTROLLER_MAX_SLOTS=0 \
    bash -c 'source "'"$REPO_ROOT"'/bin/claude-controller"; controller_slots' 2>&1)"; rc_bad_max=$?
if (( rc_bad_max != 0 )); then
    okp "CLAUDE_CONTROLLER_MAX_SLOTS=0 is refused (fail closed, never silently 0 slots)"
else
    badp "CLAUDE_CONTROLLER_MAX_SLOTS=0 must be refused (got '$got_bad_max')"
fi

echo
echo "== slots==1: the controller collapses to claude-autopilot, BYTE-IDENTICAL launch =="

# Prove byte-identical by stubbing `exec` is not possible from outside, so instead we run
# the controller with a stub `claude-autopilot` on PATH that just echoes argv/env markers,
# and compare against running that SAME stub directly — the controller's own dispatch to
# it (`exec "$bin"`, where $bin resolves to the sibling bin/claude-autopilot by absolute
# path) must produce output indistinguishable from a direct run.
STUBBIN="$TMPD/stubbin"
mkdir -p "$STUBBIN"
# The real claude-autopilot script path the controller execs is a fixed sibling path
# (dirname of BASH_SOURCE), so we exercise the REAL bin/claude-autopilot header (env dump)
# rather than a PATH-substitutable stub — this is what proves byte-identical, not a stand-in.
# claude-autopilot's first ~9 lines of stdout are deterministic config echoes that never
# touch `claude`/network as long as MAX_RUNS=1 and the claude() shim below no-ops.
FAKE_CLAUDE="$TMPD/fakebin"
mkdir -p "$FAKE_CLAUDE"
cat > "$FAKE_CLAUDE/claude" <<'EOF'
#!/usr/bin/env bash
# Never actually calls the network; emits a minimal valid JSON result so
# claude-autopilot's post-run accounting/logging path completes on one line.
echo '{"is_error": false, "result": "ok", "session_id": "stub-session", "total_cost_usd": 0, "num_turns": 1, "duration_ms": 1}'
EOF
chmod +x "$FAKE_CLAUDE/claude"

run_via_controller="$(env -i PATH="$FAKE_CLAUDE:$PATH" HOME="$TMPD/home-a" CLAUDE_PARALLEL_CONFIG="$CFG_K2" \
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
        -e '/^==> controller: effective slots=1/d' \
        -e 's/=== run #[0-9]+ \([0-9TZ]+\) ===/=== run ===/' \
        -e 's#/tmp/[^ ]*/home-[ab]#<HOME>#' \
        -e 's/^\[autopilot\] workspace:.*/[autopilot] workspace: <cwd>/' \
        <<<"$1"
}
if [[ "$(norm "$run_via_controller")" == "$(norm "$run_direct")" ]]; then
    okp "controller (slots=1) launch output is byte-identical to running claude-autopilot directly (mod timestamp/cwd/HOME)"
else
    badp "controller (slots=1) launch diverged from a direct claude-autopilot run:"
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

# ============================================================================================
# Part B — fixture umbrella for the slots>1 path: reconcile.sh / lease.sh /
# claude-worker-request / bump-worker.sh all stubbed on PATH.
# ============================================================================================
UMBRELLA="$TMPD/umbrella"
mkdir -p "$UMBRELLA/scripts" "$UMBRELLA/operations"
cat > "$UMBRELLA/.gitmodules" <<'EOF'
[submodule "hl7"]
	path = hl7
	url = git@github.com:cosyte/hl7.git
[submodule "mllp"]
	path = mllp
	url = git@github.com:cosyte/mllp.git
EOF

# A stub reconcile.sh whose --frontier output is EXACTLY the real script's shape (captured
# verbatim from a live run against this repo's own umbrella, generalized to a fixture with
# two independent items on two different repos — this is what makes the parser test honest).
cat > "$UMBRELLA/scripts/reconcile.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --frontier)
    echo "reconcile --frontier (mutually-independent unblocked unleased items, AGED→NOW→NEXT; cap = K − live = 2 − 0 = 2):"
    echo "  CC-A · hl7 (NOW)"
    echo "  CC-B · mllp (NOW)"
    echo "  promoted-by-aging: CC-A"
    echo "  eligible-but-unpicked (PAR-2.2 aging input): CC-C CC-D"
    ;;
  *) echo "reconcile: unsupported mode in stub" >&2; exit 64 ;;
esac
EOF
chmod +x "$UMBRELLA/scripts/reconcile.sh"

# A stub lease.sh that always succeeds (acquire) — used by the "happy path" dispatch test.
LEASE_LOG="$TMPD/lease.log"
cat > "$UMBRELLA/scripts/lease.sh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$LEASE_LOG"
case "\$1" in
  acquire) echo "lease: acquired \\\`\$2\\\` for '\$3'"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$UMBRELLA/scripts/lease.sh"

# A stub bump-worker.sh that just records it was called.
DRAIN_LOG="$TMPD/drain.log"
cat > "$UMBRELLA/scripts/bump-worker.sh" <<EOF
#!/usr/bin/env bash
echo "drain-called" >> "$DRAIN_LOG"
echo "bump-worker: nothing to drain"
exit 0
EOF
chmod +x "$UMBRELLA/scripts/bump-worker.sh"

# A stub claude-worker-request on PATH (the controller calls it unqualified, exactly like
# the real broker-request client) that records its args and always succeeds.
WREQ_LOG="$TMPD/wreq.log"
STUB_BIN="$TMPD/stubpath"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/claude-worker-request" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$WREQ_LOG"
echo "ok claude-worker-\$(echo "\$2" | tr '[:upper:]' '[:lower:]')"
exit 0
EOF
chmod +x "$STUB_BIN/claude-worker-request"

reset_logs() { : > "$LEASE_LOG"; : > "$DRAIN_LOG"; : > "$WREQ_LOG"; }

echo
echo "== CLAUDE_CONTROLLER_DRYRUN=1: prints the reconcile->lease->worker-request->drain plan =="
reset_logs
dry_out="$(env -i PATH="$STUB_BIN:$PATH" HOME="$TMPD/home-dry" CLAUDE_PARALLEL_CONFIG="$CFG_K2" \
    CLAUDE_CONTROLLER_MAX_SLOTS=2 CLAUDE_CONTROLLER_UMBRELLA="$UMBRELLA" \
    CLAUDE_CONTROLLER_ONESHOT=1 CLAUDE_CONTROLLER_DRYRUN=1 \
    bash "$REPO_ROOT/bin/claude-controller" 2>&1)"
if grep -q "TEST SEAM ACTIVE" <<<"$dry_out" && grep -q "reconcile.sh --frontier" <<<"$dry_out" \
   && grep -q "CC-A" <<<"$dry_out" && grep -q "CC-B" <<<"$dry_out" && grep -q "bump-worker.sh" <<<"$dry_out"; then
    okp "DRYRUN loudly warns and prints the full reconcile/lease/worker-request/drain plan"
else
    badp "DRYRUN output missing expected plan lines: $dry_out"
fi
if [[ ! -s "$LEASE_LOG" && ! -s "$WREQ_LOG" && ! -s "$DRAIN_LOG" ]]; then
    okp "DRYRUN touches nothing real — no lease/worker-request/drain calls were made"
else
    badp "DRYRUN must not call the real scripts (lease=$(cat "$LEASE_LOG" 2>/dev/null), wreq=$(cat "$WREQ_LOG" 2>/dev/null), drain=$(cat "$DRAIN_LOG" 2>/dev/null))"
fi

echo
echo "== controller_cycle (slots=2, real path): two independent items -> two dispatches, one drain =="
reset_logs
cyc_out="$(env -i PATH="$STUB_BIN:$PATH" HOME="$TMPD/home-cyc" CLAUDE_PARALLEL_CONFIG="$CFG_K2" \
    CLAUDE_CONTROLLER_MAX_SLOTS=2 CLAUDE_CONTROLLER_UMBRELLA="$UMBRELLA" \
    CLAUDE_CONTROLLER_ONESHOT=1 \
    bash "$REPO_ROOT/bin/claude-controller" 2>&1)"
nwreq="$(grep -c . "$WREQ_LOG" 2>/dev/null || echo 0)"
if [[ "$nwreq" == 2 ]]; then
    okp "exactly two claude-worker-request calls for the two independent frontier items"
else
    badp "expected exactly 2 worker-request calls, got $nwreq (log: $(cat "$WREQ_LOG" 2>/dev/null); ctl output: $cyc_out)"
fi
if grep -q "hl7 CC-A" "$WREQ_LOG" 2>/dev/null && grep -q "mllp CC-B" "$WREQ_LOG" 2>/dev/null; then
    okp "each item was requested against its OWN repo (hl7/CC-A, mllp/CC-B) — never swapped/merged"
else
    badp "worker-request args wrong (log: $(cat "$WREQ_LOG" 2>/dev/null))"
fi
ndrain="$(grep -c . "$DRAIN_LOG" 2>/dev/null || echo 0)"
if [[ "$ndrain" == 1 ]]; then
    okp "bump-worker.sh drain was called exactly once this cycle"
else
    badp "expected exactly 1 drain call, got $ndrain"
fi
nacquire="$(grep -c "^acquire " "$LEASE_LOG" 2>/dev/null || echo 0)"
if [[ "$nacquire" == 2 ]]; then
    okp "lease.sh acquire was called once per dispatched item (controller holds the lease, not the worker)"
else
    badp "expected 2 lease.sh acquire calls, got $nacquire (log: $(cat "$LEASE_LOG" 2>/dev/null))"
fi

echo
echo "== a refused lease.sh acquire skips only that item; the other still dispatches =="
REFUSING_UMBRELLA="$TMPD/umbrella-refuse"
mkdir -p "$REFUSING_UMBRELLA/scripts"
cp "$UMBRELLA/.gitmodules" "$REFUSING_UMBRELLA/"
cp "$UMBRELLA/scripts/reconcile.sh" "$REFUSING_UMBRELLA/scripts/"
cp "$UMBRELLA/scripts/bump-worker.sh" "$REFUSING_UMBRELLA/scripts/"
cat > "$REFUSING_UMBRELLA/scripts/lease.sh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$LEASE_LOG"
case "\$2" in
  CC-A) echo "lease: refused (already leased elsewhere)" >&2; exit 1 ;;
  *)    echo "lease: acquired \\\`\$2\\\` for '\$3'"; exit 0 ;;
esac
EOF
chmod +x "$REFUSING_UMBRELLA/scripts/lease.sh"
reset_logs
refuse_out="$(env -i PATH="$STUB_BIN:$PATH" HOME="$TMPD/home-refuse" CLAUDE_PARALLEL_CONFIG="$CFG_K2" \
    CLAUDE_CONTROLLER_MAX_SLOTS=2 CLAUDE_CONTROLLER_UMBRELLA="$REFUSING_UMBRELLA" \
    CLAUDE_CONTROLLER_ONESHOT=1 \
    bash "$REPO_ROOT/bin/claude-controller" 2>&1)"
nwreq2="$(grep -c . "$WREQ_LOG" 2>/dev/null || echo 0)"
if [[ "$nwreq2" == 1 ]] && grep -q "mllp CC-B" "$WREQ_LOG" 2>/dev/null && ! grep -q "CC-A" "$WREQ_LOG" 2>/dev/null; then
    okp "CC-A's refused lease skips ONLY CC-A; CC-B still dispatches — the loop continues, never crashes"
else
    badp "expected only CC-B dispatched after CC-A's lease refusal (log: $(cat "$WREQ_LOG" 2>/dev/null))"
fi
if grep -qi "warn" <<<"$refuse_out"; then
    okp "the refused acquire produces a visible warning (not silently swallowed)"
else
    badp "expected a warn line on the refused lease acquire"
fi

echo
echo "== a multi-repo frontier line is skipped, never mis-dispatched =="
MULTI_UMBRELLA="$TMPD/umbrella-multi"
mkdir -p "$MULTI_UMBRELLA/scripts"
cat > "$MULTI_UMBRELLA/.gitmodules" <<'EOF'
[submodule "crew"]
	path = crew
	url = git@github.com:cosyte/crew.git
[submodule "hl7"]
	path = hl7
	url = git@github.com:cosyte/hl7.git
EOF
cat > "$MULTI_UMBRELLA/scripts/reconcile.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --frontier)
    echo "reconcile --frontier (mutually-independent unblocked unleased items, AGED→NOW→NEXT; cap = K − live = 2 − 0 = 2):"
    echo "  CREW-ACK · crew, knowledgebase (NOW)"
    echo "  CC-A · hl7 (NOW)"
    ;;
esac
EOF
chmod +x "$MULTI_UMBRELLA/scripts/reconcile.sh"
cp "$UMBRELLA/scripts/lease.sh" "$MULTI_UMBRELLA/scripts/"
cp "$UMBRELLA/scripts/bump-worker.sh" "$MULTI_UMBRELLA/scripts/"
reset_logs
multi_out="$(env -i PATH="$STUB_BIN:$PATH" HOME="$TMPD/home-multi" CLAUDE_PARALLEL_CONFIG="$CFG_K2" \
    CLAUDE_CONTROLLER_MAX_SLOTS=2 CLAUDE_CONTROLLER_UMBRELLA="$MULTI_UMBRELLA" \
    CLAUDE_CONTROLLER_ONESHOT=1 \
    bash "$REPO_ROOT/bin/claude-controller" 2>&1)"
if grep -q "hl7 CC-A" "$WREQ_LOG" 2>/dev/null && ! grep -qi "CREW-ACK" "$WREQ_LOG" 2>/dev/null; then
    okp "the multi-repo item (CREW-ACK · crew, knowledgebase) is never dispatched; CC-A (single-repo) still is"
else
    badp "multi-repo handling wrong (log: $(cat "$WREQ_LOG" 2>/dev/null))"
fi
if grep -qi "multi-repo" <<<"$multi_out"; then
    okp "skipping the multi-repo item is loudly warned, not silent"
else
    badp "expected a warn about the skipped multi-repo item"
fi

# ============================================================================================
# Part C — controller_frontier parser, in isolation (sourced), against realistic shapes
# ============================================================================================
echo
echo "== controller_frontier: parses the real --frontier shape, ignores non-selection lines =="

# shellcheck disable=SC1091
source "$REPO_ROOT/bin/claude-controller"
set +e

FRONTIER_FIXTURE="$TMPD/frontier-fixture"
mkdir -p "$FRONTIER_FIXTURE/scripts"
cat > "$FRONTIER_FIXTURE/scripts/reconcile.sh" <<'EOF'
#!/usr/bin/env bash
echo "reconcile --frontier (mutually-independent unblocked unleased items, AGED→NOW→NEXT; cap = K − live = 2 − 1 = 1):"
echo "  PAR-3.2 · umbrella (NOW)"
echo "  eligible-but-unpicked (PAR-2.2 aging input): PAR-4.1 PW-7f PW-7g"
EOF
chmod +x "$FRONTIER_FIXTURE/scripts/reconcile.sh"
got_frontier="$(controller_frontier "$FRONTIER_FIXTURE")"
if [[ "$got_frontier" == "PAR-3.2 umbrella" ]]; then
    okp "controller_frontier extracts exactly the one selected item, ignoring eligible-but-unpicked"
else
    badp "controller_frontier parse wrong (got: '$got_frontier')"
fi

EMPTY_FIXTURE="$TMPD/frontier-empty"
mkdir -p "$EMPTY_FIXTURE/scripts"
cat > "$EMPTY_FIXTURE/scripts/reconcile.sh" <<'EOF'
#!/usr/bin/env bash
echo "reconcile --frontier (mutually-independent unblocked unleased items, AGED→NOW→NEXT; cap = K − live = 2 − 2 = 0):"
echo "  (empty — cap full: 2 live in-flight >= K=2)"
EOF
chmod +x "$EMPTY_FIXTURE/scripts/reconcile.sh"
got_empty="$(controller_frontier "$EMPTY_FIXTURE")"
if [[ -z "$got_empty" ]]; then
    okp "an '(empty — cap full...)' frontier yields zero candidates, not a parse artifact"
else
    badp "expected zero candidates from an empty frontier (got: '$got_empty')"
fi

ERROR_FIXTURE="$TMPD/frontier-error"
mkdir -p "$ERROR_FIXTURE/scripts"
cat > "$ERROR_FIXTURE/scripts/reconcile.sh" <<'EOF'
#!/usr/bin/env bash
echo "reconcile: BACKLOG.md not found" >&2
exit 66
EOF
chmod +x "$ERROR_FIXTURE/scripts/reconcile.sh"
err_out="$(controller_frontier "$ERROR_FIXTURE" 2>&1)"; err_rc=$?
if (( err_rc == 0 )) && grep -qi "warn" <<<"$err_out"; then
    okp "a reconcile.sh failure warns and yields no candidates (never crashes the loop, rc=0)"
else
    badp "expected a warn + rc=0 on reconcile failure (rc=$err_rc, out=$err_out)"
fi

echo
echo "== umbrella-absent: controller_locate_umbrella dies (fail closed) =="
NOWHERE="$TMPD/definitely-not-an-umbrella"
mkdir -p "$NOWHERE"
if ( CLAUDE_CONTROLLER_UMBRELLA="$NOWHERE" controller_locate_umbrella ) >/dev/null 2>&1; then
    badp "controller_locate_umbrella must refuse a directory with no .gitmodules/scripts/reconcile.sh"
else
    okp "controller_locate_umbrella refuses a non-umbrella directory (fail closed)"
fi
if ( env -u CLAUDE_CONTROLLER_UMBRELLA controller_locate_umbrella ) >/dev/null 2>&1; then
    # Only possible if the test host's /workspace happens to look like the umbrella —
    # acceptable (it legitimately does, in this fleet), so don't fail on that; just don't
    # count it either way. Skip silently.
    :
fi

echo
echo "== $PASS passed, $FAIL failed =="
exit $(( FAIL > 0 ? 1 : 0 ))
