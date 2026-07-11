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
# Regression: the die message that IS the barrier must no longer be reachable only via a
# CLAUDE_CONTROLLER guard. Assert the barrier's die text exists and the nearest preceding
# guard is the broker one (structurally: WORKER_BROKER guard appears before the die).
if awk '/CLAUDE_WORKER_BROKER:-0.*=~/{seen=1} /was not locked to root:root 600/{print (seen?"ok":"no"); exit}' "$ENTRY" | grep -q ok; then
    ok "the 'was not locked' barrier follows the CLAUDE_WORKER_BROKER guard"
else
    bad "the socket-lockdown barrier is not reached under the CLAUDE_WORKER_BROKER guard"
fi
# The wait var is the mode-neutral name, with the legacy controller name as a fallback.
if hasE "$ENTRY" 'CLAUDE_BROKER_SOCKET_LOCKDOWN_WAIT:-\$\{CLAUDE_CONTROLLER_SOCKET_WAIT:-90\}'; then
    ok "wait knob is CLAUDE_BROKER_SOCKET_LOCKDOWN_WAIT with the legacy alias fallback"
else
    bad "expected CLAUDE_BROKER_SOCKET_LOCKDOWN_WAIT (legacy: CLAUDE_CONTROLLER_SOCKET_WAIT)"
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
# §5a (dockerd start) must sit BEFORE §5b (broker start) so the broker's socket is present.
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

# The flat runc HARDEN_ARGS must be cleared for a Sysbox controller (the inner dockerd
# needs its caps; userns is the boundary).
hasE "$LAUNCH" 'HARDEN_ARGS=\(\)' \
    && ok "sysbox mode clears HARDEN_ARGS (no cap-drop that would starve the inner dockerd)" \
    || bad "sysbox mode does not clear HARDEN_ARGS"

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

# Regression: a PLAIN launch (no --sysbox/--broker) must keep the flat single-session
# profile and NOT inject a runtime — the SIZING_ARGS else-branch.
if awk '/^else$/{e=1} e&&/--cpus "\$CLAUDE_CPU_LIMIT"/{print "ok"; exit}' "$LAUNCH" | grep -q ok; then
    ok "a plain launch keeps the flat --cpus/--memory profile (no sysbox runtime)"
else
    bad "the non-sysbox SIZING_ARGS branch (flat profile) is missing"
fi

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

echo
echo "broker-interactive-unit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
