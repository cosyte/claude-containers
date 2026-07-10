#!/usr/bin/env bash
# Unit tests for bin/claude-worker-run (CC-4) — NO docker, NO sysbox, NO claude, NO network.
#
# Covers argv validation (the same charset the broker enforces), umbrella-location
# detection (fail-closed when absent), the non-submodule refusal, and the DRYRUN seam's
# run-exactly-once contract — the property a refuter should scrutinize hardest, since a
# worker that ran /work-on more than once per container would double-bill or double-act.
#
# The full on-host proof (a real isolate + claude -p run, a real umbrella) is
# bin/claude-worker-lifecycle-verify; it is deliberately NOT exercised here.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# shellcheck disable=SC1091
source "$REPO_ROOT/bin/claude-worker-run"   # sourcing defines functions and returns
set +e

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

# --- fake umbrella fixture ---------------------------------------------------------------
# A minimal tree that "looks like the umbrella" per worker_run_looks_like_umbrella:
# .gitmodules (with a `path = hl7` entry) + scripts/isolate.sh.
UMBRELLA="$TMPD/umbrella"
mkdir -p "$UMBRELLA/scripts"
cat > "$UMBRELLA/.gitmodules" <<'EOF'
[submodule "hl7"]
	path = hl7
	url = git@github.com:cosyte/hl7.git
[submodule "mllp"]
	path = mllp
	url = git@github.com:cosyte/mllp.git
EOF
cat > "$UMBRELLA/scripts/isolate.sh" <<'EOF'
#!/usr/bin/env bash
# stub: echoes a fake worktree path, never touches real git
echo "/tmp/fake-worktree-$1-$2"
EOF
chmod +x "$UMBRELLA/scripts/isolate.sh"

# --- worker_run_validate_args -------------------------------------------------------------
echo "== worker_run_validate_args: exactly 2 args, charset enforced =="

t_args() {  # t_args <label> <want ok|FAIL> <args...>
    # worker_run_validate_args calls _common.sh's die() on failure, which does a hard
    # `exit 1` (not `return`) — run it in a SUBSHELL so a refusal only ends that
    # subshell, never this test script.
    local label="$1" want="$2"; shift 2
    if ( worker_run_validate_args "$@" ) >/dev/null 2>&1; then
        [[ "$want" == ok ]] && ok "$label" || bad "$label (must be refused, was accepted)"
    else
        [[ "$want" == FAIL ]] && ok "$label" || bad "$label (must be accepted, was refused)"
    fi
}
t_args "well-formed repo + item accepted" ok hl7 CC-4
t_args "dotted/hyphenated item accepted" ok mllp CC-4.1_x
t_args "zero args refused (needs exactly 2)" FAIL
t_args "one arg refused (needs exactly 2)" FAIL hl7
t_args "three args refused (needs exactly 2)" FAIL hl7 CC-4 extra
t_args "repo starting with '-' (flag injection) refused" FAIL -e CC-4
t_args "item with a space (argv smuggling) refused" FAIL hl7 "CC-4 --privileged"
t_args "path-traversal repo refused" FAIL ../../etc CC-4
t_args "repo starting with '.' refused (charset requires alnum first)" FAIL .hl7 CC-4
long_item="$(printf 'a%.0s' $(seq 1 80))"
t_args "over-length (80-char) item refused (64 cap)" FAIL hl7 "$long_item"
t_args "empty item refused" FAIL hl7 ""

if worker_run_validate_args hl7 CC-4 && [[ "$WR_REPO" == hl7 && "$WR_ITEM" == CC-4 ]]; then
    ok "validate_args sets WR_REPO/WR_ITEM on success"
else
    bad "validate_args must set WR_REPO/WR_ITEM (got repo='${WR_REPO:-}' item='${WR_ITEM:-}')"
fi

# --- worker_run_looks_like_umbrella --------------------------------------------------------
echo
echo "== worker_run_looks_like_umbrella: true/false =="

if worker_run_looks_like_umbrella "$UMBRELLA"; then
    ok "the fake umbrella (.gitmodules + scripts/isolate.sh) reads as an umbrella"
else
    bad "the fake umbrella must read as an umbrella"
fi

NOGIT="$TMPD/no-gitmodules"; mkdir -p "$NOGIT/scripts"; touch "$NOGIT/scripts/isolate.sh"
if worker_run_looks_like_umbrella "$NOGIT"; then
    bad "a dir missing .gitmodules must NOT read as an umbrella"
else
    ok "a dir missing .gitmodules is rejected"
fi

NOISOLATE="$TMPD/no-isolate"; mkdir -p "$NOISOLATE"; touch "$NOISOLATE/.gitmodules"
if worker_run_looks_like_umbrella "$NOISOLATE"; then
    bad "a dir missing scripts/isolate.sh must NOT read as an umbrella"
else
    ok "a dir missing scripts/isolate.sh is rejected"
fi

if worker_run_looks_like_umbrella "$TMPD/does-not-exist"; then
    bad "a nonexistent dir must NOT read as an umbrella"
else
    ok "a nonexistent dir is rejected"
fi

# --- worker_run_locate_umbrella: fail-closed when absent -----------------------------------
echo
echo "== worker_run_locate_umbrella: fail-closed =="

if ( CLAUDE_WORKER_UMBRELLA="$UMBRELLA" worker_run_locate_umbrella ) >/dev/null 2>&1; then
    ok "an explicit CLAUDE_WORKER_UMBRELLA pointing at a real umbrella is accepted"
else
    bad "a valid CLAUDE_WORKER_UMBRELLA must be accepted"
fi

if ( CLAUDE_WORKER_UMBRELLA="$TMPD/nope" worker_run_locate_umbrella ) >/dev/null 2>&1; then
    bad "an explicit CLAUDE_WORKER_UMBRELLA that doesn't look like the umbrella must be REFUSED"
else
    ok "an explicit CLAUDE_WORKER_UMBRELLA that doesn't look right refuses (fail closed, never falls back)"
fi

# No CLAUDE_WORKER_UMBRELLA and /workspace doesn't look like the umbrella in THIS test
# environment (or does — skip gracefully if it happens to be a real umbrella checkout).
if worker_run_looks_like_umbrella /workspace; then
    ok "SKIP: /workspace looks like a real umbrella here — absent-umbrella path not testable"
else
    if ( unset CLAUDE_WORKER_UMBRELLA; worker_run_locate_umbrella ) >/dev/null 2>&1; then
        bad "no umbrella found anywhere must be REFUSED (fail closed), not silently accepted"
    else
        ok "no umbrella found anywhere refuses (fail closed)"
    fi
fi

# --- worker_run_check_submodule: non-submodule repo rejected --------------------------------
echo
echo "== worker_run_check_submodule: only real submodules run =="

# worker_run_check_submodule calls die() on rejection (a hard `exit 1`) — subshell
# every call so a refusal ends only that subshell.
if ( worker_run_check_submodule "$UMBRELLA" hl7 ) >/dev/null 2>&1; then
    ok "a repo listed in .gitmodules ('hl7') is accepted"
else
    bad "'hl7' is a real submodule and must be accepted"
fi
if ( worker_run_check_submodule "$UMBRELLA" mllp ) >/dev/null 2>&1; then
    ok "a second listed repo ('mllp') is accepted"
else
    bad "'mllp' is a real submodule and must be accepted"
fi
if ( worker_run_check_submodule "$UMBRELLA" not-a-real-repo ) >/dev/null 2>&1; then
    bad "a repo NOT in .gitmodules must be REJECTED"
else
    ok "a repo not listed in .gitmodules is rejected"
fi
if ( worker_run_check_submodule "$UMBRELLA" hl ) >/dev/null 2>&1; then
    bad "a prefix of a real submodule name ('hl' vs 'hl7') must NOT match"
else
    ok "a bare prefix of a real submodule name does not false-match"
fi

# --- CLAUDE_WORKER_RUN_DRYRUN: prints the plan EXACTLY ONCE, no docker/claude/lease ---------
echo
echo "== CLAUDE_WORKER_RUN_DRYRUN: run-exactly-once, no real isolate/claude =="

dry="$(CLAUDE_WORKER_UMBRELLA="$UMBRELLA" CLAUDE_WORKER_RUN_DRYRUN=1 \
    bash "$REPO_ROOT/bin/claude-worker-run" hl7 CC-4-DRY 2>/dev/null)"
if [[ "$(grep -c '/work-on hl7 CC-4-DRY' <<<"$dry")" == 1 ]]; then
    ok "the DRYRUN plan names '/work-on hl7 CC-4-DRY' EXACTLY ONCE (no loop)"
else
    bad "expected exactly one '/work-on hl7 CC-4-DRY' line, got: $dry"
fi
if grep -q "TEST SEAM ACTIVE" <<<"$(CLAUDE_WORKER_UMBRELLA="$UMBRELLA" CLAUDE_WORKER_RUN_DRYRUN=1 \
    bash "$REPO_ROOT/bin/claude-worker-run" hl7 CC-4-DRY 2>&1 >/dev/null)"; then
    ok "DRYRUN warns loudly that the test seam is active"
else
    bad "DRYRUN must loudly warn TEST SEAM ACTIVE"
fi
if grep -q "isolate: scripts/isolate.sh hl7 CC-4-DRY" <<<"$dry" \
   && grep -q "run-count: 1 (exactly once, never a loop)" <<<"$dry"; then
    ok "DRYRUN plan names the isolate step and states run-count: 1"
else
    bad "DRYRUN plan must show the isolate step and 'run-count: 1' (got: $dry)"
fi
# Exit 0, no real docker/claude/network touched (this whole test file runs with none available).
rc=$( { CLAUDE_WORKER_UMBRELLA="$UMBRELLA" CLAUDE_WORKER_RUN_DRYRUN=1 \
    bash "$REPO_ROOT/bin/claude-worker-run" hl7 CC-4-DRY >/dev/null 2>&1; echo $?; } )
[[ "$rc" == 0 ]] && ok "DRYRUN exits 0" || bad "DRYRUN must exit 0 (got $rc)"

# DRYRUN must short-circuit BEFORE any umbrella/submodule validation — even with no
# umbrella at all, DRYRUN still only prints the plan (using the CLAUDE_WORKER_UMBRELLA
# env value or its /workspace default verbatim in the printout), never touching disk.
rc2=$( { unset CLAUDE_WORKER_UMBRELLA; CLAUDE_WORKER_RUN_DRYRUN=1 \
    bash "$REPO_ROOT/bin/claude-worker-run" totally-fake-repo CC-4-DRY2 >/dev/null 2>&1; echo $?; } )
[[ "$rc2" == 0 ]] && ok "DRYRUN short-circuits before umbrella/submodule checks (exits 0 even with no real umbrella)" \
    || bad "DRYRUN must short-circuit before real checks (got rc=$rc2)"

# --- CC-7: DRYRUN shows the resolved per-item OTEL resource-attribute tag -------------------
echo
echo "== CLAUDE_WORKER_RUN_DRYRUN: OTEL item/repo tag is visible without running claude =="

if grep -q "otel: OTEL_RESOURCE_ATTRIBUTES=claude.item=CC-4-DRY,claude.repo=hl7" <<<"$dry"; then
    ok "DRYRUN plan names the resolved claude.item=<item>,claude.repo=<repo> OTEL tag"
else
    bad "DRYRUN plan must show 'otel: OTEL_RESOURCE_ATTRIBUTES=claude.item=CC-4-DRY,claude.repo=hl7' (got: $dry)"
fi

# An operator-supplied OTEL_RESOURCE_ATTRIBUTES must be preserved (appended), never clobbered.
dry_with_existing="$(CLAUDE_WORKER_UMBRELLA="$UMBRELLA" CLAUDE_WORKER_RUN_DRYRUN=1 \
    OTEL_RESOURCE_ATTRIBUTES="service.name=cosyte-worker" \
    bash "$REPO_ROOT/bin/claude-worker-run" mllp CC-9-DRY 2>/dev/null)"
if grep -q "otel: OTEL_RESOURCE_ATTRIBUTES=claude.item=CC-9-DRY,claude.repo=mllp,service.name=cosyte-worker" <<<"$dry_with_existing"; then
    ok "DRYRUN preserves a pre-existing OTEL_RESOURCE_ATTRIBUTES, prepending the item/repo tag"
else
    bad "DRYRUN must preserve an existing OTEL_RESOURCE_ATTRIBUTES (got: $dry_with_existing)"
fi

echo
echo "== $PASS passed, $FAIL failed =="
exit $(( FAIL > 0 ? 1 : 0 ))
