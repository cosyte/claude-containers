#!/usr/bin/env bash
# Unit tests for the surviving resource-sizing surface — NO docker, NO sysbox, NO root.
#
# SC-5 removed the K-aware Sysbox-controller-envelope sizing (controller_envelope,
# CLAUDE_WORKER_*/CLAUDE_CTRL_* profile, resolve_parallel_k, bin/claude-controller-size,
# and the broker's capacity fail-safe) — that machinery existed solely to size a
# controller for K nested Sysbox workers, which no longer exist; see
# docs/legacy-sysbox-broker.md. What survives, and what this covers, is the
# non-broker sizing surface in bin/_common.sh:
#   - size_to_mib / mem_reservation_for (docker size parsing + the 75% derivation)
#   - the flat-session CLAUDE_MEM_RESERVATION derivation at source time
#   - claude-compose-gen's per-service mem_reservation/pids_limit emission
#   - the static docker-compose.yml's opt-in reservation default
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# --- Hermetic repo root (no .env) ----------------------------------------------------
# These tests drive the sizing derivations by passing CLAUDE_MEM_LIMIT etc. through the
# AMBIENT env. But bin/_common.sh sources the repo's .env with `set -a`, and its documented
# precedence is "ambient env < base .env" — so on any machine that HAS a real .env, the
# repo's own CLAUDE_MEM_LIMIT overrode the value under test and these assertions read the
# developer's config instead of their input. It passed only on a checkout with no .env (CI),
# and failed on every configured host (e.g. a 16g .env made the 8g→6144m case read 12288m).
#
# So source _common.sh from a throwaway root that has bin/ and deliberately NO .env. The
# code under test is byte-identical; only the ambient config is removed. Keep new sizing
# cases pointed at $HERMETIC_ROOT, not $REPO_ROOT.
HERMETIC_ROOT="$TMPD/hermetic"
mkdir -p "$HERMETIC_ROOT"
cp -R "$REPO_ROOT/bin" "$HERMETIC_ROOT/bin"

# shellcheck disable=SC1091
source "$HERMETIC_ROOT/bin/_common.sh"
set +e

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

# --- size_to_mib ---------------------------------------------------------------------
echo "== size_to_mib: docker sizes → MiB, garbage refuses =="

t_size() {  # t_size <input> <want|FAIL>
    local got rc
    got="$(size_to_mib "$1")"; rc=$?
    if [[ "$2" == FAIL ]]; then
        (( rc != 0 )) && ok "'$1' is refused (fail closed)" || bad "'$1' must be refused (got '$got')"
    else
        [[ $rc -eq 0 && "$got" == "$2" ]] && ok "'$1' → $2 MiB" || bad "'$1' → want $2, got '$got' (rc=$rc)"
    fi
}
t_size 4g 4096
t_size 3g 3072
t_size 2048m 2048
t_size 1G 1024
t_size 512k 1
t_size 1048576b 1
t_size 1048577 2
t_size 0 0
t_size 4.5g FAIL
t_size -1g FAIL
t_size banana FAIL
t_size "" FAIL
t_size "4g " FAIL

if [[ "$(mem_reservation_for 4g)" == 3072m && "$(mem_reservation_for 2g)" == 1536m ]]; then
    ok "mem_reservation_for derives 75% (4g→3072m, 2g→1536m)"
else
    bad "mem_reservation_for must derive 75% (got $(mem_reservation_for 4g) / $(mem_reservation_for 2g))"
fi
if mem_reservation_for banana >/dev/null 2>&1; then
    bad "mem_reservation_for must refuse garbage"
else
    ok "mem_reservation_for refuses garbage (fail closed)"
fi

# Derived flat-session reservation at source time: 75% of an overridden limit,
# and an explicit reservation wins.
derived="$(env CLAUDE_MEM_LIMIT=8g bash -c 'source "'"$HERMETIC_ROOT"'/bin/_common.sh"; echo "$CLAUDE_MEM_RESERVATION"')"
[[ "$derived" == 6144m ]] && ok "CLAUDE_MEM_RESERVATION derives from an overridden limit (8g → 6144m)" \
    || bad "derived reservation for 8g must be 6144m (got '$derived')"
explicit="$(env CLAUDE_MEM_LIMIT=8g CLAUDE_MEM_RESERVATION=1g bash -c 'source "'"$HERMETIC_ROOT"'/bin/_common.sh"; echo "$CLAUDE_MEM_RESERVATION"')"
[[ "$explicit" == 1g ]] && ok "an explicit CLAUDE_MEM_RESERVATION wins over the derivation" \
    || bad "explicit reservation must win (got '$explicit')"
if env CLAUDE_MEM_LIMIT=banana bash -c 'source "'"$HERMETIC_ROOT"'/bin/_common.sh"' >/dev/null 2>&1; then
    bad "a garbage CLAUDE_MEM_LIMIT must refuse at source time (fail closed)"
else
    ok "a garbage CLAUDE_MEM_LIMIT refuses at source time (fail closed)"
fi

# --- static docker-compose.yml: reservation stays opt-in --------------------------------
echo
echo "== static docker-compose.yml: mem_reservation opt-in (0) + carries pids_limit =="

# The static docker-compose.yml cannot run the 75% derivation, so its
# reservation must stay OPT-IN (default 0 = disabled) — a fixed default like 3g
# would invert against a lowered CLAUDE_MEM_LIMIT and dockerd would reject the
# container.
if grep -q 'mem_reservation: ${CLAUDE_MEM_RESERVATION:-0}' "$REPO_ROOT/docker-compose.yml" \
   && grep -q 'pids_limit: ${CLAUDE_PIDS_LIMIT:-2048}' "$REPO_ROOT/docker-compose.yml"; then
    ok "static docker-compose.yml keeps the reservation opt-in (0) + carries pids_limit"
else
    bad "static docker-compose.yml must default mem_reservation to 0 (opt-in) and carry pids_limit"
fi

# --- compose-gen emits the guards ----------------------------------------------------------
echo
echo "== claude-compose-gen: mem_reservation + pids_limit ride every service =="

OUT="$TMPD/out/compose.yml"
if env CLAUDE_MEM_LIMIT=4g CLAUDE_PIDS_LIMIT=2048 \
    "$HERMETIC_ROOT/bin/claude-compose-gen" --out "$OUT" acme/api acme/worker:main >/dev/null 2>&1; then
    if grep -q "mem_reservation: 3072m" "$OUT" && grep -q "pids_limit: 2048" "$OUT"; then
        ok "services carry the derived mem_reservation (3072m) + pids_limit (2048)"
    else
        bad "generated compose must carry mem_reservation + pids_limit"
    fi
else
    bad "compose-gen failed to generate (see above)"
fi
rm -f "$OUT"
if env CLAUDE_MEM_LIMIT=4g \
    "$HERMETIC_ROOT/bin/claude-compose-gen" --out "$OUT" --mem api=2g acme/api >/dev/null 2>&1; then
    if grep -q "mem_limit: 2g" "$OUT" && grep -q "mem_reservation: 1536m" "$OUT"; then
        ok "a per-repo --mem override derives its own 75% reservation (2g → 1536m, never inverted)"
    else
        bad "per-repo --mem override must derive a matching reservation (got: $(grep -E 'mem_' "$OUT" | tr '\n' ' '))"
    fi
else
    bad "compose-gen --mem override run failed"
fi

echo
echo "== $PASS passed, $FAIL failed =="
exit $(( FAIL > 0 ? 1 : 0 ))
