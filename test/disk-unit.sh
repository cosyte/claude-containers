#!/usr/bin/env bash
# Unit tests for disk-hygiene logic: NO docker, NO sysbox, NO root.
#
# The substrate strip removed the broker's per-launch disk-floor refusal (broker_check_disk /
# broker_check_disk_config, and the broker_process_request integration around it)
# along with the nested-Sysbox worker-broker substrate it gated: see
# docs/legacy-sysbox-broker.md. What survives, and what this covers:
#   1. disk_free_mib (bin/_common.sh): df parsing, fail-closed on garbage/missing path
#   2. disk_gc_plan / disk_gc_once (bin/claude-disk-gc): the plan is exactly the two safe
#      prunes (never -a/--volumes), and disk_gc_once is fail-safe on a docker error
#
# The one-command sanity re-run of this same logic is bin/claude-disk-verify.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$REPO_ROOT/bin/_common.sh"
# _common.sh sets -e; this harness counts failures instead of dying on the first one:
# undo it, keep -u/pipefail.
set +e

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# --- disk_free_mib: real df parsing ----------------------------------------------------
echo "== disk_free_mib: df parsing =="

got="$(disk_free_mib "$TMPD" 2>/dev/null)"; rc=$?
if (( rc == 0 )) && [[ "$got" =~ ^[0-9]+$ ]]; then
    ok  "disk_free_mib parses a real df on an existing path (got '$got' MiB)"
else
    bad "disk_free_mib must succeed with a numeric MiB value on a real path (rc=$rc, got='$got')"
fi

if disk_free_mib "/no/such/path/disk-unit" >/dev/null 2>&1; then
    bad "disk_free_mib must fail on a nonexistent path (fail closed, never read as free space)"
else
    ok  "disk_free_mib fails closed on a nonexistent path"
fi

if disk_free_mib "" >/dev/null 2>&1; then
    bad "disk_free_mib must fail on an empty path"
else
    ok  "disk_free_mib fails closed on an empty path"
fi

# --- disk_free_mib: the override seam --------------------------------------------------
echo
echo "== disk_free_mib: CLAUDE_DISK_FREE_MIB_OVERRIDE seam =="

out="$(CLAUDE_DISK_FREE_MIB_OVERRIDE=54321 disk_free_mib /anything 2>&1)"; rc=$?
if (( rc == 0 )) && grep -q '^54321$' <<<"$out"; then
    ok  "the override forces the returned value regardless of the real path"
else
    bad "the override must force '54321' (rc=$rc, out='$out')"
fi
if grep -q "TEST SEAM ACTIVE" <<<"$out"; then
    ok  "the override loudly warns TEST SEAM ACTIVE"
else
    bad "the override must warn loudly (got: $out)"
fi

if CLAUDE_DISK_FREE_MIB_OVERRIDE=not-a-number disk_free_mib /anything >/dev/null 2>&1; then
    bad "a non-numeric override must fail closed, never silently coerce to a number"
else
    ok  "a non-numeric override fails closed (never misread as 0 free = plenty)"
fi

# --- disk_free_mib: fails closed on garbage df output -----------------------------------
echo
echo "== disk_free_mib: fails closed on unparseable df output =="

# A stubbed `df` on PATH that emits garbage instead of the POSIX -P -B1M shape. Fails
# closed: an unparseable Available column must never be misread as "0 free" (which would
# itself wrongly refuse) or, worse, as some large accidental number (which would wrongly
# allow). It must simply refuse.
STUBDIR="$TMPD/stubbin"; mkdir -p "$STUBDIR"
cat > "$STUBDIR/df" <<'EOF'
#!/usr/bin/env bash
echo "garbage output, not a filesystem table"
EOF
chmod +x "$STUBDIR/df"
if ( PATH="$STUBDIR:$PATH"; disk_free_mib /tmp ) >/dev/null 2>&1; then
    bad "disk_free_mib must fail closed when df emits unparseable output"
else
    ok  "disk_free_mib fails closed when df emits unparseable output"
fi

cat > "$STUBDIR/df" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$STUBDIR/df"
if ( PATH="$STUBDIR:$PATH"; disk_free_mib /tmp ) >/dev/null 2>&1; then
    bad "disk_free_mib must fail closed when df itself errors"
else
    ok  "disk_free_mib fails closed when df exits nonzero"
fi

cat > "$STUBDIR/df" <<'EOF'
#!/usr/bin/env bash
printf 'Filesystem     1M-blocks      Used Available Capacity Mounted on\n'
printf '/dev/sda1          10240      2048      8192      21%% /\n'
EOF
chmod +x "$STUBDIR/df"
got="$( (PATH="$STUBDIR:$PATH"; disk_free_mib /tmp) 2>/dev/null)"; rc=$?
if (( rc == 0 )) && [[ "$got" == 8192 ]]; then
    ok  "disk_free_mib parses the Available column (4th field) of a well-formed df -P -B1M line (8192)"
else
    bad "disk_free_mib must parse Available=8192 from a well-formed stub (rc=$rc, got='$got')"
fi

# --- claude-disk-gc: disk_gc_plan is exactly the two safe prunes -----------------------
echo
echo "== disk_gc_plan: exactly system+builder prune -f, never -a/--volumes =="

plan="$(bash -c 'source "'"$REPO_ROOT"'/bin/claude-disk-gc" 2>/dev/null; disk_gc_plan')"
if grep -qx "docker system prune -f" <<<"$plan"; then
    ok  "the plan includes 'docker system prune -f'"
else
    bad "the plan must include 'docker system prune -f' (got: $plan)"
fi
if grep -qx "docker builder prune -f" <<<"$plan"; then
    ok  "the plan includes 'docker builder prune -f' (system prune alone never clears the build cache)"
else
    bad "the plan must include 'docker builder prune -f' (got: $plan)"
fi
if grep -qE -- ' -a\b| --all\b| --volumes\b' <<<"$plan"; then
    bad "the plan must NEVER include -a/--all/--volumes, that could reach live worker data (got: $plan)"
else
    ok  "the plan never includes -a/--all/--volumes"
fi
lines="$(grep -c . <<<"$plan")"
if [[ "$lines" == 2 ]]; then
    ok  "the plan is exactly two commands: nothing extra"
else
    bad "expected exactly 2 plan lines, got $lines: $plan"
fi

# --- claude-disk-gc: disk_gc_once is fail-safe on a docker error ------------------------
echo
echo "== disk_gc_once: fail-safe on docker error (warns, never dies) =="

out="$(bash -c '
    source "'"$REPO_ROOT"'/bin/claude-disk-gc" 2>/dev/null
    gc_docker() { return 1; }
    disk_gc_once
    echo "SURVIVED rc=$?"
' 2>&1)"
if grep -q "SURVIVED rc=0" <<<"$out"; then
    ok  "disk_gc_once completes (exit 0) even when every gc_docker call fails"
else
    bad "disk_gc_once must survive a totally-failing gc_docker and exit 0 (got: $out)"
fi
if grep -qi "warning" <<<"$out"; then
    ok  "a failing prune produces a visible warn line (not silently swallowed)"
else
    bad "expected a warn line when gc_docker fails (got: $out)"
fi

# --- claude-disk-gc: CLAUDE_DISK_GC_DRYRUN reports without running anything -------------
echo
echo "== CLAUDE_DISK_GC_DRYRUN: reports, runs nothing =="

out="$(bash -c '
    source "'"$REPO_ROOT"'/bin/claude-disk-gc" 2>/dev/null
    gc_docker() { echo "SHOULD-NEVER-RUN $*"; return 0; }
    CLAUDE_DISK_GC_DRYRUN=1 disk_gc_once
' 2>&1)"
if grep -q "TEST SEAM ACTIVE" <<<"$out" && grep -q "would run" <<<"$out"; then
    ok  "DRYRUN loudly warns and reports what it WOULD run"
else
    bad "DRYRUN must warn + report the intended commands (got: $out)"
fi
if grep -q "SHOULD-NEVER-RUN" <<<"$out"; then
    bad "DRYRUN must never actually invoke gc_docker"
else
    ok  "DRYRUN never invokes gc_docker"
fi

# --- claude-disk-gc: --loop rejects an unknown flag, one-shot vs --loop dispatch -------
echo
echo "== claude-disk-gc: unknown flag refused, one-shot vs --loop dispatch =="

if bash -c 'source "'"$REPO_ROOT"'/bin/claude-disk-gc" 2>/dev/null; gc_main --bogus' >/dev/null 2>&1; then
    bad "gc_main must reject an unknown flag"
else
    ok  "gc_main rejects an unknown flag"
fi

echo
echo "== $PASS passed, $FAIL failed =="
exit $(( FAIL > 0 ? 1 : 0 ))
