#!/usr/bin/env bash
# Unit tests for test/run-all.sh (the `npm test` runner), against fake suites: NO docker, NO root.
#   - every suite runs, picked up by the glob (unit.sh and *-unit.sh, nothing else)
#   - one failing suite makes the run exit nonzero, and the others still run and pass
#   - logs print whole and in the fixed order, whatever order the suites finish in
#   - the summary names every suite with PASS/FAIL and seconds, and the elapsed total
#   - TEST_JOBS caps how many run at once; a bad TEST_JOBS refuses
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
printf '#!/usr/bin/env bash\necho "out of b-unit.sh"\nkill -9 $PPID\n' >"$D/b-unit.sh"; chmod +x "$D/b-unit.sh"
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

# --- the real tree --------------------------------------------------------------------------
noexec=""
for s in "$REPO_ROOT"/test/unit.sh "$REPO_ROOT"/test/*-unit.sh; do
    [[ -x "$s" ]] || noexec+=" $(basename "$s")"
done
[[ -z "$noexec" ]] && ok "every real suite is executable" || bad "not executable, run-all would fail them:$noexec"
grep -q '"test": "test/run-all.sh"' "$REPO_ROOT/package.json" && ok "npm test is test/run-all.sh" || bad "package.json test script"
grep -q 'run: npm test' "$REPO_ROOT/.github/workflows/ci.yml" && ! grep -Eq 'run: test/[a-z-]*unit\.sh' "$REPO_ROOT/.github/workflows/ci.yml" \
    && ok "CI runs npm test, no per-suite list" || bad "ci.yml still lists suites"

echo
echo "run-all-unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
