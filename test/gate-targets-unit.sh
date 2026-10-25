#!/usr/bin/env bash
# Unit tests for the standard gate targets (make gate-quick, make gate-full): NO docker, NO root.
#   - gate-quick runs lint, then the em-dash scan, then test/run-all.sh, each once, in that order
#   - gate-full runs exactly what gate-quick runs
#   - a failing lint stops gate-quick before the tests start
#   - make help lists both; CI's ci job calls make gate-full; the docs name the targets
# Never runs gate-quick or gate-full for real past lint: test/run-all.sh runs this suite, so a
# real gate here would recurse. Only `make -n` and the lint-fails case are safe.
# shellcheck source=test/lib/prelude.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/prelude.sh"
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

# dry <target>: what make would run for it, from the repo root, in a clean environment
dry() { (cd "$REPO_ROOT" && env -i PATH="$PATH" make -n --no-print-directory "$1" 2>&1); }

test_gate_quick_runs_lint_then_emdash_then_tests() {
    local out want=(shellcheck hadolint emdash tests) got=() line
    out="$(dry gate-quick)"
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
        case "$line" in
            "shellcheck -S warning"*)          got+=(shellcheck) ;;
            "hadolint Dockerfile")             got+=(hadolint) ;;
            "bash scripts/check-no-emdash.sh") got+=(emdash) ;;
            "test/run-all.sh")                 got+=(tests) ;;
        esac
    done <<<"$out"
    [[ "${got[*]}" == "${want[*]}" ]] \
        && ok "gate-quick runs shellcheck, hadolint, the em-dash scan, then test/run-all.sh, once each" \
        || bad "gate-quick order: got '${got[*]}', want '${want[*]}': $out"
}

test_gate_full_runs_the_same_as_gate_quick() {
    local q f
    q="$(dry gate-quick)"; f="$(dry gate-full)"
    [[ -n "$q" && "$q" == "$f" ]] && ok "gate-full runs the same as gate-quick" \
        || bad "gate-full differs from gate-quick: $(diff <(echo "$q") <(echo "$f"))"
}

test_gate_quick_stops_when_lint_fails() {
    local fake="$TMPD/fake" out rc t
    mkdir -p "$fake"
    for t in shellcheck hadolint; do
        printf '#!/usr/bin/env bash\nexit 1\n' >"$fake/$t"; chmod +x "$fake/$t"
    done
    out="$(cd "$REPO_ROOT" && env -i PATH="$fake:$PATH" make --no-print-directory gate-quick 2>&1)"; rc=$?
    [[ $rc -ne 0 ]] && grep -q 'is missing' <<<"$out" && ! grep -q '^run-all:' <<<"$out" \
        && ok "a failing lint stops gate-quick before the tests" \
        || bad "lint-fails gate-quick (rc=$rc): $out"
}

test_help_lists_gate_targets() {
    local out
    out="$(cd "$REPO_ROOT" && make --no-print-directory help 2>&1)"
    grep -Eq 'gate-quick[^a-z-]' <<<"$out" && grep -Eq 'gate-full[^a-z-]' <<<"$out" \
        && ok "make help lists gate-quick and gate-full" || bad "make help: $out"
}

test_ci_job_calls_gate_full() {
    local job line mise=0 gate=0 stray=0
    job="$(awk '/^  ci:/{f=1; next} f && /^  [A-Za-z_-]+:/{exit} f' "$REPO_ROOT/.github/workflows/ci.yml")"
    while IFS= read -r line; do
        [[ "$line" == *"uses: jdx/mise-action@"* ]] && mise=1
        [[ "$line" =~ ^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*make\ gate-full[[:space:]]*$ ]] && (( mise )) && gate=1
        [[ "$line" =~ ^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*(make\ lint|npm\ test)[[:space:]]*$ ]] && stray=1
    done <<<"$job"
    (( mise && gate && !stray )) && ok "the ci job runs mise-action, then make gate-full, and no make lint or npm test" \
        || bad "ci job (mise=$mise gate=$gate stray=$stray): $job"
}

test_run_all_unit_accepts_gate_full_ci() {
    local out rc
    out="$("$REPO_ROOT/test/run-all-unit.sh" 2>&1)"; rc=$?
    [[ $rc -eq 0 ]] \
        && grep -q 'PASS  CI runs make gate-full, gate-quick runs test/run-all.sh, no per-suite list' <<<"$out" \
        && grep -q 'PASS  npm test is test/run-all.sh' <<<"$out" \
        && ok "run-all-unit.sh accepts the gate-full CI" || bad "run-all-unit.sh (rc=$rc): $out"
}

test_docs_name_gate_targets() {
    local f miss=""
    for f in CLAUDE.md CARD.md README.md; do
        grep -q 'make gate-quick' "$REPO_ROOT/$f" || miss+=" $f"
    done
    grep -q 'make gate-full' "$REPO_ROOT/CLAUDE.md" || miss+=" CLAUDE.md(gate-full)"
    [[ -z "$miss" ]] && ok "CLAUDE.md, CARD.md and README.md name the gate targets" || bad "docs miss:$miss"
}

test_gate_quick_runs_lint_then_emdash_then_tests
test_gate_full_runs_the_same_as_gate_quick
test_gate_quick_stops_when_lint_fails
test_help_lists_gate_targets
test_ci_job_calls_gate_full
test_run_all_unit_accepts_gate_full_ci
test_docs_name_gate_targets

echo
echo "gate-targets-unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
