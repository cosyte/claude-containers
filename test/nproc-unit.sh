#!/usr/bin/env bash
# Unit tests for bin/nproc, the shim that prints the container's CPU quota: NO docker, NO root.
# A fake cpu.max and a fake /usr/bin/nproc (56 CPUs, honouring OMP_NUM_THREADS as GNU's does)
# stand in for the container.
#   - a quota: quota / period rounded up (2800000 100000 is 28), at most the affinity count
#   - "max" or no cpu.max: the affinity count, the same as --all here
#   - OMP_NUM_THREADS and OMP_THREAD_LIMIT are never read
#   - --all and --ignore=N go to the real nproc unchanged; --help says why the shim exists
#   - the image ships it ahead of /usr/bin, the facts section gets a CPUs line, and §12's
#     "NOT capped" line names the quota
# shellcheck source=test/lib/prelude.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/prelude.sh"
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIM="$REPO_ROOT/bin/nproc"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

REAL="$TMPD/real-nproc"
cat > "$REAL" <<'EOF'
#!/usr/bin/env bash
case "${1-}" in
    --all) echo 56 ;;
    --ignore=*) n=$(( ${OMP_NUM_THREADS:-${FAKE_AVAIL:-56}} - ${1#--ignore=} )); echo $(( n < 1 ? 1 : n )) ;;
    --help) echo "Usage: nproc [OPTION]..." ;;
    "") echo "${OMP_NUM_THREADS:-${FAKE_AVAIL:-56}}" ;;
    *) echo "nproc: bad option $1" >&2; exit 1 ;;
esac
EOF
chmod +x "$REAL"
shim() {  # shim <cpu.max contents|-> [args...]: run the shim against that cpu.max (- = none)
    local f="$TMPD/cpu.max"; rm -f "$f"
    [[ "$1" == - ]] || printf '%s\n' "$1" > "$f"
    shift
    CLAUDE_NPROC_CPU_MAX="$f" CLAUDE_NPROC_REAL="$REAL" "$SHIM" "$@"
}

echo "== bin/nproc =="
out="$(OMP_NUM_THREADS=4 shim "2800000 100000")"
[[ "$out" == 28 ]] && ok "2800000 100000 with OMP_NUM_THREADS=4: 28" || bad "28-CPU quota: '$out'"
out="$(OMP_THREAD_LIMIT=2 OMP_NUM_THREADS=4 shim "2850000 100000")"
[[ "$out" == 29 ]] && ok "a part CPU rounds up (28.5 is 29), OMP_THREAD_LIMIT ignored" || bad "28.5: '$out'"
out="$(OMP_NUM_THREADS=4 shim "max 100000")"; all="$(shim "max 100000" --all)"
[[ "$out" == 56 && "$out" == "$all" ]] && ok "max: --all's count (56)" || bad "max: '$out', --all '$all'"
out="$(OMP_NUM_THREADS=4 shim -)"
[[ "$out" == 56 ]] && ok "no cpu.max: the affinity count" || bad "no cpu.max: '$out'"
out="$(shim "garbage")"
[[ "$out" == 56 ]] && ok "an unreadable cpu.max: the affinity count" || bad "garbage: '$out'"
out="$(FAKE_AVAIL=8 shim "2800000 100000")"
[[ "$out" == 8 ]] && ok "a quota over the cpuset is capped by it" || bad "cpuset cap: '$out'"
out="$(OMP_NUM_THREADS=4 shim "2800000 100000" --all)"
[[ "$out" == 56 ]] && ok "--all: the real nproc's, unchanged" || bad "--all: '$out'"
out="$(OMP_NUM_THREADS=4 shim "2800000 100000" --ignore=1)"
[[ "$out" == 3 ]] && ok "--ignore=N: the real nproc's, unchanged" || bad "--ignore: '$out'"
out="$(shim - --help)"
[[ "$out" == *"OMP_NUM_THREADS"* && "$out" == *"cpu.max"* && "$out" == *"Usage: nproc"* ]] \
    && ok "--help says why it exists, then the real help" || bad "--help: $out"
shim - --bogus >/dev/null 2>&1; rc=$?
(( rc == 1 )) && ok "a bad option: the real nproc's error and exit" || bad "bad option rc=$rc"

echo "== the image, the facts, §12 =="
grep -q '^COPY --chmod=755 bin/nproc /usr/local/bin/nproc$' "$REPO_ROOT/Dockerfile" \
    && ok "the image ships it in /usr/local/bin, ahead of /usr/bin" || bad "no COPY of bin/nproc"
BASE="$TMPD/base"; mkdir -p "$BASE"
for t in bash env timeout head grep sed awk df stat date cat tr; do ln -s "$(command -v "$t")" "$BASE/$t"; done
printf '#!/bin/sh\necho 28\n' > "$TMPD/fake-nproc"; chmod +x "$TMPD/fake-nproc"
echo "2800000 100000" > "$TMPD/cpu.max"
facts() {
    env -u OMP_NUM_THREADS PATH="$BASE" CLAUDE_FACTS_NPROC="$TMPD/fake-nproc" CLAUDE_NPROC_CPU_MAX="$TMPD/cpu.max" \
        CLAUDE_FACTS_GPU_STATE="$TMPD/none" CLAUDE_FACTS_DIRS="$TMPD" CLAUDE_GPU=0 "$@" \
        "$BASE/bash" "$REPO_ROOT/bin/claude-container-facts" | grep '^- CPUs:'
}
out="$(facts)"
[[ "$out" == '- CPUs: 28 (cgroup cpu.max); thread pools capped at 4 per process (OMP_NUM_THREADS etc.; plain `/usr/bin/nproc` would show the cap)' ]] \
    && ok "facts: the quota and the default cap" || bad "facts: '$out'"
out="$(facts CLAUDE_THREADS_PER_PROCESS=0)"
[[ "$out" == *"28 (cgroup cpu.max); thread pools not capped"* ]] && ok "facts: CLAUDE_THREADS_PER_PROCESS=0 says not capped" || bad "facts off: '$out'"
echo "max 100000" > "$TMPD/cpu.max"
out="$(facts)"
[[ "$out" == *"(no cgroup quota)"* ]] && ok "facts: max says no quota" || bad "facts max: '$out'"
grep -q 'NOT capped.*not this container.s $(nproc) (its cgroup quota)' "$REPO_ROOT/entrypoint.d/12-session-env.sh" \
    && ok "§12's NOT capped line names the shim's count" || bad "§12 log line"

echo
echo "nproc-unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
