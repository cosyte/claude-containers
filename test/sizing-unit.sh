#!/usr/bin/env bash
# Unit tests for the K-aware resource sizing (CC-3) — NO docker, NO sysbox, NO root.
#
# Covers the pure-logic sizing surface in bin/_common.sh (size parsing, K
# resolution from the umbrella parallel.config.json, the controller envelope),
# the bin/claude-controller-size flags/refusal CLI, the broker's capacity
# fail-safe (via the CLAUDE_BROKER_FAKE_CGROUP_DIR seam), and the compose-gen
# reservation/pids emission. The on-host enforcement matrix (limits enforce
# inside Sysbox, OOM isolation, fork-bomb, real-path overcommit refusal) is
# bin/claude-sizing-verify and needs Sysbox; it is deliberately NOT run here.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# shellcheck disable=SC1091
source "$REPO_ROOT/bin/claude-worker-broker"   # sourcing defines functions and returns
set +e

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

# The pinned profile every math test runs against (defaults; explicit so a local
# .env can't skew the goldens).
PROFILE_ENV=(CLAUDE_WORKER_MEM=4g CLAUDE_WORKER_MEM_RESERVATION=3g CLAUDE_WORKER_CPUS=2
             CLAUDE_WORKER_PIDS=2048 CLAUDE_WORKER_SHM=2g
             CLAUDE_CTRL_CPU_OVERHEAD=1 CLAUDE_CTRL_MEM_OVERHEAD_MIB=2048
             CLAUDE_CTRL_PIDS_OVERHEAD=1024)

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
derived="$(env CLAUDE_MEM_LIMIT=8g bash -c 'source "'"$REPO_ROOT"'/bin/_common.sh"; echo "$CLAUDE_MEM_RESERVATION"')"
[[ "$derived" == 6144m ]] && ok "CLAUDE_MEM_RESERVATION derives from an overridden limit (8g → 6144m)" \
    || bad "derived reservation for 8g must be 6144m (got '$derived')"
explicit="$(env CLAUDE_MEM_LIMIT=8g CLAUDE_MEM_RESERVATION=1g bash -c 'source "'"$REPO_ROOT"'/bin/_common.sh"; echo "$CLAUDE_MEM_RESERVATION"')"
[[ "$explicit" == 1g ]] && ok "an explicit CLAUDE_MEM_RESERVATION wins over the derivation" \
    || bad "explicit reservation must win (got '$explicit')"
if env CLAUDE_MEM_LIMIT=banana bash -c 'source "'"$REPO_ROOT"'/bin/_common.sh"' >/dev/null 2>&1; then
    bad "a garbage CLAUDE_MEM_LIMIT must refuse at source time (fail closed)"
else
    ok "a garbage CLAUDE_MEM_LIMIT refuses at source time (fail closed)"
fi

# --- resolve_parallel_k ----------------------------------------------------------------
echo
echo "== resolve_parallel_k: umbrella config is the one source of truth =="

t_k() {  # t_k <config-json|-> <want|FAIL> <label>
    local cfg="" got rc
    if [[ "$1" != "-" ]]; then
        cfg="$TMPD/parallel.config.json"; printf '%s' "$1" > "$cfg"
    fi
    got="$( (CLAUDE_PARALLEL_CONFIG="$cfg" resolve_parallel_k) 2>/dev/null )"; rc=$?
    if [[ "$2" == FAIL ]]; then
        (( rc != 0 )) && ok "$3" || bad "$3 (must refuse, got '$got')"
    else
        [[ $rc -eq 0 && "$got" == "$2" ]] && ok "$3" || bad "$3 (want $2, got '$got' rc=$rc)"
    fi
}
t_k '{"K": 2, "leaseTtlMinutes": 90}' 2 "the umbrella shape parses (K=2)"
t_k '{"K": 3}' 3 "K=3 parses"
t_k '{"K": 0}' FAIL "K=0 is refused (not a sane parallelism)"
t_k '{"K": 17}' FAIL "K=17 is refused (sanity ceiling)"
t_k '{"K": "banana"}' FAIL "a garbage K is refused (fail closed — never silently 2)"
t_k '{"K": 2.5}' FAIL "a fractional K is refused"
t_k '{"leaseTtlMinutes": 90}' FAIL "a config missing K is refused"
t_k 'not json at all' FAIL "an unparseable config is refused"

if (CLAUDE_PARALLEL_CONFIG="$TMPD/nope.json" resolve_parallel_k) >/dev/null 2>&1; then
    bad "an explicit CLAUDE_PARALLEL_CONFIG that doesn't exist must refuse"
else
    ok "an explicit CLAUDE_PARALLEL_CONFIG that doesn't exist refuses (never silently ignored)"
fi

# The no-jq grep fallback must be exactly as strict as the jq path. Exercise it
# by calling resolve_parallel_k under a PATH that has no jq (symlink only the
# tools the fallback needs) — a fractional K must REFUSE, never truncate to its
# integer part, and a valid integer K must still parse.
NOJQ="$TMPD/nojq-bin"; mkdir -p "$NOJQ"
for t in grep head sed cat awk; do
    p="$(command -v "$t")" && ln -s "$p" "$NOJQ/$t"
done
printf '%s' '{"K": 2.5}' > "$TMPD/frac.json"
if (PATH="$NOJQ" CLAUDE_PARALLEL_CONFIG="$TMPD/frac.json" resolve_parallel_k) >/dev/null 2>&1; then
    bad "the no-jq fallback must refuse a fractional K (2.5), not truncate it to 2"
else
    ok  "the no-jq fallback refuses a fractional K (fail closed, same bar as jq)"
fi
printf '%s' '{"K": 3, "leaseTtlMinutes": 90}' > "$TMPD/int.json"
got="$( (PATH="$NOJQ" CLAUDE_PARALLEL_CONFIG="$TMPD/int.json" resolve_parallel_k) 2>/dev/null )"
[[ "$got" == 3 ]] && ok "the no-jq fallback parses a valid integer K" \
    || bad "the no-jq fallback must parse K=3 (got '$got')"

# No config anywhere → the documented default 2, with a warning. Point the
# repo-root fallback at an empty dir; skip if this environment has a real
# /workspace umbrella (a container run), which resolve would legitimately find.
if [[ -f /workspace/operations/parallel.config.json ]]; then
    ok "SKIP: /workspace umbrella present — default-K path not testable here"
else
    out="$( (CLAUDE_DOCKER_ROOT="$TMPD" resolve_parallel_k) 2>&1 )"; rc=$?
    if [[ $rc -eq 0 && "$(tail -1 <<<"$out")" == 2 ]] && grep -q "default K=2" <<<"$out"; then
        ok "no config found → documented default K=2, loudly"
    else
        bad "no-config default must be 2 with a warning (rc=$rc, out='$out')"
    fi
fi

# --- controller_envelope -----------------------------------------------------------------
echo
echo "== controller_envelope: Σ(K·worker) + overhead =="

t_env() {  # t_env <K> <cpus> <mem> <res> <pids>
    local out
    out="$(env "${PROFILE_ENV[@]}" bash -c '
        source "'"$REPO_ROOT"'/bin/_common.sh"
        controller_envelope "'"$1"'"
        echo "$CTRL_CPUS $CTRL_MEM_MIB $CTRL_MEM_RESERVATION_MIB $CTRL_PIDS"' 2>/dev/null)"
    if [[ "$out" == "$2 $3 $4 $5" ]]; then
        ok "K=$1 → cpus $2 · mem ${3} MiB · reservation ${4} MiB · pids $5"
    else
        bad "K=$1 envelope: want '$2 $3 $4 $5', got '$out'"
    fi
}
t_env 1 3 6144 5120 3072
t_env 2 5 10240 8192 5120
t_env 4 9 18432 14336 9216

out="$(env "${PROFILE_ENV[@]}" CLAUDE_WORKER_CPUS=1.5 bash -c '
    source "'"$REPO_ROOT"'/bin/_common.sh"; controller_envelope 2; echo "$CTRL_CPUS"' 2>/dev/null)"
[[ "$out" == 4 ]] && ok "fractional worker cpus compose (1.5·2+1 → 4)" \
    || bad "fractional cpus: want 4, got '$out'"

for bad_env in CLAUDE_WORKER_MEM=banana CLAUDE_WORKER_PIDS=lots CLAUDE_WORKER_CPUS=fast; do
    if env "${PROFILE_ENV[@]}" "$bad_env" bash -c \
        'source "'"$REPO_ROOT"'/bin/_common.sh"; controller_envelope 2' >/dev/null 2>&1; then
        bad "a garbage profile ($bad_env) must refuse (fail closed)"
    else
        ok "a garbage profile ($bad_env) refuses (fail closed)"
    fi
done

# --- claude-controller-size CLI -----------------------------------------------------------
echo
echo "== claude-controller-size: generated flags match the K-derived budget =="

golden="$(cat <<'EOF'
--runtime=sysbox-runc
--cpus
5
--memory
10240m
--memory-reservation
8192m
--pids-limit
5120
EOF
)"
got="$(env "${PROFILE_ENV[@]}" "$REPO_ROOT/bin/claude-controller-size" --k 2 --flags --no-check 2>/dev/null)"
if [[ "$got" == "$golden" ]]; then
    ok "K=2 --flags matches the golden argv exactly"
else
    bad "K=2 --flags drifted from the golden:"
    diff <(echo "$golden") <(echo "$got") | sed 's/^/        /'
fi

if out="$(env "${PROFILE_ENV[@]}" "$REPO_ROOT/bin/claude-controller-size" --k 9999 2>&1)"; then
    bad "--k 9999 must be refused on any real host (got: $(head -1 <<<"$out"))"
else
    grep -q "REFUSING" <<<"$out" && ok "--k 9999 refuses with the deficit reported (never silently overcommit)" \
        || bad "--k 9999 refusal must say REFUSING (got: $(head -2 <<<"$out"))"
fi
if env "${PROFILE_ENV[@]}" "$REPO_ROOT/bin/claude-controller-size" --k banana >/dev/null 2>&1; then
    bad "--k banana must be refused"
else
    ok "--k banana is refused (fail closed)"
fi
if out="$(env "${PROFILE_ENV[@]}" "$REPO_ROOT/bin/claude-controller-size" --k 2>&1)"; then
    bad "--k with no value must be refused"
else
    grep -q "needs a value" <<<"$out" && ok "--k with no value dies with a clear message" \
        || bad "--k with no value must die cleanly, not as an unbound-variable trace (got: $(head -1 <<<"$out"))"
fi

# The static docker-compose.yml cannot run the 75% derivation, so its
# reservation must stay OPT-IN (default 0 = disabled) — a fixed default like 3g
# would invert against a lowered CLAUDE_MEM_LIMIT and dockerd would reject the
# container (found by the CC-3 gate-refuter).
if grep -q 'mem_reservation: ${CLAUDE_MEM_RESERVATION:-0}' "$REPO_ROOT/docker-compose.yml" \
   && grep -q 'pids_limit: ${CLAUDE_PIDS_LIMIT:-2048}' "$REPO_ROOT/docker-compose.yml"; then
    ok "static docker-compose.yml keeps the reservation opt-in (0) + carries pids_limit"
else
    bad "static docker-compose.yml must default mem_reservation to 0 (opt-in) and carry pids_limit"
fi

# --- broker capacity fail-safe (CLAUDE_BROKER_FAKE_CGROUP_DIR seam) -----------------------
echo
echo "== broker_check_capacity: an undersized controller refuses to serve =="

mkcg() {  # mkcg <memory.max> <pids.max> <cpu.max> → dir
    local d; d="$(mktemp -d "$TMPD/cg.XXXX")"
    printf '%s\n' "$1" > "$d/memory.max"
    printf '%s\n' "$2" > "$d/pids.max"
    printf '%s\n' "$3" > "$d/cpu.max"
    echo "$d"
}
t_cap() {  # t_cap <cgdir> <cap> <PASS|FAIL> <label> [extra-env...]
    local d="$1" cap="$2" want="$3" label="$4"; shift 4
    ( export "${PROFILE_ENV[@]}" "$@" 2>/dev/null
      export CLAUDE_BROKER_FAKE_CGROUP_DIR="$d"
      BROKER_MAX_WORKERS="$cap"
      broker_check_capacity ) >/dev/null 2>&1
    local rc=$?
    if [[ "$want" == PASS ]]; then
        (( rc == 0 )) && ok "$label" || bad "$label (must pass, rc=$rc)"
    else
        (( rc != 0 )) && ok "$label" || bad "$label (must refuse)"
    fi
}
fits="$(mkcg 10737418240 5120 '500000 100000')"
t_cap "$fits" 2 PASS "cap=2 fits an envelope-sized controller (10240 MiB / 5120 pids / 5 cpus)"
t_cap "$(mkcg 2147483648 5120 '500000 100000')" 2 FAIL "an undersized memory budget (2 GiB) refuses"
t_cap "$(mkcg 10737418240 1024 '500000 100000')" 2 FAIL "an undersized pids budget (1024) refuses"
t_cap "$(mkcg 10737418240 5120 '200000 100000')" 2 FAIL "an undersized cpu budget (2) refuses"
t_cap "$fits" 4 FAIL "raising the cap past the same controller budget refuses (cap=4 needs 18432 MiB)"
t_cap "$fits" banana FAIL "a garbage worker cap refuses (fail closed)"
# Unlimited cgroup ("max") falls back to host MemTotal/nproc — prove with a tiny
# profile so it passes on any CI runner.
t_cap "$(mkcg max max max)" 2 PASS "'max' (unlimited) budgets fall back to host capacity (tiny profile)" \
    CLAUDE_WORKER_MEM=64m CLAUDE_WORKER_MEM_RESERVATION=32m CLAUDE_WORKER_CPUS=0.1 \
    CLAUDE_WORKER_PIDS=16 CLAUDE_CTRL_MEM_OVERHEAD_MIB=16 CLAUDE_CTRL_PIDS_OVERHEAD=16 \
    CLAUDE_CTRL_CPU_OVERHEAD=0.1
# An empty cgroup dir + no /proc/meminfo is untestable portably; the unreadable-
# budget refusal is covered by the die in broker_check_capacity (memory branch)
# via a dir with a garbage memory.max on a host where /proc/meminfo exists →
# falls back to MemTotal and passes; the true blind case only exists on broken
# hosts, where failing closed is exactly the point.

# --- compose-gen emits the guards ----------------------------------------------------------
echo
echo "== claude-compose-gen: mem_reservation + pids_limit ride every service =="

OUT="$TMPD/out/compose.yml"
if env "${PROFILE_ENV[@]}" CLAUDE_MEM_LIMIT=4g CLAUDE_PIDS_LIMIT=2048 \
    "$REPO_ROOT/bin/claude-compose-gen" --out "$OUT" cosyte/hl7 cosyte/mllp:main >/dev/null 2>&1; then
    if grep -q "mem_reservation: 3072m" "$OUT" && grep -q "pids_limit: 2048" "$OUT"; then
        ok "services carry the derived mem_reservation (3072m) + pids_limit (2048)"
    else
        bad "generated compose must carry mem_reservation + pids_limit"
    fi
else
    bad "compose-gen failed to generate (see above)"
fi
rm -f "$OUT"
if env "${PROFILE_ENV[@]}" CLAUDE_MEM_LIMIT=4g \
    "$REPO_ROOT/bin/claude-compose-gen" --out "$OUT" --mem hl7=2g cosyte/hl7 >/dev/null 2>&1; then
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
