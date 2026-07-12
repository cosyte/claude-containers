#!/usr/bin/env bash
# Unit tests for bin/claude-reaper — NO docker, NO sysbox, NO root.
#
# SC-5 removed claude-reaper's worker-container-reaping duty (it targeted
# `claude.worker=1` containers the deleted broker/worker-run launched — see
# docs/legacy-sysbox-broker.md). What's left, and what this covers, is the
# spool-pruning duty: reaper_stale_spool_files against a real (tmp) spool with
# touch -d'd mtimes, the never-touch-.lock guarantee, idempotency, and the
# fail-safe posture (a prune error warns and continues — reaper_once must
# never die mid-reap).
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

# --- reaper_stale_spool_files: stale selected, fresh + .lock kept ---------------------------
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

# Missing dirs are a no-op, not an error.
EMPTY_SPOOL="$TMPD/empty-spool"
out3="$(reaper_stale_spool_files "$EMPTY_SPOOL" 3600 2>&1)"; rc3=$?
[[ -z "$out3" && $rc3 -eq 0 ]] && ok "a spool dir with no responses/requests/staging subdirs is a silent no-op" \
    || bad "a missing spool dir must no-op cleanly (rc=$rc3, out='$out3')"

# --- reaper_once: idempotent + fail-safe -----------------------------------------------------
echo
echo "== reaper_once: idempotent, fail-safe =="

CLAUDE_REAPER_SPOOL_DIR="$TMPD/idem-spool"
mkdir -p "$CLAUDE_REAPER_SPOOL_DIR/responses" "$CLAUDE_REAPER_SPOOL_DIR/requests" "$CLAUDE_REAPER_SPOOL_DIR/staging"
: > "$CLAUDE_REAPER_SPOOL_DIR/responses/aged"; touch -d '2 hours ago' "$CLAUDE_REAPER_SPOOL_DIR/responses/aged"
export CLAUDE_REAPER_SPOOL_DIR
first="$(reaper_once 2>&1)"; rc_first=$?
if (( rc_first == 0 )) && [[ ! -f "$CLAUDE_REAPER_SPOOL_DIR/responses/aged" ]]; then
    ok "first reaper_once run removes the aged spool file and exits 0"
else
    bad "first reaper_once run must exit 0 and remove the aged file (rc=$rc_first, still-there=$([[ -f "$CLAUDE_REAPER_SPOOL_DIR/responses/aged" ]] && echo yes || echo no))"
fi

second="$(reaper_once 2>&1)"; rc_second=$?
if (( rc_second == 0 )) && grep -q "pruned 0 spool file" <<<"$second"; then
    ok "a second reaper_once run over already-clean state is idempotent (0 pruned, still exits 0)"
else
    bad "second run must be a no-op (rc=$rc_second, out=$second)"
fi
unset CLAUDE_REAPER_SPOOL_DIR

echo
echo "== reaper_once: a failing prune warns, never dies (fail-safe) =="

FAIL_SPOOL="$TMPD/unwritable-spool"
mkdir -p "$FAIL_SPOOL/responses"
: > "$FAIL_SPOOL/responses/aged"; touch -d '2 hours ago' "$FAIL_SPOOL/responses/aged"
chmod 500 "$FAIL_SPOOL/responses"   # dir not writable -> rm -f on its contents fails
out4="$(CLAUDE_REAPER_SPOOL_DIR="$FAIL_SPOOL" reaper_once 2>&1)"; rc4=$?
chmod 700 "$FAIL_SPOOL/responses"   # restore so the outer TMPD cleanup can remove it
if (( rc4 == 0 )) && grep -qi "warn" <<<"$out4"; then
    ok "a prune failure still lets reaper_once complete (warn, exit 0 — never die mid-reap)"
else
    bad "a failing prune must not kill reaper_once (rc=$rc4, out=$out4)"
fi

# --- CLAUDE_REAPER_DRYRUN: reports without pruning -------------------------------------------
echo
echo "== CLAUDE_REAPER_DRYRUN: reports, changes nothing =="

DRY_SPOOL="$TMPD/dry-spool"
mkdir -p "$DRY_SPOOL/responses"
: > "$DRY_SPOOL/responses/dry-aged"; touch -d '2 hours ago' "$DRY_SPOOL/responses/dry-aged"
out5="$(CLAUDE_REAPER_SPOOL_DIR="$DRY_SPOOL" CLAUDE_REAPER_DRYRUN=1 reaper_once 2>&1)"
if grep -q "TEST SEAM ACTIVE" <<<"$out5" && grep -q "would prune" <<<"$out5"; then
    ok "DRYRUN loudly warns and reports what it WOULD do"
else
    bad "DRYRUN must warn + report intended actions (got: $out5)"
fi
if [[ -f "$DRY_SPOOL/responses/dry-aged" ]]; then
    ok "DRYRUN prunes nothing — the aged spool file is still there"
else
    bad "DRYRUN must not actually prune anything"
fi

# --- reaper_main: unknown flag refused, one-shot vs --loop dispatch -------------------------
echo
echo "== reaper_main: unknown flag refused =="

if (reaper_main --bogus) >/dev/null 2>&1; then
    bad "reaper_main must reject an unknown flag"
else
    ok "reaper_main rejects an unknown flag"
fi

echo
echo "== $PASS passed, $FAIL failed =="
exit $(( FAIL > 0 ? 1 : 0 ))
