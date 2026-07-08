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

# A malformed FLOOR must fail CLOSED — garbage on either side of the compare refuses.
if in_env SYSBOX_MIN_VERSION=banana CLAUDE_SYSBOX_FAKE_VERSION=0.7.0 CLAUDE_SYSBOX_SKIP_DOCKER=1 -- preflight_sysbox; then
    bad "a malformed SYSBOX_MIN_VERSION must REFUSE (fail closed), not collapse to 0.0.0"
else
    ok  "a malformed SYSBOX_MIN_VERSION refuses (fail closed)"
fi

# The floor may be RAISED, never LOWERED: a well-formed-but-low SYSBOX_MIN_VERSION
# (the .env/ambient neutralize-the-gate vector) dies against the immovable CVE floor —
# even when the installed version would satisfy the lowered bar.
if in_env SYSBOX_MIN_VERSION=0.0.0 CLAUDE_SYSBOX_FAKE_VERSION=0.6.7 CLAUDE_SYSBOX_SKIP_DOCKER=1 -- preflight_sysbox; then
    bad "SYSBOX_MIN_VERSION=0.0.0 must be REFUSED — the CVE floor is immovable"
else
    ok  "SYSBOX_MIN_VERSION=0.0.0 is refused (CVE floor is immovable)"
fi

if in_env SYSBOX_MIN_VERSION=0.6.0 CLAUDE_SYSBOX_FAKE_VERSION=1.0.0 CLAUDE_SYSBOX_SKIP_DOCKER=1 -- preflight_sysbox; then
    bad "SYSBOX_MIN_VERSION=0.6.0 must be REFUSED even with a new Sysbox installed — a lowered floor is a config error, not a pass"
else
    ok  "SYSBOX_MIN_VERSION=0.6.0 is refused even though the installed version is new (lowered floor = config error)"
fi

echo
echo "== preflight_sysbox: REAL-binary path (PATH-stubbed sysbox-runc) =="

# The refusals must be reachable from the real parse, not just the fake-version seam:
# the parser keeps pre-release/build suffixes so the floor logic can see them.
STUBBIN="$(mktemp -d)"
trap 'rm -rf "$STUBBIN"' EXIT
mkstub() { printf '#!/bin/sh\nprintf "sysbox-runc\\n\\tedition: \\tCommunity Edition (CE)\\n\\tversion: \\t%s\\n"\n' "$1" > "$STUBBIN/sysbox-runc"; chmod +x "$STUBBIN/sysbox-runc"; }

mkstub "0.7.0-rc.1"
if in_env PATH="$STUBBIN:/usr/bin:/bin" CLAUDE_SYSBOX_SKIP_DOCKER=1 -- preflight_sysbox; then
    bad "REAL binary reporting 0.7.0-rc.1 must be REFUSED (pre-release of the floor)"
else
    ok  "REAL binary reporting 0.7.0-rc.1 is refused — the suffix survives the parse"
fi

mkstub "0.7.0"
if in_env PATH="$STUBBIN:/usr/bin:/bin" CLAUDE_SYSBOX_SKIP_DOCKER=1 -- preflight_sysbox; then
    ok  "REAL binary reporting 0.7.0 is accepted"
else
    bad "REAL binary reporting 0.7.0 must be accepted"
fi

mkstub "0.7.0+build.7"
if in_env PATH="$STUBBIN:/usr/bin:/bin" CLAUDE_SYSBOX_SKIP_DOCKER=1 -- preflight_sysbox; then
    ok  "REAL binary reporting 0.7.0+build.7 is accepted (build metadata stripped, not a pre-release)"
else
    bad "0.7.0+build.7 must be accepted — build metadata carries no release semantics"
fi

mkstub "0.6.7"
if in_env PATH="$STUBBIN:/usr/bin:/bin" CLAUDE_SYSBOX_SKIP_DOCKER=1 -- preflight_sysbox; then
    bad "REAL binary reporting 0.6.7 must be REFUSED"
else
    ok  "REAL binary reporting 0.6.7 is refused"
fi

# A binary emitting no version token must die WITH the parse diagnostic (reachable
# under errexit), never silently.
printf '#!/bin/sh\necho "sysbox-runc (no version here)"\n' > "$STUBBIN/sysbox-runc"; chmod +x "$STUBBIN/sysbox-runc"
outp="$( ( export PATH="$STUBBIN:/usr/bin:/bin" CLAUDE_SYSBOX_SKIP_DOCKER=1
           # shellcheck disable=SC1091
           source "$REPO_ROOT/bin/_common.sh"; preflight_sysbox ) 2>&1 )" && rc=0 || rc=$?
if [[ $rc -ne 0 && "$outp" == *"could not parse a version"* ]]; then
    ok  "version-less output dies WITH the parse diagnostic (not a silent errexit death)"
else
    bad "version-less output must die with the parse diagnostic (rc=$rc, out=$outp)"
fi

echo
echo "== version_ge helper =="
( # shellcheck disable=SC1091
  source "$REPO_ROOT/bin/_common.sh"
  version_ge 0.7.0 0.7.0        || exit 1
  version_ge 0.7.1 0.7.0        || exit 1
  version_ge 1.0.0 0.7.0        || exit 1
  version_ge 0.10.0 0.9.9       || exit 1   # numeric, not lexical
  version_ge 0.08.0 0.7.0       || exit 1   # leading zero must not trip octal
  ! version_ge 0.6.7 0.7.0      || exit 1
  ! version_ge 0.7 0.7.1        || exit 1   # missing part defaults to 0
  rc=0; version_ge banana 0.7.0 || rc=$?
  [[ $rc -eq 2 ]] || exit 1                 # garbage → ERROR, not a verdict
) >/dev/null 2>&1 && ok "version_ge truth table holds (incl. leading-zero + garbage→error)" \
                  || bad "version_ge truth table failed"

echo
echo "== preflight_runc: warn-only posture preserved (K=1 non-regression) =="

# preflight_runc must never exit non-zero — it warns. Feed it a vulnerable runc via a stub.
STUB="$(mktemp -d)"
trap 'rm -rf "$STUB" "$STUBBIN"' EXIT
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
