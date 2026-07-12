#!/usr/bin/env bash
# Unit tests for the INTERACTIVE-controller feature — an interactive session that can
# spawn autonomous nested workers (`claude-launch --broker`). NO docker, NO sysbox.
#
# Two production changes are covered:
#   A. entrypoint.sh — the CC-6 socket-lockdown barrier now fires on CLAUDE_WORKER_BROKER
#      (not only CLAUDE_CONTROLLER), so an interactive+broker session gets the same
#      boot-race protection; plus the §5a inner-dockerd startup (fail-closed if absent).
#   B. bin/claude-launch — the --sysbox / --broker flags: Sysbox runtime + attestation,
#      controller sizing, the worker-broker env, controller-image auto-select, and
#      (critically) that a plain launch is byte-unchanged.
#   C. the image plumbing (Dockerfile WITH_DOCKER + label, Makefile build-controller,
#      _common.sh CLAUDE_IMAGE_CONTROLLER).
#
# The full on-host proof (build the controller image, run a --broker container, spawn a
# real nested worker through the inner dockerd) is bin/claude-broker-verify +
# bin/claude-sysbox-verify on a Sysbox host; it is deliberately NOT exercised here.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRY="$REPO_ROOT/entrypoint.sh"
LAUNCH="$REPO_ROOT/bin/claude-launch"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
has()  { grep -qF -- "$2" "$1"; }   # has  <file> <fixed-string>
hasE() { grep -qE -- "$2" "$1"; }   # hasE <file> <regex>

# ============================================================================================
echo "== A. entrypoint §5c: the socket-lockdown barrier is BROKER-gated (not controller-only) =="
# ============================================================================================
bash -n "$ENTRY" && ok "entrypoint.sh parses (bash -n)" || bad "entrypoint.sh has a syntax error"

# The barrier's guard must be CLAUDE_WORKER_BROKER. The old CLAUDE_CONTROLLER-only guard on
# this barrier would leave an interactive+broker session unprotected — the exact fix.
if hasE "$ENTRY" 'if \[\[ "\$\{CLAUDE_WORKER_BROKER:-0\}" =~ .* \]\]; then'; then
    ok "the barrier is gated on CLAUDE_WORKER_BROKER"
else
    bad "expected an 'if CLAUDE_WORKER_BROKER' guard on the socket-lockdown barrier"
fi
# Regression, SCOPED to the §5c block (so §5a's earlier WORKER_BROKER guard can't mask a
# revert): the §5c barrier must be guarded by CLAUDE_WORKER_BROKER and NOT reintroduce a
# CLAUDE_CONTROLLER guard. Extract §5c (header → its final serving-confirmed log).
SEC5C="$(sed -n '/# --- 5c\./,/broker serving before the agent session starts/p' "$ENTRY")"
if grep -qF 'CLAUDE_WORKER_BROKER:-0' <<<"$SEC5C" && ! grep -qF 'if [[ "${CLAUDE_CONTROLLER:-0}"' <<<"$SEC5C"; then
    ok "§5c barrier is guarded by CLAUDE_WORKER_BROKER, not CLAUDE_CONTROLLER (scoped, revert-proof)"
else
    bad "§5c barrier guard is wrong (broker gate missing, or a CLAUDE_CONTROLLER guard reappeared)"
fi
# §5c must verify the broker is actually SERVING (its spool), not just socket perms (which
# §5a's pre-lock already sets), and fail fast if the backgrounded broker PID died.
if grep -qF 'broker_serving()' <<<"$SEC5C" && grep -qF 'BROKER_SPOOL' <<<"$SEC5C" \
   && grep -qF 'kill -0 "$BROKER_PID"' <<<"$SEC5C"; then
    ok "§5c waits for the broker to be SERVING (spool dir) + fails fast on a dead broker PID"
else
    bad "§5c does not check broker liveness (spool dir + BROKER_PID) — socket perms alone are insufficient"
fi
# The wait var is the mode-neutral name, with the legacy controller name as a fallback.
if hasE "$ENTRY" 'CLAUDE_BROKER_SOCKET_LOCKDOWN_WAIT:-\$\{CLAUDE_CONTROLLER_SOCKET_WAIT:-90\}'; then
    ok "wait knob is CLAUDE_BROKER_SOCKET_LOCKDOWN_WAIT with the legacy alias fallback"
else
    bad "expected CLAUDE_BROKER_SOCKET_LOCKDOWN_WAIT (legacy: CLAUDE_CONTROLLER_SOCKET_WAIT)"
fi
# Both wait knobs must be validated as POSITIVE integers with no leading zero — a `(( … ))`
# compare parses 090 as octal (infinite spin) and WAIT=0 would time out before dockerd boots.
if [[ "$(grep -cF '=~ ^[1-9][0-9]*$' "$ENTRY")" -ge 2 ]]; then
    ok "CLAUDE_INNER_DOCKERD_WAIT + the socket wait are validated positive/no-leading-zero (octal-safe)"
else
    bad "expected both wait knobs validated with ^[1-9][0-9]*$ (octal/WAIT=0 safe)"
fi

echo "== A2. entrypoint §5a: inner dockerd starts before the broker, fail-closed if absent =="
# The fail-closed guard spans two lines (`command -v dockerd … \` then `|| die …`), so
# assert both halves are present: the probe and the actionable refusal.
if has "$ENTRY" 'command -v dockerd' && has "$ENTRY" "needs an inner Docker daemon, but 'dockerd' is not in this image"; then
    ok "§5a dies (fail closed) when dockerd is absent from the image"
else
    bad "expected a fail-closed 'command -v dockerd || die' in §5a"
fi
if has "$ENTRY" 'dockerd >> /var/log/inner-dockerd.log'; then
    ok "§5a starts the inner dockerd (backgrounded, logged)"
else
    bad "§5a does not start dockerd"
fi
# A stale pidfile from an ungracefully-killed prior daemon must be cleared so a container
# restart (--restart unless-stopped) doesn't boot-loop on 'pidfile already exists'.
if has "$ENTRY" 'rm -f /run/docker.pid /var/run/docker.pid'; then
    ok "§5a clears a stale dockerd pidfile before starting (restart-safe)"
else
    bad "§5a does not clear a stale pidfile — a controller restart can boot-loop"
fi
# Inner dockerd (§5a) must start BEFORE the broker (§5b) — they share one guard now, so the
# dockerd 'starting' log must precede the broker 'starting' log within the block.
a_line="$(grep -n 'starting as root (Sysbox-contained' "$ENTRY" | head -1 | cut -d: -f1)"
b_line="$(grep -n 'Worker broker       : starting as root (agent requests' "$ENTRY" | head -1 | cut -d: -f1)"
if [[ -n "$a_line" && -n "$b_line" ]] && (( a_line < b_line )); then
    ok "inner dockerd (§5a, line $a_line) starts before the broker (§5b, line $b_line)"
else
    bad "inner dockerd must start before the broker (§5a=$a_line, §5b=$b_line)"
fi

echo "== A3. behavioral: the REAL sock_locked predicate fails CLOSED (no root needed) =="
# Extract the actual function text from the entrypoint and exercise it against controllable
# paths. The security-critical direction is the negative: an absent / non-root-owned socket
# must NOT read as locked (that would let the agent start over a reachable inner socket).
SOCK_FN="$(sed -n '/sock_locked() {/,/^    }$/p' "$ENTRY")"
if [[ -n "$SOCK_FN" ]]; then
    ok "extracted the real sock_locked() from entrypoint.sh"
else
    bad "could not extract sock_locked() — did the function move?"
fi
# absent path -> not locked
if ( set +e; eval "$SOCK_FN"; SOCK="$TMPD/nope.sock"; sock_locked ); then
    bad "sock_locked must return non-zero for an ABSENT socket"
else
    ok "sock_locked fails closed on an absent socket"
fi
# a self-owned (non-root) plain file, mode 600 -> not a socket AND owner != root -> not locked
touch "$TMPD/fake" && chmod 600 "$TMPD/fake"
if ( set +e; eval "$SOCK_FN"; SOCK="$TMPD/fake"; sock_locked ); then
    bad "sock_locked must return non-zero for a non-socket / non-root-owned path"
else
    ok "sock_locked fails closed on a non-root-owned path"
fi

# ============================================================================================
echo "== B. claude-launch: --sysbox / --broker wiring =="
# ============================================================================================
bash -n "$LAUNCH" && ok "claude-launch parses (bash -n)" || bad "claude-launch has a syntax error"

# --help must list the new flags (usage() runs before need_docker, so this needs no docker).
help_out="$(bash "$LAUNCH" --help 2>&1 || true)"
grep -q -- '--sysbox' <<<"$help_out" && grep -q -- '--broker' <<<"$help_out" \
    && ok "--help documents --sysbox and --broker" \
    || bad "--help is missing --sysbox / --broker"

hasE "$LAUNCH" '^\s*--sysbox\)' && hasE "$LAUNCH" '^\s*--broker\)' \
    && ok "the arg parser accepts --sysbox and --broker" \
    || bad "claude-launch does not parse --sysbox / --broker"

hasE "$LAUNCH" '\[\[ "\$BROKER" == 1 \]\] && SYSBOX=1' \
    && ok "--broker implies --sysbox" \
    || bad "--broker does not imply --sysbox"

# Sysbox path: attest a CVE-patched Sysbox and pass the attested version in.
has "$LAUNCH" 'preflight_sysbox' && has "$LAUNCH" 'CLAUDE_SYSBOX_ATTESTED_VERSION="$SYSBOX_VERSION"' \
    && ok "--sysbox runs preflight_sysbox and passes CLAUDE_SYSBOX_ATTESTED_VERSION" \
    || bad "--sysbox is missing the preflight_sysbox / attestation wiring"

# The flat runc HARDEN_ARGS / preflight_runc must NOT apply on the Sysbox path (the inner
# dockerd needs its caps; userns is the boundary). They live in the non-sysbox (else) branch;
# assert preflight_runc sits AFTER the `if [[ "$SYSBOX" == 1 ]]` split (i.e. only in else).
pf_line="$(grep -n '^    preflight_runc' "$LAUNCH" | head -1 | cut -d: -f1)"
sb_line="$(grep -nF 'if [[ "$SYSBOX" == 1 ]]' "$LAUNCH" | head -1 | cut -d: -f1)"
if [[ -n "$pf_line" && -n "$sb_line" ]] && (( pf_line > sb_line )); then
    ok "preflight_runc + flat hardening run ONLY on the non-sysbox path"
else
    bad "preflight_runc must sit inside the non-sysbox branch (irrelevant under sysbox-runc)"
fi
# Egress firewall is fail-open, so --sysbox + CLAUDE_EGRESS_LOCKDOWN re-adds NET_ADMIN
# explicitly rather than relying on Sysbox's implicit cap set.
has "$LAUNCH" 'HARDEN_ARGS=(--cap-add NET_ADMIN)' \
    && ok "--sysbox + egress lockdown re-adds NET_ADMIN explicitly" \
    || bad "--sysbox + egress lockdown does not re-add NET_ADMIN"

# Broker path: controller sizing + the broker env + controller-image auto-select.
has "$LAUNCH" 'claude-controller-size" --flags' \
    && ok "--broker sizes the container via claude-controller-size --flags" \
    || bad "--broker does not size via claude-controller-size"
has "$LAUNCH" 'CLAUDE_WORKER_BROKER=1' \
    && ok "--broker sets CLAUDE_WORKER_BROKER=1" \
    || bad "--broker does not set CLAUDE_WORKER_BROKER=1"
has "$LAUNCH" 'CLAUDE_IMAGE="$CLAUDE_IMAGE_CONTROLLER"' \
    && ok "--broker auto-selects the controller image" \
    || bad "--broker does not auto-select the controller image"

# The docker run must actually consume the assembled arrays.
has "$LAUNCH" '"${SIZING_ARGS[@]}"'     && ok "docker run uses SIZING_ARGS"      || bad "docker run does not use SIZING_ARGS"
has "$LAUNCH" '"${ATTEST_ARGS[@]}"'     && ok "docker run uses ATTEST_ARGS"      || bad "docker run does not use ATTEST_ARGS"
has "$LAUNCH" '"${BROKER_ENV_ARGS[@]}"' && ok "docker run uses BROKER_ENV_ARGS"  || bad "docker run does not use BROKER_ENV_ARGS"

# Regression: the single-session profile is factored into FLAT_PROFILE (one source of truth).
# A PLAIN launch uses it as-is (NO runtime); sysbox-no-broker prepends --runtime=sysbox-runc.
# These are unique fixed strings, so breaking the non-sysbox branch fails the check (unlike the
# old positional awk, which matched the sysbox branch's --cpus and passed regardless).
has "$LAUNCH" 'FLAT_PROFILE=(--cpus "$CLAUDE_CPU_LIMIT"' \
    && ok "the single-session profile is factored into FLAT_PROFILE" \
    || bad "FLAT_PROFILE (shared flat profile) is missing"
has "$LAUNCH" 'SIZING_ARGS=("${FLAT_PROFILE[@]}")' \
    && ok "a plain launch uses FLAT_PROFILE as-is (no sysbox runtime)" \
    || bad "the non-sysbox SIZING_ARGS branch (flat profile, no runtime) is missing"
has "$LAUNCH" 'SIZING_ARGS=(--runtime=sysbox-runc "${FLAT_PROFILE[@]}")' \
    && ok "sysbox (no broker) prepends --runtime=sysbox-runc to the flat profile" \
    || bad "the sysbox-non-broker SIZING_ARGS branch is missing"

# ============================================================================================
echo "== C. image plumbing: Dockerfile WITH_DOCKER + label, Makefile, _common defaults =="
# ============================================================================================
DF="$REPO_ROOT/Dockerfile"; MF="$REPO_ROOT/Makefile"; COMMON="$REPO_ROOT/bin/_common.sh"
hasE "$DF" '^ARG WITH_DOCKER=0'                 && ok "Dockerfile has ARG WITH_DOCKER=0 (default off)" || bad "Dockerfile missing ARG WITH_DOCKER"
has  "$DF" 'docker-ce docker-ce-cli containerd.io' && ok "Dockerfile installs the Docker engine under WITH_DOCKER=1" || bad "Dockerfile does not install docker-ce"
hasE "$DF" 'LABEL claude.controller='           && ok "Dockerfile stamps the claude.controller capability label" || bad "Dockerfile missing claude.controller label"
has  "$MF" 'build-controller:'                  && ok "Makefile has a build-controller target" || bad "Makefile missing build-controller"
has  "$MF" 'WITH_DOCKER=$(WITH_DOCKER)'         && ok "Makefile threads WITH_DOCKER into the build args" || bad "Makefile does not pass WITH_DOCKER"
has  "$COMMON" 'CLAUDE_IMAGE_CONTROLLER="${CLAUDE_IMAGE_CONTROLLER:-claude-code-box:controller}"' \
    && ok "_common.sh defines CLAUDE_IMAGE_CONTROLLER" || bad "_common.sh missing CLAUDE_IMAGE_CONTROLLER default"

# ============================================================================================
echo "== D. durable worker image: entrypoint tarball auto-load + claude-launch --worker-tarball =="
# ============================================================================================
# §5a loads the worker image from a mounted tarball (survives recreate — inner daemon is empty
# each time), idempotently (skip if present) and fail-soft (a load failure warns, never dies).
SEC5A="$(sed -n '/durable worker image (CC-INTERACTIVE-BROKER)/,/worker broker (CC-2)/p' "$ENTRY")"
if grep -qF 'CLAUDE_WORKER_IMAGE_TARBALL' <<<"$SEC5A" && grep -qF 'docker load -i' <<<"$SEC5A"; then
    ok "§5a loads the worker image from CLAUDE_WORKER_IMAGE_TARBALL"
else
    bad "§5a does not load a worker-image tarball"
fi
grep -qF 'docker image inspect "$_wimg"' <<<"$SEC5A" \
    && ok "§5a is idempotent (skips the load when the worker image is already present)" \
    || bad "§5a is not idempotent (would reload every boot)"
# Fail-soft: the load is inside the §5a block, which never calls die (only log/WARNING).
if ! grep -qE '\bdie\b' <<<"$SEC5A"; then
    ok "§5a is fail-soft (a tarball problem warns, never dies — the broker just refuses launches)"
else
    bad "§5a can die on a tarball problem (should be fail-soft)"
fi
# claude-launch --worker-tarball: mounts the tarball + sets the env, only with --broker.
hasE "$LAUNCH" '^\s*--worker-tarball\)' && ok "claude-launch parses --worker-tarball" || bad "claude-launch missing --worker-tarball"
has "$LAUNCH" '/etc/claude/worker-image.tar:ro' && has "$LAUNCH" 'CLAUDE_WORKER_IMAGE_TARBALL=/etc/claude/worker-image.tar' \
    && ok "--worker-tarball mounts the tarball read-only + sets CLAUDE_WORKER_IMAGE_TARBALL" \
    || bad "--worker-tarball does not wire the mount + env"

# ============================================================================================
echo "== E. compose-gen --broker: generates a broker controller service =="
# ============================================================================================
CG="$REPO_ROOT/bin/claude-compose-gen"
bash -n "$CG" && ok "claude-compose-gen parses (bash -n)" || bad "claude-compose-gen has a syntax error"
hasE "$CG" '^\s*--broker\)' && hasE "$CG" '^\s*--worker-tarball\)' \
    && ok "compose-gen parses --broker and --worker-tarball" || bad "compose-gen missing --broker / --worker-tarball"
# Functional: generate one broker + one plain service and assert the broker's shape (and that
# the plain service is unchanged — the regression that matters for a mixed roster).
GENOUT="$TMPD/gen.yml"; TARBALL="$TMPD/w.tar"; : > "$TARBALL"
if bash "$CG" --out "$GENOUT" --broker br --worker-tarball "$TARBALL" cosyte/br cosyte/plain >/dev/null 2>&1; then
    brk="$(sed -n '/^  br:/,/^  plain:/p' "$GENOUT")"
    pln="$(sed -n '/^  plain:/,/^volumes:/p' "$GENOUT")"
    grep -qF 'image: claude-code-box:controller' <<<"$brk" && grep -qF 'runtime: sysbox-runc' <<<"$brk" \
        && ok "broker service uses the controller image + sysbox-runc runtime" || bad "broker service image/runtime wrong"
    grep -qF 'CLAUDE_WORKER_BROKER: "1"' <<<"$brk" && grep -qF 'CLAUDE_SYSBOX_ATTESTED_VERSION' <<<"$brk" \
        && ok "broker service sets CLAUDE_WORKER_BROKER + attestation" || bad "broker service missing broker env"
    grep -qF 'worker-image.tar:ro' <<<"$brk" && grep -qF 'CLAUDE_WORKER_IMAGE_TARBALL' <<<"$brk" \
        && ok "broker service mounts the worker tarball + sets the env" || bad "broker service missing tarball wiring"
    grep -qF 'cap_drop' <<<"$brk" && bad "broker service must NOT cap_drop (Sysbox is the boundary)" \
        || ok "broker service has no cap_drop (Sysbox userns is the boundary)"
    grep -qF 'cap_drop' <<<"$pln" && grep -qF 'image: claude-code-box:latest' <<<"$pln" \
        && ok "a PLAIN service in the same roster is unchanged (lean image + cap_drop)" \
        || bad "regression: a plain service lost its hardening / lean image"
else
    bad "compose-gen --broker failed to generate"
fi

# REGRESSION (fail-soft attestation): on a host with NO sysbox-runc, preflight_sysbox `die`s
# (exit 1). An `exit` inside `$( … )` kills that subshell immediately, so an INNER `|| true`
# never runs and `set -e` would kill the generator — with the reason swallowed by the redirect.
# The `||` must therefore live in the PARENT. Assert the generator SURVIVES a Sysbox-less host
# (generation may legitimately target a different host) and falls back to the CVE floor.
NOSB="$TMPD/nosysbox"; mkdir -p "$NOSB"
for d in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*; do b="$(basename "$f")"
        [[ "$b" == sysbox-runc ]] && continue
        [[ -e "$NOSB/$b" ]] || ln -sf "$f" "$NOSB/$b" 2>/dev/null
    done
done
GEN2="$TMPD/gen-nosysbox.yml"
if ( PATH="$NOSB" bash "$CG" --out "$GEN2" --broker br cosyte/br >/dev/null 2>&1 ) && [[ -f "$GEN2" ]]; then
    ok "compose-gen --broker SURVIVES a Sysbox-less host (fail-soft attestation, not a silent die)"
    grep -qF "CLAUDE_SYSBOX_ATTESTED_VERSION: \"$(bash -c 'source '"$REPO_ROOT"'/bin/_common.sh; printf "%s" "$SYSBOX_CVE_FLOOR"')\"" "$GEN2" \
        && ok "Sysbox-less generation attests the immovable CVE floor (broker re-validates at run)" \
        || bad "Sysbox-less generation did not fall back to the CVE floor"
else
    bad "compose-gen --broker DIED on a Sysbox-less host (the exit-inside-\$() fail-open bug)"
fi

echo
echo "broker-interactive-unit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
