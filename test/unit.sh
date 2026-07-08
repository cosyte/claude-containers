#!/usr/bin/env bash
# Unit tests that need NO docker and NO sysbox — safe for CI and for `scripts/verify.sh`.
#
# Covers the pure-logic safety checks in bin/_common.sh:
#   - preflight_sysbox: the version-floor REFUSAL (CC-1) — pre-patch refused, floor+ accepted,
#     garbage refused, absent binary refused
#   - preflight_runc:   the warn-only posture is preserved (never exits non-zero)
#
# The full on-host substrate proof (controller + nested child + containment) lives in
# bin/claude-sysbox-verify and requires Sysbox installed; it is deliberately NOT run here.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

# Run a snippet in a subshell that sources _common.sh, with docker checks stubbed out.
# Prints nothing; the caller asserts on the exit code.
in_env() {  # in_env <extra-env...> -- <bash-snippet>
    local envs=()
    while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done
    shift
    ( export "${envs[@]}" 2>/dev/null
      # shellcheck disable=SC1091
      source "$REPO_ROOT/bin/_common.sh"
      eval "$1"
    ) >/dev/null 2>&1
}

echo "== preflight_sysbox: version-floor refusal =="

if in_env CLAUDE_SYSBOX_FAKE_VERSION=0.6.7 CLAUDE_SYSBOX_SKIP_DOCKER=1 -- preflight_sysbox; then
    bad "0.6.7 (pre-patch) must be REFUSED"
else
    ok  "0.6.7 (pre-patch) is refused"
fi

if in_env CLAUDE_SYSBOX_FAKE_VERSION=0.7.0 CLAUDE_SYSBOX_SKIP_DOCKER=1 -- preflight_sysbox; then
    ok  "0.7.0 (the floor — first release porting the Nov-2025 CVE patches) is accepted"
else
    bad "0.7.0 (the floor) must be accepted"
fi

if in_env CLAUDE_SYSBOX_FAKE_VERSION=0.7.1 CLAUDE_SYSBOX_SKIP_DOCKER=1 -- preflight_sysbox; then
    ok  "0.7.1 (above the floor, patch bump) is accepted"
else
    bad "0.7.1 must be accepted"
fi

if in_env CLAUDE_SYSBOX_FAKE_VERSION=1.0.0 CLAUDE_SYSBOX_SKIP_DOCKER=1 -- preflight_sysbox; then
    ok  "1.0.0 (above the floor, major bump) is accepted"
else
    bad "1.0.0 must be accepted"
fi

if in_env CLAUDE_SYSBOX_FAKE_VERSION=v0.7.0 CLAUDE_SYSBOX_SKIP_DOCKER=1 -- preflight_sysbox; then
    ok  "a 'v'-prefixed version parses and is accepted"
else
    bad "v0.7.0 must parse and be accepted"
fi

if in_env CLAUDE_SYSBOX_FAKE_VERSION=0.7.0-rc.1 CLAUDE_SYSBOX_SKIP_DOCKER=1 -- preflight_sysbox; then
    bad "0.7.0-rc.1 (a pre-release of the floor) must be REFUSED — can't prove it has the patches"
else
    ok  "0.7.0-rc.1 (a pre-release of the floor) is refused (fail closed)"
fi

if in_env CLAUDE_SYSBOX_FAKE_VERSION=0.7.1-rc.1 CLAUDE_SYSBOX_SKIP_DOCKER=1 -- preflight_sysbox; then
    ok  "0.7.1-rc.1 (pre-release ABOVE the floor) is accepted"
else
    bad "0.7.1-rc.1 is above the floor and must be accepted"
fi

if in_env CLAUDE_SYSBOX_FAKE_VERSION=banana CLAUDE_SYSBOX_SKIP_DOCKER=1 -- preflight_sysbox; then
    bad "an unparseable version must be REFUSED (fail closed)"
else
    ok  "an unparseable version is refused (fail closed)"
fi

# A raised floor binds: 0.7.0 refused when the operator demands 0.8.0.
if in_env SYSBOX_MIN_VERSION=0.8.0 CLAUDE_SYSBOX_FAKE_VERSION=0.7.0 CLAUDE_SYSBOX_SKIP_DOCKER=1 -- preflight_sysbox; then
    bad "0.7.0 must be refused when SYSBOX_MIN_VERSION=0.8.0"
else
    ok  "a raised SYSBOX_MIN_VERSION floor binds"
fi

# No fake version + no sysbox-runc on PATH → refusal (never a silent pass).
if in_env PATH=/nonexistent-cc1 CLAUDE_SYSBOX_SKIP_DOCKER=1 -- preflight_sysbox; then
    bad "absent sysbox-runc must be REFUSED"
else
    ok  "absent sysbox-runc is refused"
fi

echo
echo "== preflight_runc: warn-only posture preserved (K=1 non-regression) =="

# preflight_runc must never exit non-zero — it warns. Feed it a vulnerable runc via a stub.
STUB="$(mktemp -d)"
trap 'rm -rf "$STUB"' EXIT
printf '#!/bin/sh\necho "runc version 1.2.7"\n' > "$STUB/runc" && chmod +x "$STUB/runc"
if in_env PATH="$STUB:/usr/bin:/bin" -- preflight_runc; then
    ok  "a vulnerable runc (1.2.7) only WARNS — flat launch path behavior unchanged"
else
    bad "preflight_runc must never exit non-zero (it is warn-only by design)"
fi
printf '#!/bin/sh\necho "runc version 1.3.3"\n' > "$STUB/runc"
if in_env PATH="$STUB:/usr/bin:/bin" -- preflight_runc; then
    ok  "a patched runc (1.3.3) passes quietly"
else
    bad "a patched runc must pass"
fi

echo
echo "== $PASS passed, $FAIL failed =="
exit $(( FAIL > 0 ? 1 : 0 ))
