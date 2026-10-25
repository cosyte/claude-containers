#!/usr/bin/env bash
# Unit tests for test/run-all.sh (the `npm test` runner), against fake suites: NO docker, NO root.
#   - every suite runs, picked up by the glob (unit.sh and *-unit.sh, nothing else)
#   - one failing suite makes the run exit nonzero, and the others still run and pass
#   - logs print whole and in the fixed order, whatever order the suites finish in
#   - the summary names every suite with PASS/FAIL and seconds, and the elapsed total
#   - TEST_JOBS caps how many run at once; a bad TEST_JOBS refuses
#   - TEST_SUITE_TIMEOUT (default 300) ends a hung suite as TIMEOUT, by name; a bad value refuses
# shellcheck source=test/lib/prelude.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/prelude.sh"
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$REPO_ROOT/test/run-all.sh"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

# fake <dir> <name> <exit> <sleep>: a suite that marks it ran, notes the concurrency, and exits
fake() {
    cat >"$1/$2" <<EOF
#!/usr/bin/env bash
mkdir "$1/.run.\$\$" && n=\$(ls -d "$1"/.run.* | wc -l) && echo "\$n" >>"$1/.peak"
echo "out of $2"
sleep $4
rmdir "$1/.run.\$\$"
exit $3
EOF
    chmod +x "$1/$2"
}

# --- two fakes, one failing ---------------------------------------------------------------
D="$TMPD/two"; mkdir "$D"
fake "$D" a-unit.sh 0 0.4
fake "$D" b-unit.sh 3 0.1
out="$(TEST_DIR="$D" "$RUN" 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && ok "a failing suite exits nonzero" || bad "a failing suite exits nonzero (rc=$rc)"
grep -q '^  PASS  a-unit.sh' <<<"$out" && ok "the passing suite is PASS in the summary" || bad "a-unit.sh PASS: $out"
grep -q '^  FAIL  b-unit.sh .*(exit 3)' <<<"$out" && ok "the failing suite is FAIL with its exit status" || bad "b-unit.sh FAIL: $out"
grep -Eq '^run-all: 2 suites, 1 failed, .*elapsed [0-9]+s$' <<<"$out" && ok "the last line counts failures and prints elapsed seconds" || bad "summary line: $out"
# b finishes first, but a's log prints first and whole
order="$(grep -E '^(=== |out of)' <<<"$out" | head -4 | tr '\n' '|')"
[[ "$order" == "=== a-unit.sh|out of a-unit.sh|=== b-unit.sh|out of b-unit.sh|" ]] \
    && ok "logs print in the fixed order, whole" || bad "log order: $order"

# --- a suite whose runner dies leaves no result: FAIL, never the previous suite's PASS -------
D="$TMPD/dies"; mkdir "$D"
fake "$D" a-unit.sh 0 0
# its parent is timeout; the runner is timeout's parent
printf '#!/usr/bin/env bash\necho "out of b-unit.sh"\nread -r _ _ _ runner _ </proc/$PPID/stat\nkill -9 "$runner"\n' >"$D/b-unit.sh"; chmod +x "$D/b-unit.sh"
fake "$D" c-unit.sh 0 0
out="$(TEST_DIR="$D" "$RUN" 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q '^  FAIL  b-unit.sh .*no result' <<<"$out" \
    && ok "a suite with no result is FAIL and the run exits nonzero" || bad "dead runner (rc=$rc): $out"
grep -q '^out of c-unit.sh' <<<"$out" && ok "later suites' logs still print" || bad "c-unit.sh log missing: $out"

# --- all pass; the glob; the jobs cap ------------------------------------------------------
D="$TMPD/many"; mkdir "$D"
fake "$D" unit.sh 0 0.3
for n in c d e f; do fake "$D" "$n-unit.sh" 0 0.6; done
fake "$D" smoke.sh 1 0          # not a unit suite: never run
fake "$D" helper.sh 1 0
out="$(TEST_DIR="$D" TEST_JOBS=2 "$RUN" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && ok "all passing exits 0" || bad "all passing (rc=$rc): $out"
grep -q '^run-all: 5 suites, 0 failed, 2 jobs' <<<"$out" && ok "unit.sh and every *-unit.sh run, nothing else" || bad "suite count: $out"
grep -q '^  PASS  unit.sh' <<<"$out" && [[ "$(grep -m1 '^=== ' <<<"$out")" == "=== unit.sh" ]] \
    && ok "unit.sh runs and prints first" || bad "unit.sh first: $out"
grep -Eq 'smoke.sh|helper.sh' <<<"$out" && bad "a non-suite ran: $out" || ok "smoke.sh and helpers are not suites"
peak="$(sort -n "$D/.peak" | tail -1)"
[[ "$peak" == 2 ]] && ok "TEST_JOBS=2 runs two at once, never more" || bad "peak concurrency $peak, want 2"

out="$(TEST_DIR="$D" TEST_JOBS=0 "$RUN" 2>&1)"; rc=$?
[[ $rc -eq 2 ]] && grep -q 'TEST_JOBS must be a positive integer' <<<"$out" \
    && ok "TEST_JOBS=0 refuses" || bad "TEST_JOBS=0 (rc=$rc): $out"
mkdir "$TMPD/empty"
TEST_DIR="$TMPD/empty" "$RUN" >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "no suites at all refuses" || bad "empty dir rc=$rc"

# --- TEST_SUITE_TIMEOUT --------------------------------------------------------------------
test_sleeping_suite_times_out_by_name() {
    local D="$TMPD/slow" out rc t0
    mkdir "$D"
    printf '#!/usr/bin/env bash\nsleep 60\n' >"$D/slow-unit.sh"; chmod +x "$D/slow-unit.sh"
    fake "$D" ok-unit.sh 0 0
    t0=$SECONDS
    out="$(TEST_DIR="$D" TEST_SUITE_TIMEOUT=1 "$RUN" 2>&1)"; rc=$?
    (( rc != 0 && SECONDS - t0 < 15 )) \
        && grep -q '^run-all: slow-unit.sh timed out after 1 s$' <<<"$out" \
        && grep -q '^  TIMEOUT slow-unit.sh' <<<"$out" \
        && grep -q '^  PASS  ok-unit.sh' <<<"$out" \
        && ok "test_sleeping_suite_times_out_by_name" || bad "test_sleeping_suite_times_out_by_name (rc=$rc, $((SECONDS - t0))s): $out"
}
test_bad_timeout_value_is_refused() {
    local out rc
    out="$(TEST_DIR="$TMPD/two" TEST_SUITE_TIMEOUT=abc "$RUN" 2>&1)"; rc=$?
    [[ $rc -eq 2 ]] && grep -q "^run-all: TEST_SUITE_TIMEOUT must be a positive integer, got 'abc'$" <<<"$out" \
        && ok "test_bad_timeout_value_is_refused" || bad "test_bad_timeout_value_is_refused (rc=$rc): $out"
}
test_default_timeout_is_300() {
    local D="$TMPD/default" out rc
    mkdir "$D"
    fake "$D" sleep-unit.sh 0 2
    out="$(unset TEST_SUITE_TIMEOUT; TEST_DIR="$D" "$RUN" 2>&1)"; rc=$?
    [[ $rc -eq 0 ]] && grep -q '^  PASS  sleep-unit.sh' <<<"$out" \
        && grep -qF 'TIMEOUT="${TEST_SUITE_TIMEOUT:-300}"' "$RUN" \
        && ok "test_default_timeout_is_300" || bad "test_default_timeout_is_300 (rc=$rc): $out"
}
test_sleeping_suite_times_out_by_name
test_bad_timeout_value_is_refused
test_default_timeout_is_300

# --- the real tree --------------------------------------------------------------------------
noexec=""
for s in "$REPO_ROOT"/test/unit.sh "$REPO_ROOT"/test/*-unit.sh; do
    [[ -x "$s" ]] || noexec+=" $(basename "$s")"
done
[[ -z "$noexec" ]] && ok "every real suite is executable" || bad "not executable, run-all would fail them:$noexec"
grep -q '"test": "test/run-all.sh"' "$REPO_ROOT/package.json" && ok "npm test is test/run-all.sh" || bad "package.json test script"
CI="$REPO_ROOT/.github/workflows/ci.yml"
grep -Eq '^[[:space:]]*run: make gate-full[[:space:]]*$' "$CI" \
    && (cd "$REPO_ROOT" && make -n --no-print-directory gate-quick 2>/dev/null) | grep -qx 'test/run-all.sh' \
    && ! grep -Eq 'run: test/[a-z-]*unit\.sh' "$CI" \
    && ok "CI runs make gate-full, gate-quick runs test/run-all.sh, no per-suite list" || bad "ci.yml or the gate-quick target"

echo
echo "run-all-unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
