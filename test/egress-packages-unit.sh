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
echo "two address families, independently (enforcement path, no NET_ADMIN, no real firewall)"

# Everything above drives the CLAUDE_EGRESS_PRINT_HOSTS seam, which exits BEFORE any
# firewall binary is required. The IPv6 work lives on the enforcement side of that seam,
# so it needs a second one: a sandbox PATH holding ONLY the tools the script shells out
# to, with getent / curl / iptables* / ip6tables* replaced by stubs that record what they
# were handed. The shipped script then runs for real (same `command -v` checks, same
# resolution loop, same restore pipeline, same post-commit policy verification) against a
# fake kernel, on a host with no NET_ADMIN and no iptables.
#
# The sandbox PATH is what makes the absent-tooling case honest: "no ip6tables in this
# image" is expressed by NOT CREATING the binary, so `command -v` really fails, rather
# than by a flag the script could be taught to special-case.
SBROOT="$(mktemp -d)"
trap 'rm -rf "$SBROOT"' EXIT

# The genuine tools bin/claude-egress-firewall calls out to, symlinked in so the script
# runs against real coreutils while `command -v` sees exactly the world we built.
SB_REAL_TOOLS="bash timeout mktemp awk sort cat rm cp wc head grep jq"

sb_new() {  # sb_new <name> [--no-ip6] : build a sandbox, print its path
    local sb="$SBROOT/$1" ip6=1; shift
    [[ "${1:-}" == "--no-ip6" ]] && ip6=0
    rm -rf "$sb"; mkdir -p "$sb/bin" "$sb/tmp"
    local t p
    for t in $SB_REAL_TOOLS; do p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$sb/bin/$t"; done

    # Fake resolver. Logs every query (so a test can prove WHICH hosts each family was
    # asked about) and answers a per-host address taken from the host's position in
    # STUB_HOSTLIST, so every host gets a distinct net and the rules can be counted.
    # STUB_NO_V4 / STUB_NO_V6 list the hosts that answer with nothing, which is what a
    # timeout, an NXDOMAIN or an address-family-less name looks like from here.
    cat > "$sb/bin/getent" <<'EOS'
#!/usr/bin/env bash
db="$1"; host="${2:-}"
printf '%s %s\n' "$db" "$host" >> "$STUB_QUERYLOG"
idx="$(grep -nxF -- "$host" "$STUB_HOSTLIST" 2>/dev/null | head -1)"; idx="${idx%%:*}"
[[ -z "$idx" ]] && exit 2
case "$db" in
  ahostsv4) case " ${STUB_NO_V4:-} " in *" $host "*) exit 2 ;; esac
            printf '198.51.100.%s STREAM %s\n198.51.100.%s DGRAM\n' "$idx" "$host" "$idx" ;;
  ahostsv6) case " ${STUB_NO_V6:-} " in *" $host "*) exit 2 ;; esac
            printf '2001:db8::%s STREAM %s\n2001:db8::%s DGRAM\n' "$idx" "$host" "$idx" ;;
  *) exit 2 ;;
esac
EOS
    # api.github.com/meta: fails by default (deterministic, and the script's documented
    # per-host-DNS fallback), or serves STUB_CURL_META when a test wants the published
    # ranges in play.
    cat > "$sb/bin/curl" <<'EOS'
#!/usr/bin/env bash
[[ -n "${STUB_CURL_META:-}" && -s "${STUB_CURL_META:-}" ]] || exit 1
cat "$STUB_CURL_META"
EOS
    # Fake netfilter, one pair per family. `-S OUTPUT` reports the policy the last
    # successful restore committed, which is exactly what the script verifies after it
    # commits, and `-P` records a policy change (that is how fail_open and v6_fail put a
    # family back to ACCEPT).
    local fam
    for fam in 4 6; do
        local bin=iptables var=V4
        [[ "$fam" == 6 ]] && { bin=ip6tables; var=V6; }
        [[ "$fam" == 6 && "$ip6" == 0 ]] && continue
        cat > "$sb/bin/$bin" <<EOS
#!/usr/bin/env bash
case "\${1:-}" in
  -S) cat "\$STUB_${var}_POLICY" 2>/dev/null || echo "-P OUTPUT ACCEPT" ;;
  -P) printf -- '-P %s %s\n' "\$2" "\$3" > "\$STUB_${var}_POLICY" ;;
esac
EOS
        cat > "$sb/bin/$bin-restore" <<EOS
#!/usr/bin/env bash
cat > "\$STUB_${var}_RULES.attempt"
case "\${STUB_${var}_FAIL:-0}" in
  1)   exit 1 ;;
  log) grep -q -- '-j LOG' "\$STUB_${var}_RULES.attempt" && exit 1 ;;
esac
cp "\$STUB_${var}_RULES.attempt" "\$STUB_${var}_RULES"
printf -- '-P OUTPUT DROP\n' > "\$STUB_${var}_POLICY"
exit 0
EOS
        chmod +x "$sb/bin/$bin" "$sb/bin/$bin-restore"
    done
    chmod +x "$sb/bin/getent" "$sb/bin/curl"
    hosts > "$sb/hostlist"
    echo "$sb"
}

# run_fw <sandbox> [VAR=VAL ...]: run the SHIPPED script against the sandbox with a
# scrubbed environment, merging its [egress] diagnostics into the output and appending
# fw_rc=<status>. The status is the per-family posture contract the entrypoint reads.
run_fw() {
    local sb="$1"; shift
    local rc=0 out
    out="$(env -i PATH="$sb/bin" HOME="$sb" TMPDIR="$sb/tmp" \
        STUB_QUERYLOG="$sb/queries" STUB_HOSTLIST="$sb/hostlist" \
        STUB_V4_RULES="$sb/v4.rules" STUB_V6_RULES="$sb/v6.rules" \
        STUB_V4_POLICY="$sb/v4.policy" STUB_V6_POLICY="$sb/v6.policy" \
        "$@" bash "$FW" 2>&1)" || rc=$?
    printf '%s\nfw_rc=%s\n' "$out" "$rc"
}
sb_pol()   { cat "$1/$2.policy" 2>/dev/null || echo "-P OUTPUT ACCEPT"; }
sb_nets()  { grep -c -- '-A OUTPUT -p tcp -d ' "$1/$2.rules" 2>/dev/null || true; }
sb_asked() { awk -v d="$1" '$1==d{print $2}' "$2/queries" 2>/dev/null | sort -u; }

# ---- the sandbox itself is honest, or nothing below means anything -----------------------
SB="$(sb_new probe)"
if [[ -x "$SB/bin/ip6tables" && -x "$SB/bin/iptables" ]] \
   && ! env -i PATH="$SB/bin" bash -c 'command -v ping' >/dev/null 2>&1; then
    ok "sandbox PATH is closed: only the stubbed/symlinked tools are visible to command -v"
else
    bad "the sandbox PATH leaks the host's binaries, so 'tooling absent' could never be tested"
fi

# ---- BOTH families are resolved, for exactly the hosts the dry run reports ----------------
OUT="$(run_fw "$SB")"
DRY="$(hosts | sort -u)"
if [[ "$(sb_asked ahostsv6 "$SB")" == "$DRY" && "$(sb_asked ahostsv4 "$SB")" == "$DRY" ]]; then
    ok "the IPv6 pass resolves EXACTLY the host set the IPv4 pass does, and the dry run reports it"
else
    bad "the two families were asked about different host sets (or not the dry-run set)"
fi
grep -qxF 'fw_rc=0' <<<"$OUT" && ok "both families default-deny => exit 0 (the entrypoint's 'IPv4 and IPv6 contained' status)" \
                              || bad "a fully successful run did not exit 0: $(grep '^fw_rc=' <<<"$OUT")"
[[ "$(sb_pol "$SB" v4)" == "-P OUTPUT DROP" && "$(sb_pol "$SB" v6)" == "-P OUTPUT DROP" ]] \
    && ok "both OUTPUT policies actually flipped to DROP (verified after the commit, per family)" \
    || bad "a family's OUTPUT policy did not flip to DROP"

# ---- the IPv6 table MIRRORS the IPv4 one (same shape, same allowlist, same ports) ---------
V6R="$(cat "$SB/v6.rules" 2>/dev/null || true)"
mirror=0
grep -q '^:OUTPUT DROP'                                         <<<"$V6R" || mirror=1
grep -q -- '-A OUTPUT -o lo -j ACCEPT'                          <<<"$V6R" || mirror=1
grep -q -- '--ctstate ESTABLISHED,RELATED -j ACCEPT'            <<<"$V6R" || mirror=1
grep -q -- '-p udp --dport 53 -j ACCEPT'                        <<<"$V6R" || mirror=1
grep -q -- '-p tcp --dport 53 -j ACCEPT'                        <<<"$V6R" || mirror=1
grep -q -- '-d 2001:db8::1 -m multiport --dports 22,80,443'     <<<"$V6R" || mirror=1
grep -q '^COMMIT'                                               <<<"$V6R" || mirror=1
[[ "$mirror" -eq 0 ]] && ok "the IPv6 ruleset mirrors the IPv4 rules (policy, loopback, established, DNS, allowlist on 22/80/443)" \
                      || bad "the IPv6 ruleset is not a mirror of the IPv4 rules"
[[ "$(sb_nets "$SB" v6)" == "$(sb_nets "$SB" v4)" ]] \
    && ok "one allowlist rule per resolvable host on each family ($(sb_nets "$SB" v6) nets, both tables)" \
    || bad "the two tables pinned different numbers of nets ($(sb_nets "$SB" v4) v4 vs $(sb_nets "$SB" v6) v6)"

# IPv6 needs ICMPv6 or it cannot even find its default router (Neighbor Discovery is
# ICMPv6, unlike ARP which never reaches the filter table). Echo must NOT be allowed:
# it is an attacker-chosen payload to an arbitrary address, i.e. the exfiltration this
# ruleset exists to stop.
icmp6=0
for t in 1 2 3 4 133 134 135 136; do
    grep -q -- "--icmpv6-type $t -j ACCEPT" <<<"$V6R" || icmp6=1
done
[[ "$icmp6" -eq 0 ]] && ok "the IPv6 table permits the ICMPv6 types IPv6 cannot work without (NDP + PMTU/errors)" \
                     || bad "the IPv6 table drops NDP/PMTU ICMPv6: every allowlisted host would be unreachable"
grep -qE -- '--icmpv6-type (128|129) -j ACCEPT' <<<"$V6R" \
    && bad "the IPv6 table permits ICMPv6 echo: ping is an exfiltration channel to any address" \
    || ok "ICMPv6 echo (128/129) is NOT permitted: no ping-shaped hole to a non-allowlisted address"

# ---- a host with NO IPv6 address is NAMED and SKIPPED, never a reason to abort or open ----
SB="$(sb_new nov6)"
OUT="$(run_fw "$SB" STUB_NO_V6="api.anthropic.com github.com")"
grep -q 'could not resolve api.anthropic.com to an IPv6 address' <<<"$OUT" \
    && grep -q 'could not resolve github.com to an IPv6 address'  <<<"$OUT" \
    && ok "a host with no AAAA is NAMED in the log, one line per host" \
    || bad "a host with no IPv6 address was not named in the log"
if [[ "$(sb_nets "$SB" v6)" -eq $(( $(sb_nets "$SB" v4) - 2 )) ]] && [[ "$(sb_nets "$SB" v6)" -gt 0 ]]; then
    ok "the remaining hosts are still pinned on IPv6 (the two unresolvable ones, and only those, are dropped)"
else
    bad "an unresolvable host aborted the IPv6 allowlist instead of being skipped"
fi
grep -qxF 'fw_rc=0' <<<"$OUT" && [[ "$(sb_pol "$SB" v6)" == "-P OUTPUT DROP" ]] \
    && ok "an unresolvable host does NOT fall back to open IPv6 egress (still default-deny, still exit 0)" \
    || bad "an unresolvable host left IPv6 open or failed the run"

# Every host unresolvable on IPv6 is the same rule taken to its limit: a sealed IPv6
# table, never an open one. It cannot brick the container, because the IPv4 allowlist
# committed above carries the same hosts.
SB="$(sb_new allnov6)"
OUT="$(run_fw "$SB" STUB_NO_V6="$(hosts | tr '\n' ' ')")"
grep -q 'resolved to ZERO IPv6 nets' <<<"$OUT" \
    && [[ "$(sb_pol "$SB" v6)" == "-P OUTPUT DROP" ]] && [[ "$(sb_nets "$SB" v6)" -eq 0 ]] \
    && grep -qxF 'fw_rc=0' <<<"$OUT" \
    && ok "zero resolvable IPv6 addresses yields a SEALED IPv6 table, loudly, never an open one" \
    || bad "zero resolvable IPv6 addresses did not produce a sealed, loudly-logged IPv6 table"

# ---- ABSENT IPv6 TOOLING IS A FAILURE, NOT A SKIP ----------------------------------------
SB="$(sb_new noip6 --no-ip6)"
OUT="$(run_fw "$SB")"
grep -q 'ip6tables not installed' <<<"$OUT" \
    && grep -q 'egress posture: IPv4 default-deny, IPv6 UNRESTRICTED' <<<"$OUT" \
    && ok "no ip6tables in the image => IPv6 is reported UNRESTRICTED (a failure to apply, not a skip)" \
    || bad "absent ip6tables was treated as a skip or was not reported as unrestricted"
grep -qxF 'fw_rc=2' <<<"$OUT" \
    && ok "no ip6tables => exit 2 (IPv4 success + IPv6 open), never exit 0 and never exit 1" \
    || bad "absent ip6tables did not produce the IPv4-success/IPv6-open status: $(grep '^fw_rc=' <<<"$OUT")"
grep -q 'IPv6 default-deny egress active' <<<"$OUT" \
    && bad "absent ip6tables still claimed IPv6 containment somewhere in the log" \
    || ok "absent ip6tables makes NO claim of IPv6 containment anywhere in the log"
[[ "$(sb_pol "$SB" v4)" == "-P OUTPUT DROP" ]] && [[ "$(sb_nets "$SB" v4)" -gt 0 ]] \
    && grep -q 'IPv4 default-deny egress active' <<<"$OUT" \
    && ok "absent ip6tables leaves the IPv4 lockdown fully committed and reported as success" \
    || bad "absent ip6tables damaged or suppressed the IPv4 lockdown"
grep -q 'failing OPEN' <<<"$OUT" \
    && bad "absent ip6tables called fail_open: an IPv6 problem tore down the IPv4 lockdown" \
    || ok "absent ip6tables never calls fail_open (the IPv4 family is untouched by an IPv6 failure)"

# ---- a FAILING IPv6 restore beside a SUCCEEDING IPv4 restore ------------------------------
SB="$(sb_new v6fail)"
OUT="$(run_fw "$SB" STUB_V6_FAIL=1)"
grep -q 'ip6tables-restore failed to apply the IPv6 ruleset' <<<"$OUT" \
    && grep -qxF 'fw_rc=2' <<<"$OUT" \
    && ok "a failed IPv6 restore is reported as an IPv6 failure and STILL reports IPv4 success (exit 2)" \
    || bad "a failed IPv6 restore did not report IPv4 success: $(grep '^fw_rc=' <<<"$OUT")"
[[ "$(sb_pol "$SB" v4)" == "-P OUTPUT DROP" ]] && [[ -s "$SB/v4.rules" ]] \
    && ok "a failed IPv6 restore still leaves the IPv4 default-deny ruleset committed and in force" \
    || bad "a failed IPv6 restore lost the IPv4 ruleset"
[[ "$(sb_pol "$SB" v6)" == "-P OUTPUT ACCEPT" ]] \
    && ok "a failed IPv6 restore puts the IPv6 policy back to ACCEPT, so the log's UNRESTRICTED is true"  \
    || bad "the IPv6 policy after a failed restore does not match what the log reports"
grep -q 'failing OPEN' <<<"$OUT" \
    && bad "a failed IPv6 restore called fail_open and tore down the IPv4 lockdown" \
    || ok "a failed IPv6 restore never reaches fail_open: the two families are independent"

# The drop-LOG retry the IPv4 pass has, mirrored: a kernel without the LOG target must
# still get the ruleset, just without the logging rule.
SB="$(sb_new v6nolog)"
OUT="$(run_fw "$SB" STUB_V6_FAIL=log)"
grep -q 'IPv6 applied without drop-logging' <<<"$OUT" \
    && grep -qxF 'fw_rc=0' <<<"$OUT" && ! grep -q -- '-j LOG' "$SB/v6.rules" \
    && [[ "$(sb_pol "$SB" v6)" == "-P OUTPUT DROP" ]] \
    && ok "no LOG target on IPv6 => the ruleset is retried without it and still commits default-deny" \
    || bad "the IPv6 pass has no retry-without-drop-logging fallback"

# ---- an IPv6 SUCCESS must never mask an IPv4 FAILURE --------------------------------------
SB="$(sb_new v4fail)"
OUT="$(run_fw "$SB" STUB_V4_FAIL=1)"
grep -q 'failing OPEN' <<<"$OUT" && grep -qxF 'fw_rc=1' <<<"$OUT" \
    && grep -q 'egress posture: IPv4 UNRESTRICTED, IPv6 UNRESTRICTED' <<<"$OUT" \
    && ok "an IPv4 failure still exits 1 and reports BOTH families open (IPv6 cannot mask it)" \
    || bad "an IPv4 failure was softened: $(grep '^fw_rc=' <<<"$OUT")"
[[ ! -e "$SB/v6.rules" ]] \
    && ok "an IPv4 failure stops before any IPv6 ruleset is committed (nothing is half-applied)" \
    || bad "an IPv6 ruleset was committed after the IPv4 pass had already failed open"

# ---- the published GitHub ranges feed BOTH families, from the one best-effort fetch -------
if command -v jq >/dev/null 2>&1; then
    SB="$(sb_new meta)"
    cat > "$SB/meta.json" <<'JSON'
{"web":["203.0.113.0/24","2001:db8:beef::/48"],"api":["203.0.113.128/25"],
 "git":["2001:db8:cafe::/48"],"packages":[]}
JSON
    OUT="$(run_fw "$SB" STUB_CURL_META="$SB/meta.json")"
    grep -q -- '-d 2001:db8:beef::/48 -m multiport --dports 22,80,443' "$SB/v6.rules" \
      && grep -q -- '-d 2001:db8:cafe::/48 -m multiport --dports 22,80,443' "$SB/v6.rules" \
      && grep -q -- '-d 203.0.113.0/24 -m multiport --dports 22,80,443'  "$SB/v4.rules" \
      && ok "GitHub's published ranges are split by family from ONE fetch: v6 CIDRs pin on IPv6, v4 on IPv4" \
      || bad "the published IPv6 ranges were discarded (or leaked into the wrong table)"
    grep -q -- '-d 2001:db8:beef::/48' "$SB/v4.rules" \
      && bad "an IPv6 CIDR was written into the IPv4 table" \
      || ok "no IPv6 CIDR leaks into the IPv4 table (and the IPv4 filter is unchanged)"
else
    bad "jq is unavailable, so the published-ranges split could not be exercised (jq is a baked image dependency; a skip here would be theater)"
fi

# ---- the dry-run seam is UNCHANGED by any of the above ------------------------------------
[[ "$(hosts)" == "$OFF" ]] \
    && ok "the dry-run host list is byte-identical to before the IPv6 work (one list, both families)" \
    || bad "the IPv6 work changed the dry-run host list"
DIRTY6="$(hosts | grep -cE 'IPv6|ipv6|\[egress\]' || true)"
[[ "$DIRTY6" -eq 0 ]] \
    && ok "the dry run stays a pure host list: no family annotations, no diagnostics on stdout" \
    || bad "the dry-run stdout gained family annotations or diagnostics"

echo
echo "egress-packages-unit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
