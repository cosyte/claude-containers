#!/usr/bin/env bash
# Unit tests for bin/claude-reaper (CC-4) — NO docker, NO sysbox, NO root.
#
# Covers the two pure-selection functions (reaper_exited_workers, reaper_stale_spool_files)
# against a stubbed docker + a real (tmp) spool with touch -d'd mtimes, the never-touch-.lock
# guarantee, idempotency, and the fail-safe posture (a docker error warns and continues —
# reaper_once must never die mid-reap). The on-host proof (a real broker-launched worker
# vanishing, a real kill -9'd worker actually being reaped) is
# bin/claude-worker-lifecycle-verify; it is deliberately NOT exercised here.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# shellcheck disable=SC1091
source "$REPO_ROOT/bin/claude-reaper"   # sourcing defines functions and returns
set +e

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

# --- reaper_exited_workers: exited selected, running NOT selected ---------------------------
echo "== reaper_exited_workers: exited/dead/created selected, running never is =="

reaper_docker() {
    case "$*" in
        *"status=exited"*)  echo "exited-1"$'\n'"exited-2" ;;
        *"status=dead"*)    echo "dead-1" ;;
        *"status=created"*) echo "" ;;
        *"status=running"*) echo "SHOULD-NEVER-BE-SELECTED" ;;
        *) return 1 ;;
    esac
}
got="$(reaper_exited_workers)"
if grep -qx "exited-1" <<<"$got" && grep -qx "exited-2" <<<"$got" && grep -qx "dead-1" <<<"$got"; then
    ok "exited + dead container ids are selected"
else
    bad "expected exited-1, exited-2, dead-1 selected (got: $got)"
fi
if ! grep -q "SHOULD-NEVER-BE-SELECTED" <<<"$got"; then
    ok "running containers are never selected (the filter never queries status=running for removal)"
else
    bad "a running container id leaked into the selection"
fi
if [[ -z "$(reaper_docker ps -a --filter label=claude.worker=1 --filter status=created -q)" ]] \
   && grep -qx "exited-1" <<<"$got"; then
    ok "an empty status (created, here) contributes nothing but doesn't break other statuses"
else
    bad "an empty-result status must not suppress the other statuses' ids"
fi

echo
echo "== reaper_exited_workers: fail-safe (docker error warns, does not die) =="

reaper_docker() { return 1; }
out="$(reaper_exited_workers 2>&1)"; rc=$?
if (( rc == 0 )) && [[ -z "$(tr -d '[:space:]' <<<"$(grep -v 'warning' <<<"$out")")" ]]; then
    ok "a docker error on every status warns (not dies) and returns 0 with no ids"
else
    bad "reaper_exited_workers must warn+continue on docker error, return 0, no ids (rc=$rc, out=$out)"
fi
if grep -q "warning" <<<"$out"; then
    ok "the docker error produces a warn line (visible, not swallowed)"
else
    bad "expected a warn line on docker error"
fi

# A partial failure (one status errors, another succeeds) must still surface the
# succeeding status's ids — one bad status degrades itself, not the whole call.
reaper_docker() {
    case "$*" in
        *"status=exited"*) return 1 ;;
        *"status=dead"*)   echo "dead-only" ;;
        *"status=created"*) echo "" ;;
        *) return 1 ;;
    esac
}
got2="$(reaper_exited_workers 2>/dev/null)"
if [[ "$got2" == "dead-only" ]]; then
    ok "a docker error on ONE status still surfaces ids from the other statuses"
else
    bad "expected 'dead-only' to survive a sibling status's docker error (got: $got2)"
fi

# --- reaper_stale_spool_files: stale selected, fresh + .lock kept ---------------------------
echo
echo "== reaper_stale_spool_files: stale selected, fresh + .lock always kept =="

SPOOL="$TMPD/spool"
mkdir -p "$SPOOL/responses" "$SPOOL/requests" "$SPOOL/staging"
: > "$SPOOL/responses/old-response";  touch -d '2 hours ago' "$SPOOL/responses/old-response"
: > "$SPOOL/responses/new-response"
: > "$SPOOL/requests/old-request";    touch -d '2 hours ago' "$SPOOL/requests/old-request"
: > "$SPOOL/requests/new-request"
: > "$SPOOL/staging/old-staged";      touch -d '2 hours ago' "$SPOOL/staging/old-staged"
: > "$SPOOL/staging/new-staged"
: > "$SPOOL/.lock";                   touch -d '2 hours ago' "$SPOOL/.lock"

stale="$(reaper_stale_spool_files "$SPOOL" 3600)"
want_present=(old-response old-request old-staged)
want_absent=(new-response new-request new-staged .lock)
all_ok=1
for f in "${want_present[@]}"; do grep -q "/$f\$" <<<"$stale" || all_ok=0; done
for f in "${want_absent[@]}"; do grep -q "/$f\$" <<<"$stale" && all_ok=0; done
if (( all_ok )); then
    ok "aged files in responses/requests/staging are selected; fresh files + .lock (even if aged) are never selected"
else
    bad "stale-selection wrong (got: $stale)"
fi

# TTL boundary: a file just inside the TTL is kept, a file well past it is selected.
: > "$SPOOL/responses/almost-fresh"; touch -d '30 seconds ago' "$SPOOL/responses/almost-fresh"
stale2="$(reaper_stale_spool_files "$SPOOL" 3600)"
if ! grep -q "almost-fresh" <<<"$stale2"; then
    ok "a file well inside the TTL (30s old, 3600s TTL) is kept"
else
    bad "a fresh (30s old) file must not be selected under a 3600s TTL"
fi

# Missing dirs are a no-op, not an error (a controller that never started the broker).
EMPTY_SPOOL="$TMPD/empty-spool"
out3="$(reaper_stale_spool_files "$EMPTY_SPOOL" 3600 2>&1)"; rc3=$?
[[ -z "$out3" && $rc3 -eq 0 ]] && ok "a spool dir with no responses/requests/staging subdirs is a silent no-op" \
    || bad "a missing spool dir must no-op cleanly (rc=$rc3, out='$out3')"

# --- reaper_once: idempotent + fail-safe (docker error → warn, never die) -------------------
echo
echo "== reaper_once: idempotent, fail-safe on docker error =="

CLAUDE_BROKER_DIR="$TMPD/idem-spool"
mkdir -p "$CLAUDE_BROKER_DIR/responses" "$CLAUDE_BROKER_DIR/requests" "$CLAUDE_BROKER_DIR/staging"
: > "$CLAUDE_BROKER_DIR/responses/aged"; touch -d '2 hours ago' "$CLAUDE_BROKER_DIR/responses/aged"
reaper_docker() {
    case "$*" in
        *"status=exited"*) echo "exited-once" ;;
        *) return 1 ;;
    esac
}
export CLAUDE_BROKER_DIR
first="$(reaper_once 2>&1)"; rc_first=$?
if (( rc_first == 0 )) && [[ ! -f "$CLAUDE_BROKER_DIR/responses/aged" ]]; then
    ok "first reaper_once run removes the aged spool file and exits 0"
else
    bad "first reaper_once run must exit 0 and remove the aged file (rc=$rc_first, still-there=$([[ -f "$CLAUDE_BROKER_DIR/responses/aged" ]] && echo yes || echo no))"
fi

second="$(reaper_once 2>&1)"; rc_second=$?
if (( rc_second == 0 )) && grep -q "pruned 0 spool file" <<<"$second"; then
    ok "a second reaper_once run over already-clean state is idempotent (0 pruned, still exits 0)"
else
    bad "second run must be a no-op (rc=$rc_second, out=$second)"
fi
unset CLAUDE_BROKER_DIR

echo
echo "== reaper_once: a failing reaper_docker warns, never dies (fail-safe) =="

reaper_docker() { return 1; }
CLAUDE_BROKER_DIR="$TMPD/dead-daemon-spool"
mkdir -p "$CLAUDE_BROKER_DIR/responses"
out4="$(CLAUDE_BROKER_DIR="$CLAUDE_BROKER_DIR" reaper_once 2>&1)"; rc4=$?
if (( rc4 == 0 )) && grep -qi "warn" <<<"$out4"; then
    ok "a totally failing docker still lets reaper_once complete (warn, exit 0 — never die mid-reap)"
else
    bad "a failing docker must not kill reaper_once (rc=$rc4, out=$out4)"
fi

# --- CLAUDE_REAPER_DRYRUN: reports without removing/pruning ---------------------------------
echo
echo "== CLAUDE_REAPER_DRYRUN: reports, changes nothing =="

reaper_docker() {
    case "$*" in
        *"status=exited"*) echo "dry-exited" ;;
        *) return 1 ;;
    esac
}
DRY_SPOOL="$TMPD/dry-spool"
mkdir -p "$DRY_SPOOL/responses"
: > "$DRY_SPOOL/responses/dry-aged"; touch -d '2 hours ago' "$DRY_SPOOL/responses/dry-aged"
out5="$(CLAUDE_BROKER_DIR="$DRY_SPOOL" CLAUDE_REAPER_DRYRUN=1 reaper_once 2>&1)"
if grep -q "TEST SEAM ACTIVE" <<<"$out5" && grep -q "would remove" <<<"$out5" && grep -q "would prune" <<<"$out5"; then
    ok "DRYRUN loudly warns and reports what it WOULD do"
else
    bad "DRYRUN must warn + report intended actions (got: $out5)"
fi
if [[ -f "$DRY_SPOOL/responses/dry-aged" ]]; then
    ok "DRYRUN removes nothing — the aged spool file is still there"
else
    bad "DRYRUN must not actually prune anything"
fi

echo
echo "== $PASS passed, $FAIL failed =="
exit $(( FAIL > 0 ? 1 : 0 ))
