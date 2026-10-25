#!/usr/bin/env bash
# Run every unit suite at once: `npm test`, locally and in CI.
#
# The suites are test/unit.sh and every test/*-unit.sh: a glob, so a new suite runs with no list
# to edit. They run concurrently, at most TEST_JOBS at a time (default: nproc), each writing to
# its own log. Each log is printed whole, in the fixed order above, as soon as it and every
# suite before it have finished, so output never interleaves. Then one summary line per suite
# (PASS, FAIL or TIMEOUT, seconds) and the elapsed total. Exits nonzero if any suite failed or
# timed out; every suite still runs.
#
# TEST_SUITE_TIMEOUT (seconds, default 300) caps each suite: past it the suite gets TERM, then
# KILL 10 s later, its log ends with "run-all: <suite> timed out after <N> s", and its summary
# line reads TIMEOUT, so a hung suite fails fast and names itself.
#
# TEST_DIR points it at another directory of suites (test/run-all-unit.sh uses fakes).
set -uo pipefail

DIR="${TEST_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
JOBS="${TEST_JOBS:-$(nproc 2>/dev/null || echo 2)}"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "run-all: TEST_JOBS must be a positive integer, got '$JOBS'" >&2; exit 2; }
TIMEOUT="${TEST_SUITE_TIMEOUT:-300}"
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || { echo "run-all: TEST_SUITE_TIMEOUT must be a positive integer, got '$TIMEOUT'" >&2; exit 2; }

suites=()
[[ -f "$DIR/unit.sh" ]] && suites+=("$DIR/unit.sh")
for f in "$DIR"/*-unit.sh; do
    [[ -f "$f" ]] && suites+=("$f")
done
(( ${#suites[@]} )) || { echo "run-all: no suites in $DIR" >&2; exit 2; }

LOGS="$(mktemp -d)"
trap 'rm -rf "$LOGS"' EXIT
trap 'kill $(jobs -p) 2>/dev/null; exit 130' INT TERM

# Each suite's result lands in $LOGS/<i>.rc as "<exit status> <seconds>" once it ends.
start=$SECONDS
printed=0
flush() {   # print, in order, every finished suite's log not yet printed; "all": every one left
    while (( printed < ${#suites[@]} )) && [[ -f "$LOGS/$printed.rc" || "${1:-}" == all ]]; do
        echo "=== $(basename "${suites[$printed]}")"
        cat "$LOGS/$printed.log" 2>/dev/null
        printed=$((printed + 1))
    done
}

echo "run-all: ${#suites[@]} suites, $JOBS at a time"
for i in "${!suites[@]}"; do
    while (( $(jobs -rp | wc -l) >= JOBS )); do
        wait -n
        flush
    done
    (
        s=$SECONDS
        # timeout runs the suite in its own process group, out of reach of a Ctrl-C: pass a TERM on
        timeout --kill-after=10 "$TIMEOUT" "${suites[$i]}" </dev/null >"$LOGS/$i.log" 2>&1 &
        tpid=$!
        trap 'kill -TERM "$tpid" 2>/dev/null; exit 143' TERM
        wait "$tpid"
        rc=$?
        (( rc == 124 || rc == 137 )) \
            && echo "run-all: $(basename "${suites[$i]}") timed out after $TIMEOUT s" >>"$LOGS/$i.log"
        echo "$rc $((SECONDS - s))" >"$LOGS/$i.rc.tmp" && mv "$LOGS/$i.rc.tmp" "$LOGS/$i.rc"
    ) &
done
while (( $(jobs -rp | wc -l) > 0 )); do
    wait -n
    flush
done
wait
flush all   # a suite whose wrapper died wrote no .rc: print its log anyway

echo
echo "=== summary"
failed=0
for i in "${!suites[@]}"; do
    rc="" secs="?"
    read -r rc secs <"$LOGS/$i.rc" 2>/dev/null
    if [[ -z "$rc" ]]; then
        printf '  FAIL  %-28s %4ss  (no result: its runner died)\n' "$(basename "${suites[$i]}")" "$secs"
        failed=$((failed + 1))
    elif (( rc == 0 )); then
        printf '  PASS  %-28s %4ss\n' "$(basename "${suites[$i]}")" "$secs"
    elif (( rc == 124 || rc == 137 )); then
        printf '  TIMEOUT %-26s %4ss  (over %s s)\n' "$(basename "${suites[$i]}")" "$secs" "$TIMEOUT"
        failed=$((failed + 1))
    else
        printf '  FAIL  %-28s %4ss  (exit %s)\n' "$(basename "${suites[$i]}")" "$secs" "$rc"
        failed=$((failed + 1))
    fi
done
echo "run-all: ${#suites[@]} suites, $failed failed, ${JOBS} jobs, elapsed $((SECONDS - start))s"
(( failed == 0 ))
