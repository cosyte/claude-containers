#!/usr/bin/env bash
# Unit tests for the K-aware sizing + single-source config (CC-3) in bin/_common.sh.
# NO docker, NO sysbox — pure arithmetic + config resolution, safe for CI and verify.sh.
# The on-host K-worker isolation proof (OOM/pids/Σ-ceiling) lives in bin/claude-cgroup-verify
# and needs Sysbox; it is deliberately NOT run here.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

# Run a snippet in a subshell that sources _common.sh. Prints the snippet's stdout;
# the caller asserts on it and/or the exit code. Extra env before `--`.
in_env() {  # in_env <env...> -- <snippet>
    local envs=()
    while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done
    shift
    ( if (( ${#envs[@]} )); then export "${envs[@]}" 2>/dev/null; fi   # never `export` with no args (dumps the env)
      # shellcheck disable=SC1091
      source "$REPO_ROOT/bin/_common.sh"
      eval "$1"
    ) 2>/dev/null
}
# exit-code-only variant (stdout+stderr discarded).
rc_env() { in_env "$@" >/dev/null 2>&1; }

echo "== resolve_k: explicit override + validation =="

[[ "$(in_env CLAUDE_K=3 -- 'resolve_k')" == 3 ]] \
    && ok "CLAUDE_K=3 is honored" || bad "CLAUDE_K override must win"

if rc_env CLAUDE_K=banana -- 'resolve_k'; then
    bad "a non-integer CLAUDE_K must be REFUSED (fail closed)"
else
    ok "a non-integer CLAUDE_K is refused (fail closed)"
fi

if rc_env CLAUDE_K=0 -- 'resolve_k'; then
    bad "K=0 must be REFUSED — the engine needs at least one worker"
else
    ok "K=0 is refused (>= 1 required)"
fi

echo
echo "== resolve_k: single-sourced from the umbrella parallel.config.json =="

CFG="$(mktemp)"; trap 'rm -f "$CFG" "$CFG.bad" "$CFG.k4"' EXIT
printf '{ "K": 2, "leaseTtlMinutes": 90 }\n' > "$CFG"
[[ "$(in_env COSYTE_PARALLEL_CONFIG="$CFG" -- 'resolve_k')" == 2 ]] \
    && ok "K is read from parallel.config.json (.K=2)" || bad "must read .K from the umbrella config"

printf '{ "K": 4 }\n' > "$CFG.k4"
[[ "$(in_env COSYTE_PARALLEL_CONFIG="$CFG.k4" -- 'resolve_k')" == 4 ]] \
    && ok "a ramped K (=4) is read straight from the config (no forked literal)" || bad "K=4 from config must be read"

printf '{ "K": "nope" }\n' > "$CFG.bad"
if rc_env COSYTE_PARALLEL_CONFIG="$CFG.bad" -- 'resolve_k'; then
    bad "a present-but-garbage K must REFUSE (fail closed), not default"
else
    ok "a present-but-garbage K in the config refuses (fail closed)"
fi

printf '{ "K": 2.5 }\n' > "$CFG.bad"
if rc_env COSYTE_PARALLEL_CONFIG="$CFG.bad" -- 'resolve_k'; then
    bad "a float K (2.5) must REFUSE — not truncate to 2 (jq + sed paths must agree)"
else
    ok "a float K (2.5) refuses (not silently truncated)"
fi

# A config path that does not exist → treated as 'no umbrella config' → standalone K=1.
[[ "$(in_env COSYTE_PARALLEL_CONFIG=/nonexistent-cc3.json -- 'resolve_k')" == 1 ]] \
    && ok "absent umbrella config → K=1 (standalone, single-container)" || bad "absent config must collapse to K=1"

echo
echo "== mem_to_mib / mib_to_docker: size arithmetic, fail-closed on garbage =="

check_mem() { local got; got="$(in_env -- "mem_to_mib $1")"; [[ "$got" == "$2" ]] \
    && ok "mem_to_mib $1 = $2" || bad "mem_to_mib $1 got '$got' want $2"; }
check_mem 4g 4096
check_mem 512m 512
check_mem 1024k 1
check_mem 2097152b 2
check_mem 1048576 1          # bare number = bytes (Docker convention)
if rc_env -- 'mem_to_mib 4gg'; then bad "mem_to_mib must fail on garbage"; else ok "mem_to_mib fails closed on garbage (4gg)"; fi

check_doc() { local got; got="$(in_env -- "mib_to_docker $1")"; [[ "$got" == "$2" ]] \
    && ok "mib_to_docker $1 = $2" || bad "mib_to_docker $1 got '$got' want $2"; }
check_doc 4096 4g
check_doc 768 768m
check_doc 10240 10g

echo
echo "== controller_envelope: Σ(K workers) + overhead (roadmap §5 numbers) =="

# Defaults: worker 4g/2cpu/2g-shm, overhead 2g/1cpu.
env2="$(in_env -- 'controller_envelope 2; echo "$CTRL_CPUS $CTRL_MEM $CTRL_MEM_MIB $CTRL_SHM"')"
[[ "$env2" == "5 10g 10240 4g" ]] \
    && ok "K=2 → 5 CPU / 10g / 4g shm (matches roadmap §5 'nested ≥ ~10 GB / ~5 CPU')" \
    || bad "K=2 envelope wrong: got '$env2' want '5 10g 10240 4g'"

env4="$(in_env -- 'controller_envelope 4; echo "$CTRL_CPUS $CTRL_MEM $CTRL_MEM_MIB $CTRL_SHM"')"
[[ "$env4" == "9 18g 18432 8g" ]] \
    && ok "K=4 (deferred ceiling) → 9 CPU / 18g / 8g shm (matches roadmap §5)" \
    || bad "K=4 envelope wrong: got '$env4' want '9 18g 18432 8g'"

# Fractional CPU profile renders cleanly (--cpus accepts floats).
fc="$(in_env CLAUDE_WORKER_CPUS=0.5 CLAUDE_CONTROLLER_CPU_OVERHEAD=0 -- 'controller_envelope 1; echo "$CTRL_CPUS $CTRL_CPUS_MILLI"')"
[[ "$fc" == "0.50 500" ]] \
    && ok "fractional CPU profile renders (0.5×1 → 0.50 CPU / 500 milli)" || bad "fractional CPU wrong: got '$fc'"

# An integer-valued fractional sum trims to an integer.
fi_="$(in_env CLAUDE_WORKER_CPUS=1.5 CLAUDE_CONTROLLER_CPU_OVERHEAD=1 -- 'controller_envelope 2; echo "$CTRL_CPUS"')"
[[ "$fi_" == "4" ]] && ok "2×1.5+1 = 4 renders as an integer (no trailing .0)" || bad "integer-sum CPU wrong: got '$fi_'"

if rc_env CLAUDE_WORKER_MEM=bogus -- 'controller_envelope 2'; then
    bad "controller_envelope must fail closed on an unparseable worker mem"
else
    ok "controller_envelope fails closed on an unparseable worker mem"
fi

if rc_env CLAUDE_WORKER_MEM=0g -- 'controller_envelope 2'; then
    bad "a zero-sized worker (0g) must REFUSE — not size a controller of pure overhead"
else
    ok "a zero-sized worker mem (0g) refuses (no all-overhead controller that 'fits' anything)"
fi

if rc_env CLAUDE_WORKER_PIDS='oops"' -- 'controller_envelope 2'; then
    bad "a garbage CLAUDE_WORKER_PIDS must REFUSE (fail closed; it feeds --pids-limit + JSON)"
else
    ok "a garbage CLAUDE_WORKER_PIDS refuses (fail closed)"
fi
if rc_env CLAUDE_WORKER_PIDS=0 -- 'controller_envelope 2'; then
    bad "CLAUDE_WORKER_PIDS=0 must REFUSE (a positive integer is required)"
else
    ok "CLAUDE_WORKER_PIDS=0 refuses (positive integer required)"
fi

echo
echo "== check_controller_capacity: the fail-safe (never overcommit) =="

# Fits: small profile on a generous pretend host → returns 0.
if rc_env CLAUDE_WORKER_MEM=256m CLAUDE_CONTROLLER_MEM_OVERHEAD=256m CLAUDE_WORKER_CPUS=1 \
          CLAUDE_HOST_CPUS_OVERRIDE=8 CLAUDE_HOST_MEM_MIB_OVERRIDE=16384 -- 'check_controller_capacity 2'; then
    ok "a fitting K passes the capacity check"
else
    bad "a fitting K must pass the capacity check"
fi

# Over memory: 2×64g on a 2 GB host → REFUSE.
if rc_env CLAUDE_WORKER_MEM=64g CLAUDE_HOST_CPUS_OVERRIDE=64 CLAUDE_HOST_MEM_MIB_OVERRIDE=2048 -- 'check_controller_capacity 2'; then
    bad "an over-memory K must be REFUSED (never overcommit)"
else
    ok "an over-memory K is refused (never overcommit)"
fi

# Over CPU: 2×2cpu+1 = 5 on a 2-CPU host → REFUSE.
if rc_env CLAUDE_HOST_CPUS_OVERRIDE=2 CLAUDE_HOST_MEM_MIB_OVERRIDE=65536 -- 'check_controller_capacity 2'; then
    bad "an over-CPU K must be REFUSED"
else
    ok "an over-CPU K is refused"
fi

# Unprobeable host (0) → cannot prove headroom → REFUSE (fail closed).
if rc_env CLAUDE_HOST_CPUS_OVERRIDE=0 CLAUDE_HOST_MEM_MIB_OVERRIDE=0 -- 'check_controller_capacity 2'; then
    bad "an unprobeable host must REFUSE (fail closed), not wave through"
else
    ok "an unprobeable host refuses (fail closed — cannot prove headroom)"
fi

echo
echo "== single-source: the worker profile is defined once in _common.sh =="

# The broker reads CLAUDE_WORKER_MEM from _common.sh — the default lands there, not
# in a forked literal. Assert the canonical default is present after sourcing.
prof="$(in_env -- 'echo "$CLAUDE_WORKER_MEM $CLAUDE_WORKER_PIDS $CLAUDE_WORKER_CPUS"')"
[[ "$prof" == "4g 2048 2" ]] \
    && ok "the per-worker profile default (4g/2048/2) is single-sourced in _common.sh" \
    || bad "profile default wrong: got '$prof'"

echo
echo "== leaf_resource_args: opt-in, empty by default (K=1 byte-identical) =="

[[ -z "$(in_env -- 'leaf_resource_args')" ]] \
    && ok "leaf_resource_args is EMPTY by default (flat launch unchanged)" || bad "leaf args must be empty by default"
[[ "$(in_env CLAUDE_MEM_RESERVATION=3g CLAUDE_PIDS_LIMIT=2048 -- 'leaf_resource_args')" == "--memory-reservation 3g --pids-limit 2048" ]] \
    && ok "leaf_resource_args emits both flags when set" || bad "leaf args emission wrong"
[[ "$(in_env CLAUDE_PIDS_LIMIT=2048 -- 'leaf_resource_args')" == "--pids-limit 2048" ]] \
    && ok "leaf_resource_args emits just the one flag that is set" || bad "leaf args single-flag wrong"

echo
echo "== $PASS passed, $FAIL failed =="
exit $(( FAIL > 0 ? 1 : 0 ))
