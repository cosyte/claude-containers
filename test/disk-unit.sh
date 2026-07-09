#!/usr/bin/env bash
# Unit tests for storage/disk safety (CC-5) — NO docker, NO sysbox, NO root.
#
# Covers three pieces, none of which touch a real Docker daemon:
#   1. disk_free_mib (bin/_common.sh)     — df parsing, fail-closed on garbage/missing path
#   2. broker_check_disk (bin/claude-worker-broker) — the per-launch refusal: below floor
#      refuses, above floor allows, unknown free space fails closed
#   3. disk_gc_plan / disk_gc_once (bin/claude-disk-gc) — the plan is exactly the two safe
#      prunes (never -a/--volumes), and disk_gc_once is fail-safe on a docker error
#
# The on-host proof (a real controller, N worker cycles + gc between them, a real floor
# refusal, image-reuse) is bin/claude-disk-verify (needs Sysbox); it is deliberately NOT
# run here.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source the broker ONCE (pulls in bin/_common.sh transitively, so disk_free_mib AND
# broker_check_disk are both defined here). Do NOT source _common.sh (or anything that
# sources it) a second time in THIS process — bash treats a repeated `readonly VAR=`
# (the SYSBOX_CVE_FLOOR guard in _common.sh) as a fatal error under `set -e` even inside
# the `if !` meant to catch it, and that fatal error survives even a `(...)` subshell or
# `$(...)` command substitution of this same process (bin/claude-disk-verify hit this
# exact hazard and works around it the same way: a genuinely fresh `bash -c` process for
# anything that needs claude-disk-gc's own source, below).
# shellcheck disable=SC1091
source "$REPO_ROOT/bin/claude-worker-broker"
# The broker (via _common.sh) sets -e; this harness counts failures instead of dying on
# the first one — undo it, keep -u/pipefail.
set +e

# Define AFTER the source: _common.sh ships its own ok() and would shadow the counters.
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

if disk_free_mib "/no/such/path/CC-5-disk-unit" >/dev/null 2>&1; then
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

# --- broker_check_disk: refuse below floor, allow above, fail closed on unknown ---------
echo
echo "== broker_check_disk: floor refusal, above-floor allow, fail-closed-on-unknown =="

# Run in a subshell (NOT a re-source — broker_check_disk is already defined in this
# process) so each case gets its own DISK_FLOOR_MIB/DISK_DATA_ROOT/override without
# leaking into the next.
sub_disk() {   # sub_disk <override|empty> <floor> -> the real exit code
    (
        DISK_FLOOR_MIB="$2"; DISK_DATA_ROOT="/does-not-matter"
        [[ -n "$1" ]] && export CLAUDE_DISK_FREE_MIB_OVERRIDE="$1"
        broker_check_disk
    ) >/dev/null 2>&1
}

if sub_disk 1000 500; then
    ok  "broker_check_disk ALLOWS when free (1000 MiB) >= floor (500 MiB)"
else
    bad "broker_check_disk must allow when free >= floor"
fi

if sub_disk 100 500; then
    bad "broker_check_disk must REFUSE when free (100 MiB) < floor (500 MiB)"
else
    ok  "broker_check_disk REFUSES when free (100 MiB) < floor (500 MiB)"
fi

if sub_disk 500 500; then
    ok  "broker_check_disk allows at the exact floor (500 MiB free == 500 MiB floor)"
else
    bad "broker_check_disk must allow when free == floor (>=, not >)"
fi

if sub_disk garbage 500; then
    bad "broker_check_disk must REFUSE (fail closed) when free space is unparseable"
else
    ok  "broker_check_disk fails closed when free space is unparseable (never reads as plenty)"
fi

# An impossible floor (non-integer) on the PER-REQUEST path must REFUSE (return 1),
# NOT die/exit — a `die` here would kill the whole serve loop (broker_process_request's
# `|| blog` wrapper cannot catch exit), turning one misconfig into a total outage.
# Assert both: the check refuses (nonzero) AND the shell SURVIVES the call.
survived="$(
    DISK_FLOOR_MIB="not-a-number"; DISK_DATA_ROOT="/tmp"; export CLAUDE_DISK_FREE_MIB_OVERRIDE=1000
    broker_check_disk && echo REFUSE-FAILED || true
    echo SURVIVED
)"
if [[ "$survived" == *SURVIVED* && "$survived" != *REFUSE-FAILED* ]]; then
    ok  "broker_check_disk REFUSES a non-integer floor via return 1 (never die) — the serve loop survives a misconfig"
else
    bad "broker_check_disk on a non-integer floor must return 1 AND not exit the shell (got: '$survived')"
fi

# The floor config is validated FAIL-FAST at STARTUP (broker_check_disk_config) — a
# misconfigured floor refuses to serve rather than dying on the first request.
if ( DISK_FLOOR_MIB="10gb"; DISK_DATA_ROOT="/tmp"; broker_check_disk_config ) >/dev/null 2>&1; then
    bad "broker_check_disk_config must DIE at startup on a non-integer floor (fail fast, before serving)"
else
    ok  "broker_check_disk_config dies at startup on a non-integer floor (fail fast — never a start-then-die daemon)"
fi
if ( DISK_FLOOR_MIB="10240"; DISK_DATA_ROOT="/tmp"; broker_check_disk_config ) >/dev/null 2>&1; then
    ok  "broker_check_disk_config accepts a valid integer floor at startup"
else
    bad "broker_check_disk_config must accept a valid integer floor"
fi

# --- broker_process_request: the disk-floor refusal leaves the item retry-able ---------
echo
echo "== broker_process_request: disk-pressure refusal responds + leaves the item retry-able =="

# broker_respond writes a root:group-owned file (chown to the client group) — outside a
# real controller (running as root) that chown fails and the write is dropped, same as
# every other broker-unit.sh test that exercises broker_process_request. Stub it here so
# this test isolates the disk-floor DECISION (was broker_respond called with the right
# message? was broker_docker/broker_launch never reached? is staging cleaned?) from the
# unrelated, environment-dependent chown mechanics.
PDIR="$(mktemp -d)"; mkdir -p "$PDIR/requests" "$PDIR/staging" "$PDIR/responses"
printf 'repo=hl7\nitem=CC-5-DISK\n' > "$PDIR/requests/req1"
RESPFILE="$TMPD/resp-captured"
(
    BROKER_DIR="$PDIR"
    DISK_FLOOR_MIB=99999999   # an impossible floor forces the disk check to refuse
    DISK_DATA_ROOT="/tmp"
    export CLAUDE_DISK_FREE_MIB_OVERRIDE=100
    broker_docker() { echo "SHOULD-NEVER-LAUNCH"; return 0; }   # must never be reached
    broker_respond() { shift; printf '%s\n' "$*" > "$RESPFILE"; }
    set -e
    broker_process_request "$PDIR/requests/req1"
) >/dev/null 2>&1
rc=$?
resp="$(cat "$RESPFILE" 2>/dev/null || echo MISSING)"
if (( rc == 0 )) && grep -q "disk pressure" <<<"$resp" && [[ ! -e "$PDIR/staging/req1" ]]; then
    ok  "a disk-pressure refusal responds with 'error disk pressure …', cleans staging, returns 0 (item stays retry-able)"
else
    bad "expected a disk-pressure error response + clean staging + rc 0 (rc=$rc, resp='$resp', staging-left=$([[ -e "$PDIR/staging/req1" ]] && echo yes || echo no))"
fi
if ! grep -q "SHOULD-NEVER-LAUNCH" <<<"$resp" && [[ ! -s "$PDIR/responses/req1" || ! -e "$PDIR/responses/req1" ]]; then
    ok  "broker_launch/broker_docker was never reached — the disk check runs BEFORE launch"
else
    bad "broker_docker must never be invoked when the disk-floor check refuses"
fi
rm -rf "$PDIR"

# --- claude-disk-gc: disk_gc_plan is exactly the two safe prunes -----------------------
echo
echo "== disk_gc_plan: exactly system+builder prune -f, never -a/--volumes =="

# A fresh `bash -c` process (NOT a subshell of THIS process, which already sourced
# claude-worker-broker → _common.sh once) — same readonly-re-source hazard as above.
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
    bad "the plan must NEVER include -a/--all/--volumes — that could reach live worker data (got: $plan)"
else
    ok  "the plan never includes -a/--all/--volumes"
fi
lines="$(grep -c . <<<"$plan")"
if [[ "$lines" == 2 ]]; then
    ok  "the plan is exactly two commands — nothing extra"
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

# --- claude-disk-gc: --loop rejects an unknown flag, one bad cycle keeps looping -------
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
