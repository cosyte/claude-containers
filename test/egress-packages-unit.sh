#!/usr/bin/env bash
# egress-packages-unit.sh: pure-logic tests for the opt-in package-registry egress profile in
# bin/claude-egress-firewall. NO docker, NO NET_ADMIN, NO live iptables: safe for CI / scripts/verify.sh.
#
# The firewall's host-SELECTION (the part this profile changes) is exercised via its CLAUDE_EGRESS_PRINT_HOSTS=1
# dry-run seam, which prints the composed allowlist host set and exits BEFORE touching iptables. The
# live default-deny enforcement (that a non-allowlisted IP actually DROPs) needs NET_ADMIN and lives in
# the on-host smoke/substrate proofs; here we prove the allowlist COMPOSITION is opt-in, additive, and
# leaks nothing when off.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FW="$REPO_ROOT/bin/claude-egress-firewall"
PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

# hosts <extra-env...>: the composed allowlist host set for the given env (dry-run, sorted, one per line)
hosts() { env "$@" CLAUDE_EGRESS_PRINT_HOSTS=1 bash "$FW" 2>/dev/null; }

PKG_HOSTS="pypi.org files.pythonhosted.org crates.io index.crates.io static.crates.io proxy.golang.org sum.golang.org mise.run ghcr.io"

echo "package-registry egress profile"

# ---- profile OFF (default) is byte-identical to the baked default set --------------------------------
OFF="$(hosts)"
DEFAULT_OFF="$(hosts CLAUDE_EGRESS_PACKAGES=0)"
[[ "$OFF" == "$DEFAULT_OFF" ]] && ok "profile unset == explicitly-off (byte-identical)" || bad "unset vs =0 differ"

leaked=0
for h in $PKG_HOSTS; do grep -qxF "$h" <<<"$OFF" && leaked=1; done
[[ "$leaked" -eq 0 ]] && ok "profile OFF: NO package-registry host appears (nothing broadens egress implicitly)" \
                       || bad "profile OFF leaked a package host"

# the default set still carries the always-on hosts (regression guard on the base allowlist)
for h in api.anthropic.com github.com registry.npmjs.org; do
  grep -qxF "$h" <<<"$OFF" || bad "profile OFF dropped a baked default host: $h"
done
ok "profile OFF: the baked default hosts (Claude API / GitHub / npm) are still present"

# ---- profile ON is ADDITIVE: every package host appears AND every default host remains ---------------
for v in 1 true yes on; do
  ON="$(hosts CLAUDE_EGRESS_PACKAGES=$v)"
  miss=0
  for h in $PKG_HOSTS; do grep -qxF "$h" <<<"$ON" || miss=1; done
  [[ "$miss" -eq 0 ]] && ok "CLAUDE_EGRESS_PACKAGES=$v: all 9 package hosts present" || bad "CLAUDE_EGRESS_PACKAGES=$v missing a package host"
done
ON="$(hosts CLAUDE_EGRESS_PACKAGES=1)"
for h in api.anthropic.com github.com registry.npmjs.org; do
  grep -qxF "$h" <<<"$ON" || bad "profile ON dropped a baked default host: $h"
done
ok "profile ON: additive, the baked default hosts are all still present"

# Debian/apt mirrors are deliberately NOT in this profile (they need the retired worker apt tier)
grep -qiE 'debian|ubuntu|deb\.' <<<"$ON" && bad "profile ON wrongly included a Debian/apt mirror (retired-apt-tier scope)" \
                                          || ok "profile ON: no Debian/apt mirror (correctly deferred to the retired apt tier)"

# ---- a non-allowlisted host never appears, on or off ------------------------------------------------
for set in "$OFF" "$ON"; do
  grep -qxF "evil.example.com" <<<"$set" && bad "a non-allowlisted host appeared in the allowlist"
done
ok "a non-allowlisted host (evil.example.com) is never in the composed allowlist"

# ---- the profile composes WITH CLAUDE_EGRESS_EXTRA_HOSTS (both additive, independent) ---------------
BOTH="$(hosts CLAUDE_EGRESS_PACKAGES=1 CLAUDE_EGRESS_EXTRA_HOSTS=my.internal.host,other.host)"
grep -qxF "my.internal.host" <<<"$BOTH" && grep -qxF "other.host" <<<"$BOTH" && grep -qxF "pypi.org" <<<"$BOTH" \
  && ok "package profile + CLAUDE_EGRESS_EXTRA_HOSTS coexist (both additive)" \
  || bad "package profile and EXTRA_HOSTS did not compose"
# EXTRA alone must NOT pull in the package hosts (they are strictly gated on the package flag)
EXTRA_ONLY="$(hosts CLAUDE_EGRESS_EXTRA_HOSTS=my.internal.host)"
grep -qxF "pypi.org" <<<"$EXTRA_ONLY" && bad "EXTRA_HOSTS alone leaked the package profile" \
                                       || ok "EXTRA_HOSTS alone does not enable the package profile"

# ---- the dry-run seam accepts the same truthy spellings as the package flag (gate parity) ----------
TRUE_RUN="$(env CLAUDE_EGRESS_PRINT_HOSTS=true bash "$FW" 2>/dev/null)"
grep -qxF "api.anthropic.com" <<<"$TRUE_RUN" \
  && ok "CLAUDE_EGRESS_PRINT_HOSTS=true dry-runs (same 1|true|yes|on gate as the package flag)" \
  || bad "PRINT_HOSTS=true did not dry-run (gate spelling inconsistent → would hit live iptables)"

# ---- the dry-run seam emits a PURE host list on stdout (diagnostics go to stderr) ------------------
DIRTY="$(hosts CLAUDE_EGRESS_PACKAGES=1 | grep -c '\[egress\]' || true)"
[[ "$DIRTY" -eq 0 ]] && ok "CLAUDE_EGRESS_PRINT_HOSTS stdout is a clean host list (no [egress] log lines)" \
                     || bad "the dry-run host list is polluted by [egress] diagnostics on stdout"

echo
echo "egress-packages-unit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
