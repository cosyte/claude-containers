#!/usr/bin/env bash
# Run every unit suite at once: `npm test`, locally and in CI.
#
# The suites are test/unit.sh and every test/*-unit.sh: a glob, so a new suite runs with no list
# to edit. They run concurrently, at most TEST_JOBS at a time (default: nproc), each writing to
# its own log. Each log is printed whole, in the fixed order above, as soon as it and every
# suite before it have finished, so output never interleaves. Then one summary line per suite
# (PASS or FAIL, seconds) and the elapsed total. Exits nonzero if any suite failed; every suite
# still runs.
#
# TEST_DIR points it at another directory of suites (test/run-all-unit.sh uses fakes).
set -uo pipefail

DIR="${TEST_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
JOBS="${TEST_JOBS:-$(nproc 2>/dev/null || echo 2)}"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "run-all: TEST_JOBS must be a positive integer, got '$JOBS'" >&2; exit 2; }

suites=()
[[ -f "$DIR/unit.sh" ]] && suites+=("$DIR/unit.sh")
for f in "$DIR"/*-unit.sh; do
    [[ -f "$f" ]] && suites+=("$f")
done
(( ${#suites[@]} )) || { echo "run-all: no suites in $DIR" >&2; exit 2; }

LOGS="$(mktemp -d)"
trap 'rm -rf "$LOGS"' EXIT

# Each suite's result lands in $LOGS/<i>.rc as "<exit status> <seconds>" once it ends.
start=$SECONDS
printed=0
flush() {   # print, in order, every finished suite's log not yet printed
    while (( printed < ${#suites[@]} )) && [[ -f "$LOGS/$printed.rc" ]]; do
        echo "=== $(basename "${suites[$printed]}")"
        cat "$LOGS/$printed.log"
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
        "${suites[$i]}" </dev/null >"$LOGS/$i.log" 2>&1
        rc=$?
        echo "$rc $((SECONDS - s))" >"$LOGS/$i.rc.tmp" && mv "$LOGS/$i.rc.tmp" "$LOGS/$i.rc"
    ) &
done
while (( $(jobs -rp | wc -l) > 0 )); do
    wait -n
    flush
done
wait
flush

echo
echo "=== summary"
failed=0
for i in "${!suites[@]}"; do
    read -r rc secs <"$LOGS/$i.rc"
    if (( rc == 0 )); then
        printf '  PASS  %-28s %4ss\n' "$(basename "${suites[$i]}")" "$secs"
    else
        printf '  FAIL  %-28s %4ss  (exit %s)\n' "$(basename "${suites[$i]}")" "$secs" "$rc"
        failed=$((failed + 1))
    fi
done
echo "run-all: ${#suites[@]} suites, $failed failed, ${JOBS} jobs, elapsed $((SECONDS - start))s"
(( failed == 0 ))
