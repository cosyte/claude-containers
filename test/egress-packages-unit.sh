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
SB_REAL_TOOLS="bash timeout mktemp awk sort cat rm cp mkdir sleep wc head grep jq"

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
    # STUB_NET / STUB_NET6 move every answer to a different prefix without changing
    # WHICH hosts answer, which is how a refresh cycle is given something new to
    # commit: the same allowlist, resolved to different addresses, exactly as a CDN
    # rotation looks from inside the container.
    cat > "$sb/bin/getent" <<'EOS'
#!/usr/bin/env bash
db="$1"; host="${2:-}"
printf '%s %s\n' "$db" "$host" >> "$STUB_QUERYLOG"
idx="$(grep -nxF -- "$host" "$STUB_HOSTLIST" 2>/dev/null | head -1)"; idx="${idx%%:*}"
[[ -z "$idx" ]] && exit 2
case "$db" in
  ahostsv4) case " ${STUB_NO_V4:-} " in *" $host "*) exit 2 ;; esac
            printf '%s.%s STREAM %s\n%s.%s DGRAM\n' "${STUB_NET:-198.51.100}" "$idx" "$host" "${STUB_NET:-198.51.100}" "$idx" ;;
  ahostsv6) case " ${STUB_NO_V6:-} " in *" $host "*) exit 2 ;; esac
            printf '%s::%s STREAM %s\n%s::%s DGRAM\n' "${STUB_NET6:-2001:db8}" "$idx" "$host" "${STUB_NET6:-2001:db8}" "$idx" ;;
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

# run_fw_mode <sandbox> <script-argument, or empty for the boot pass> [VAR=VAL ...]:
# run the SHIPPED script against the sandbox with a scrubbed environment, merging its
# [egress] diagnostics into the output and appending fw_rc=<status>. For the boot pass
# that status is the per-family posture contract the entrypoint reads.
#
# CLAUDE_EGRESS_STATE_DIR is always redirected into the sandbox: the refresh path's
# memory of "what the ruleset in force was built from" is a root-only path under /run
# in a real container, and a test that wrote there would be both unrunnable in CI and
# a way for one case to leak state into the next.
run_fw_mode() {
    local sb="$1" arg="$2"; shift 2
    local rc=0 out; local -a a=()
    [[ -n "$arg" ]] && a=("$arg")
    out="$(env -i PATH="$sb/bin" HOME="$sb" TMPDIR="$sb/tmp" \
        STUB_QUERYLOG="$sb/queries" STUB_HOSTLIST="$sb/hostlist" \
        STUB_V4_RULES="$sb/v4.rules" STUB_V6_RULES="$sb/v6.rules" \
        STUB_V4_POLICY="$sb/v4.policy" STUB_V6_POLICY="$sb/v6.policy" \
        CLAUDE_EGRESS_STATE_DIR="$sb/state" \
        "$@" bash "$FW" ${a[@]+"${a[@]}"} 2>&1)" || rc=$?
    printf '%s\nfw_rc=%s\n' "$out" "$rc"
}
run_fw() { local sb="$1"; shift; run_fw_mode "$sb" "" "$@"; }
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

# Every host unresolvable on IPv6 is the same rule taken to its limit: a nearly sealed
# IPv6 table, never an open one. It cannot brick the container, because the IPv4
# allowlist committed above carries the same hosts.
#
# "Nearly" is the one thing that changed when Anthropic's PUBLISHED inbound ranges
# started being pinned from the publisher's list rather than from DNS alone: those do
# not come from a lookup, so no DNS failure can remove them and the table can no longer
# reach zero nets. The property this case exists for is untouched, and is what is
# asserted: DNS returning nothing on a family never falls back to OPEN egress.
SB="$(sb_new allnov6)"
OUT="$(run_fw "$SB" STUB_NO_V6="$(hosts | tr '\n' ' ')")"
grep -q 'could not resolve .* to an IPv6 address' <<<"$OUT" \
    && [[ "$(sb_pol "$SB" v6)" == "-P OUTPUT DROP" ]] \
    && grep -qxF 'fw_rc=0' <<<"$OUT" \
    && ok "zero DNS-resolvable IPv6 addresses still yields a DEFAULT-DENY IPv6 table, loudly, never an open one" \
    || bad "zero resolvable IPv6 addresses did not produce a default-deny, loudly-logged IPv6 table"
# and the only thing left in it is the published range, so nothing a failed lookup
# produced leaked in.
if [[ "$(sb_nets "$SB" v6)" -eq 1 ]] && grep -q -- '-d 2607:6bc0::/48 -m multiport' "$SB/v6.rules"; then
    ok "with no AAAA anywhere the IPv6 table holds ONLY Anthropic's published inbound range (nothing a failed lookup returned)"
else
    bad "the IPv6 table with no resolvable AAAA is not exactly the published inbound range: $(sb_nets "$SB" v6) nets"
fi

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
echo "the composed allowlist is answerable to the vendor's published requirements"

# An allowlist is only trustworthy if its GAPS are deliberate. A host that is simply
# missing looks exactly like a host somebody forgot, and the difference only surfaces
# as a feature that mysteriously does not work in a locked-down container weeks later.
#
# So docs/egress-allowlist.md carries one row per host the vendor's published network
# requirements name, each either `pinned` or `omitted` WITH A REASON, and this section
# grades the shipped allowlist against that record rather than against a list retyped
# here. The retyped part is deliberately only the INDEX (which hosts the vendor names),
# so a row cannot be quietly deleted to make a documented host disappear from both the
# allowlist and the record at once.
MEMO="$REPO_ROOT/docs/egress-allowlist.md"

# The hosts https://code.claude.com/docs/en/network-config names, from its "Network
# access requirements" table and its "Desktop and claude.ai" subsection. Every one of
# them must be accounted for in the memo; whether it is PINNED or OMITTED is the memo's
# call to make, not this list's.
DOCUMENTED_HOSTS="
api.anthropic.com claude.ai claude.com platform.claude.com mcp-proxy.anthropic.com
downloads.claude.ai storage.googleapis.com registry.npmjs.org
bridge.claudeusercontent.com *.frame.claudeusercontent.com raw.githubusercontent.com
http-intake.logs.us5.datadoghq.com browser-intake-us5-datadoghq.com
formulae.brew.sh code.claude.com
assets-proxy.anthropic.com *.claudeusercontent.com
fonts.googleapis.com fonts.gstatic.com
cdnjs.cloudflare.com cdn.jsdelivr.net cdn.tailwindcss.com code.jquery.com
"

# host<TAB>status<TAB>feature<TAB>why-not, one line per graded row. A row is graded
# only when its status cell is one of the three known statuses, so headers, separators
# and the memo's other tables cannot smuggle themselves in as rows.
memo_rows() {
  awk -F'|' 'NF >= 6 {
      h=$2; s=$3; f=$4; w=$5
      gsub(/^[ \t]+|[ \t]+$/,"",h); gsub(/^[ \t]+|[ \t]+$/,"",s)
      gsub(/^[ \t]+|[ \t]+$/,"",f); gsub(/^[ \t]+|[ \t]+$/,"",w)
      gsub(/`/,"",h)
      if (s != "pinned" && s != "omitted" && s != "omitted-wildcard") next
      printf "%s\t%s\t%s\t%s\n", h, s, f, w
  }' "$MEMO"
}

if [[ -f "$MEMO" ]] && [[ "$(memo_rows | wc -l)" -ge 15 ]]; then
    ok "the omission record exists and parses ($(memo_rows | wc -l) graded rows in docs/egress-allowlist.md)"
else
    bad "docs/egress-allowlist.md is missing or has no parseable rows: every check below would be vacuous"
fi

COMPOSED="$(hosts)"
# Diagnostics only (the wildcard report and everything else the script says while
# composing), with stdout thrown away so this cannot accidentally read the host list.
COMPOSE_LOG="$(env CLAUDE_EGRESS_PRINT_HOSTS=1 bash "$FW" 2>&1 >/dev/null)"

miss_pinned=() leaked=() unreasoned=()
while IFS=$'\t' read -r h st feat why; do
    case "$st" in
      pinned)  grep -qxF "$h" <<<"$COMPOSED" || miss_pinned+=("$h") ;;
      omitted|omitted-wildcard)
               grep -qxF "$h" <<<"$COMPOSED" && leaked+=("$h")
               [[ -z "${why// }" ]] && unreasoned+=("$h") ;;
    esac
done < <(memo_rows)
[[ ${#miss_pinned[@]} -eq 0 ]] \
    && ok "every host the record calls PINNED is actually in the composed allowlist" \
    || bad "the record claims these hosts are pinned but the allowlist does not carry them: ${miss_pinned[*]}"
[[ ${#leaked[@]} -eq 0 ]] \
    && ok "every host the record calls OMITTED is actually absent from the composed allowlist" \
    || bad "the record claims these hosts are omitted but the allowlist carries them: ${leaked[*]}"
[[ ${#unreasoned[@]} -eq 0 ]] \
    && ok "every omission carries a written reason (an unexplained gap is the defect this record exists to prevent)" \
    || bad "these hosts are omitted with no reason given: ${unreasoned[*]}"

# The reconciliation itself: a documented host must be one or the other, and never
# neither. This is the check that fails the day the vendor's list grows and nobody
# looks at it.
undocumented=()
for h in $DOCUMENTED_HOSTS; do
    memo_rows | cut -f1 | grep -qxF -- "$h" || undocumented+=("$h")
done
[[ ${#undocumented[@]} -eq 0 ]] \
    && ok "every host the published requirements name is either pinned or recorded as omitted ($(echo $DOCUMENTED_HOSTS | wc -w) documented hosts)" \
    || bad "these documented hosts are neither pinned nor named in the omission record: ${undocumented[*]}"

# The four hosts the record was written because they were missing. Named explicitly so
# a regression that dropped them again cannot hide behind the generic loop above.
for h in claude.com mcp-proxy.anthropic.com code.claude.com platform.claude.com; do
    grep -qxF "$h" <<<"$COMPOSED" || bad "the documented host $h is not in the composed allowlist"
done
ok "the previously-omitted documented hosts (claude.com, mcp-proxy.anthropic.com, code.claude.com) are pinned"

# The set only GREW. Dropping a host to make room would be a silent egress regression
# for whatever depended on it, so the pre-existing entries are asserted by name.
for h in api.anthropic.com claude.ai platform.claude.com downloads.claude.ai \
         bridge.claudeusercontent.com raw.githubusercontent.com objects.githubusercontent.com \
         storage.googleapis.com statsig.anthropic.com statsig.com api.growthbook.io \
         cdn.growthbook.io us.sentry.io downloads.sentry-cdn.com registry.npmjs.org \
         github.com api.github.com codeload.github.com; do
    grep -qxF "$h" <<<"$COMPOSED" || bad "reconciliation DROPPED a host that was already pinned: $h"
done
ok "reconciliation is additive: every host pinned before is still pinned"

echo
echo "a wildcard names the feature it costs, instead of failing silently"

# A pattern has no address, so an IP allowlist can never admit it. That is not the
# defect. The defect is silence: a container where one vendor feature simply does not
# work, with nothing in the log connecting it to the allowlist, gets diagnosed as a bug
# in the feature. Every wildcard the record carries must therefore be named IN THE LOG,
# at composition time, together with what it costs.
wc_rows=0 wc_bad=()
while IFS=$'\t' read -r h st feat why; do
    [[ "$st" == "omitted-wildcard" ]] || continue
    wc_rows=$((wc_rows+1))
    case "$h" in *'*'*) ;; *) wc_bad+=("$h: recorded as a wildcard but has no pattern") ;; esac
    grep -qF "WILDCARD NOT PINNED: $h " <<<"$COMPOSE_LOG" || wc_bad+=("$h: not named in the composition log")
    [[ -z "${feat// }" ]] && wc_bad+=("$h: no feature named for it in the record")
done < <(memo_rows)
[[ "$wc_rows" -ge 2 && ${#wc_bad[@]} -eq 0 ]] \
    && ok "every wildcard in the record ($wc_rows) is named in the composition log with the feature it costs" \
    || bad "wildcard reporting is incomplete: ${wc_bad[*]:-no wildcard rows were graded at all}"
grep -qF 'WHAT WILL NOT WORK: Artifact content reads' <<<"$COMPOSE_LOG" \
    && ok "the artifact wildcard names Artifact content reads as the CLI feature that will not work" \
    || bad "the artifact wildcard does not name the feature an operator loses"
# The report is a diagnostic. It must not contaminate the host list the enforcement
# path consumes, or a pattern would reach the resolver as if it were a host.
grep -qE '^\*' <<<"$COMPOSED" \
    && bad "a wildcard pattern leaked into the composed host list (it would be resolved as a hostname)" \
    || ok "no wildcard pattern is in the composed host list: the report is a diagnostic, not an allowlist entry"
# An operator's own pattern gets the same treatment rather than one more anonymous
# "could not resolve" line.
EXTRA_WC="$(env CLAUDE_EGRESS_PRINT_HOSTS=1 CLAUDE_EGRESS_EXTRA_HOSTS='*.internal.example' bash "$FW" 2>&1 >/dev/null)"
grep -qF 'WILDCARD NOT PINNED: *.internal.example ' <<<"$EXTRA_WC" \
    && ok "a wildcard supplied through CLAUDE_EGRESS_EXTRA_HOSTS is reported as unpinnable too" \
    || bad "an operator-supplied wildcard is accepted silently and would just fail to resolve"

echo
echo "Anthropic's published ranges: INBOUND destinations, pinned ADDITIVELY"

# The publisher's page has three sections and only one of them is a destination.
# Inbound is where Anthropic RECEIVES connections, which is what a container dials.
# Outbound (160.79.104.0/21) is the source addresses Anthropic uses when IT calls out:
# someone else's ingress allowlist, and an eightfold wider prefix. Phased out is a set
# the publisher asks people to REMOVE. Getting this wrong is not a cosmetic error: it
# either fails to pin the API or broadens egress by 2048 addresses for nothing.
ANTHROPIC_IN4="160.79.104.0/23"
ANTHROPIC_IN6="2607:6bc0::/48"
ANTHROPIC_NOT="160.79.104.0/21 34.162.46.92/32 34.162.102.82/32 34.162.136.91/32 34.162.142.92/32 34.162.183.95/32"

SB="$(sb_new anthropic)"
OUT="$(run_fw "$SB")"
grep -qF -- "-d $ANTHROPIC_IN4 -m multiport --dports 22,80,443" "$SB/v4.rules" \
    && grep -qF -- "-d $ANTHROPIC_IN6 -m multiport --dports 22,80,443" "$SB/v6.rules" \
    && ok "the published INBOUND ranges are pinned on BOTH families ($ANTHROPIC_IN4, $ANTHROPIC_IN6)" \
    || bad "an Anthropic published inbound range is missing from a family's ruleset"
out_leak=()
for n in $ANTHROPIC_NOT; do
    grep -qF -- "-d $n " "$SB/v4.rules" 2>/dev/null && out_leak+=("$n")
    grep -qF -- "-d $n " "$SB/v6.rules" 2>/dev/null && out_leak+=("$n")
done
[[ ${#out_leak[@]} -eq 0 ]] \
    && ok "the published OUTBOUND prefix and the phased-out addresses are NOT in the destination allowlist" \
    || bad "an outbound/phased-out range reached the destination allowlist: ${out_leak[*]}"
# Additive, not instead of: every per-host answer still has its own rule, so a host
# that resolves outside Anthropic's space stays reachable.
if grep -q -- '-d 198.51.100.1 -m multiport' "$SB/v4.rules" \
   && grep -q -- '-d 2001:db8::1 -m multiport' "$SB/v6.rules" \
   && [[ "$(sb_nets "$SB" v4)" -eq $(( $(hosts | wc -l) + 1 )) ]]; then
    ok "the published ranges are ADDED to per-host resolution, not substituted for it (all $(hosts | wc -l) resolved hosts plus the published range)"
else
    bad "pinning the published ranges replaced or reduced what per-host resolution produced"
fi
# The whole point of pinning from the publisher rather than from DNS: no lookup can
# take it away. Everything except one host answers with nothing here, so the pass
# still has something to commit and the question is only whether the published range
# survived a resolver that produced none of it.
KEEPHOST=github.com
SB="$(sb_new anthropic_nodns)"
NODNS="$(hosts | grep -vxF "$KEEPHOST" | tr '\n' ' ')"
OUT="$(run_fw "$SB" STUB_NO_V4="$NODNS" STUB_NO_V6="$NODNS")"
grep -qF -- "-d $ANTHROPIC_IN4 " "$SB/v4.rules" && grep -qF -- "-d $ANTHROPIC_IN6 " "$SB/v6.rules" \
    && ok "with every DNS answer but one empty the published inbound ranges are STILL pinned (they do not come from a lookup)" \
    || bad "an empty resolver removed the published inbound range, which is the failure pinning it exists to prevent"
[[ "$(sb_nets "$SB" v4)" -eq 2 && "$(sb_nets "$SB" v6)" -eq 2 ]] \
    && ok "and each table is exactly the one host that answered plus the published range: nothing a failed lookup returned leaked in" \
    || bad "the tables built from one answered host are not (that host + the published range): v4=$(sb_nets "$SB" v4) v6=$(sb_nets "$SB" v6)"

# THE PUBLISHED RANGE IS NOT EVIDENCE THAT THE ALLOWLIST RESOLVED, and this is the
# case that says so. It is a constant: it is in the composition whatever the resolver
# did, so counting it when asking "did anything resolve" retires the boot pass's
# fail-open guard altogether. A container whose resolver answers nothing would then
# commit a default-deny table admitting exactly one /23, exit 0, and have the boot log
# call that successful lockdown, while CLAUDE_EGRESS_LOCKDOWN=strict (which refuses on
# status 1 and nothing else) would have no status left to refuse on. The posture on a
# total resolution failure is UNRESTRICTED and loud, and it is asserted four ways.
SB="$(sb_new nodns_at_all)"
OUT="$(run_fw "$SB" STUB_NO_V4="$(hosts | tr '\n' ' ')" STUB_NO_V6="$(hosts | tr '\n' ' ')")"
grep -q 'allowlist resolved to zero IPs, failing OPEN' <<<"$OUT" \
    && ok "a resolver that answers nothing at all still reaches the fail-open guard, by name" \
    || bad "the zero-resolution fail-open guard did not fire: the published range was counted as a resolved allowlist"
grep -qxF 'fw_rc=1' <<<"$OUT" \
    && ok "and it exits 1, the only status CLAUDE_EGRESS_LOCKDOWN=strict refuses on" \
    || bad "a total resolution failure did not exit 1: $(grep '^fw_rc=' <<<"$OUT")"
[[ "$(sb_pol "$SB" v4)" == "-P OUTPUT ACCEPT" && ! -e "$SB/v4.rules" ]] \
    && ok "nothing is committed: the IPv4 policy is left ACCEPT (egress open), never sealed to the published range" \
    || bad "a total resolution failure committed a ruleset anyway: policy $(sb_pol "$SB" v4), $(sb_nets "$SB" v4) rules"
grep -q 'egress posture: IPv4 UNRESTRICTED, IPv6 UNRESTRICTED' <<<"$OUT" \
    && ok "and the log says UNRESTRICTED on both families rather than claiming lockdown" \
    || bad "a total resolution failure was reported as containment"

echo
echo "the periodic refresh: it re-commits, and it NEVER narrows"

# Everything below drives the shipped script's --refresh-once mode against the same
# fake kernel. The shape is always: BOOT the sandbox once (which commits a ruleset and
# records what it was built from), then change one thing about the world and refresh.
# What is under test is the DECISION, and a decision is provable without a real table.
#
# The interval is set on the boot run because the state the refresh reads is only
# written when a refresh is actually configured: a container that never asked for one
# must touch no new path at all.
RI="CLAUDE_EGRESS_REFRESH_INTERVAL=60"

# sb_boot <name>: a sandbox that has already been through a boot pass WITH a refresh
# interval, so it carries a committed ruleset and the record of what built it. Kept
# out of a command substitution on purpose: $SB has to survive into the assertions.
sb_boot() { SB="$(sb_new "$1")"; run_fw "$SB" $RI >/dev/null; }

# --- it actually re-resolves and re-commits ------------------------------------------
sb_boot refresh_ok
OUT="$(run_fw_mode "$SB" --refresh-once $RI STUB_NET=203.0.113 STUB_NET6=2001:db8:99)"
grep -q 'REFRESH: IPv4 allowlist re-resolved and the refreshed ruleset committed atomically' <<<"$OUT" \
    && grep -q 'REFRESH: IPv6 allowlist re-resolved and the refreshed ruleset committed atomically' <<<"$OUT" \
    && ok "a refresh re-resolves the allowlist and re-commits BOTH families" \
    || bad "a refresh did not re-commit both families"
grep -q -- '-d 203.0.113.1 -m multiport --dports 22,80,443' "$SB/v4.rules" \
    && grep -q -- '-d 2001:db8:99::1 -m multiport --dports 22,80,443' "$SB/v6.rules" \
    && ok "the committed ruleset carries the NEW addresses (the refresh is a real re-resolution, not a re-apply)" \
    || bad "the refreshed ruleset still holds the boot-time addresses"
grep -q -- '-d 198.51.100.1 -m multiport' "$SB/v4.rules" \
    && bad "the refreshed ruleset still carries a stale boot-time address" \
    || ok "the stale boot-time addresses are gone: the ruleset was replaced wholesale, in one restore"
[[ "$(sb_pol "$SB" v4)" == "-P OUTPUT DROP" && "$(sb_pol "$SB" v6)" == "-P OUTPUT DROP" ]] \
    && ok "both families are still default-deny after the refresh (the policy is never put back to ACCEPT)" \
    || bad "a refresh left a family's policy somewhere other than DROP"
grep -qxF 'fw_rc=0' <<<"$OUT" \
    && ok "a refresh exits 0: it is never the reason a running session stops" \
    || bad "a refresh exited non-zero: $(grep '^fw_rc=' <<<"$OUT")"
# The two families stay separate across a refresh exactly as they do at boot. The
# refresh adds to both arrays from one resolution wave, so a family mix-up here would
# be silent: an IPv4 address in the IPv6 table is not a rule, it is a broken restore
# or, worse, a rule for something else entirely.
if grep -qE -- '-d [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)? -m multiport' "$SB/v6.rules" \
   || grep -qE -- '-d [0-9a-f]*:[0-9a-f:]* -m multiport' "$SB/v4.rules"; then
    bad "a refresh leaked an address into the WRONG family's table"
else
    ok "a refresh keeps the two families separate: no IPv4 address in the IPv6 table, and no IPv6 address in the IPv4 one"
fi

# --- RETAIN ON EMPTY: the invariant the whole feature is built around -----------------
# A host that contributed addresses to the ruleset in force and now answers with
# nothing is evidence about the RESOLVER, not about the host. Narrowing on it takes a
# working container off the network mid-task, and no later pass gives that work back.
sb_boot refresh_lost
OUT="$(run_fw_mode "$SB" --refresh-once $RI STUB_NO_V4="api.anthropic.com github.com")"
grep -q 'REFRESH: api.anthropic.com returned NO IPv4 address this cycle but is pinned in the ruleset in force' <<<"$OUT" \
    && grep -q 'REFRESH: github.com returned NO IPv4 address this cycle but is pinned in the ruleset in force' <<<"$OUT" \
    && ok "a host that previously resolved and now answers with nothing is logged BY NAME" \
    || bad "a host lost between cycles was not named in the log"
grep -q 'the ruleset already in force is RETAINED unchanged' <<<"$OUT" \
    && ok "the ruleset in force is RETAINED rather than narrowed" \
    || bad "an empty answer did not retain the ruleset in force"
if grep -q -- '-d 198.51.100.1 -m multiport' "$SB/v4.rules" \
   && [[ "$(sb_nets "$SB" v4)" -eq $(( $(hosts | wc -l) + 1 )) ]]; then
    ok "the committed IPv4 table is byte-for-byte the one the boot pass applied (nothing was dropped)"
else
    bad "the IPv4 table was rewritten after a failed lookup: the allowlist NARROWED"
fi
# The other family is independent: only the one that lost a host retains.
grep -q 'REFRESH: IPv6 allowlist re-resolved and the refreshed ruleset committed atomically' <<<"$OUT" \
    && ok "a host lost on IPv4 does not stop the IPv6 family from refreshing (the two are decided separately)" \
    || bad "one family's empty answer abandoned the other family too"
grep -qxF 'fw_rc=0' <<<"$OUT" \
    && ok "retaining on an empty answer does not stop the session (exit 0, no refusal)" \
    || bad "a retained refresh exited non-zero"
grep -q 'failing OPEN' <<<"$OUT" \
    && bad "a refresh called fail_open: it would have torn down the lockdown of a live container" \
    || ok "no refresh path ever reaches fail_open (that is the boot pass's posture, not this one's)"

# Every host lost at once is the same rule at its limit, and the temptation to commit
# a sealed table is exactly the outcome the retain rule forbids.
sb_boot refresh_allempty
OUT="$(run_fw_mode "$SB" --refresh-once $RI STUB_NO_V4="$(hosts | tr '\n' ' ')" STUB_NO_V6="$(hosts | tr '\n' ' ')")"
grep -q 'the ruleset already in force is RETAINED unchanged' <<<"$OUT" \
    && [[ "$(sb_nets "$SB" v4)" -eq $(( $(hosts | wc -l) + 1 )) ]] \
    && ok "a resolver that answers nothing at all retains both rulesets: it never seals the container" \
    || bad "a total resolver failure narrowed or sealed the ruleset in force"

# --- RETAIN ON FAILURE: absent tooling, and a rejected restore ------------------------
sb_boot refresh_v4reject
OUT="$(run_fw_mode "$SB" --refresh-once $RI STUB_V4_FAIL=1)"
grep -q 'REFRESH: iptables-restore rejected the refreshed IPv4 ruleset; the ruleset already in force is RETAINED unchanged' <<<"$OUT" \
    && ok "a rejected IPv4 restore names the family and retains what is in force" \
    || bad "a rejected refresh restore did not report the family or did not retain"
[[ "$(sb_pol "$SB" v4)" == "-P OUTPUT DROP" ]] && grep -q -- '-d 198.51.100.1 ' "$SB/v4.rules" \
    && ok "the previously committed IPv4 table survives a rejected refresh, policy and rules alike" \
    || bad "a rejected refresh damaged the ruleset in force"
grep -qxF 'fw_rc=0' <<<"$OUT" \
    && ok "a rejected refresh restore does not stop the running session" \
    || bad "a rejected refresh restore exited non-zero"

# Absent tooling is expressed by NOT CREATING the binary, so `command -v` really fails.
SB="$(sb_new refresh_noip6 --no-ip6)"
run_fw "$SB" $RI >/dev/null
OUT="$(run_fw_mode "$SB" --refresh-once $RI)"
grep -q 'REFRESH: the boot pass never committed a IPv6 ruleset' <<<"$OUT" \
    && ok "a family the boot pass could not commit is left alone by the refresh, never silently sealed later" \
    || bad "the refresh touched a family the boot log had already reported as UNRESTRICTED"
grep -q 'REFRESH: IPv4 allowlist re-resolved and the refreshed ruleset committed atomically' <<<"$OUT" \
    && ok "and the family that WAS committed still refreshes normally beside it" \
    || bad "an uncommittable IPv6 family stopped the IPv4 refresh"

# The published GitHub ranges are a lookup too, so the same rule binds them: a fetch
# that failed must not shrink what is already pinned.
if command -v jq >/dev/null 2>&1; then
    SB="$(sb_new refresh_ghmeta)"
    cat > "$SB/meta.json" <<'JSON'
{"web":["203.0.113.0/24","2001:db8:beef::/48"],"api":[],"git":[],"packages":[]}
JSON
    run_fw "$SB" $RI STUB_CURL_META="$SB/meta.json" >/dev/null
    OUT="$(run_fw_mode "$SB" --refresh-once $RI)"   # no STUB_CURL_META: the fetch now fails
    grep -q 'REUSING the published GitHub ranges the ruleset in force already carries' <<<"$OUT" \
        && grep -q -- '-d 203.0.113.0/24 -m multiport' "$SB/v4.rules" \
        && grep -q -- '-d 2001:db8:beef::/48 -m multiport' "$SB/v6.rules" \
        && ok "a failed api.github.com/meta fetch REUSES the ranges in force instead of dropping them" \
        || bad "a failed meta fetch on refresh silently narrowed the allowlist by the published GitHub ranges"

    # AND A FETCH THAT SUCCEEDS BUT PRODUCES NOTHING IS THE SAME EMPTY ANSWER. curl
    # exiting 0 says the transport worked, not that the body carried an address: a
    # proxy interstitial, a rate-limit body or a schema change all reduce to an empty
    # list. Treating that as a successful re-fetch commits a live ruleset with GitHub's
    # entire published address space removed AND overwrites the remembered copy with
    # the empty result, so no later cycle can recover it either. Both halves are
    # asserted, because the second is the one that makes the damage permanent.
    SB="$(sb_new refresh_ghempty)"
    cat > "$SB/meta.json" <<'JSON'
{"web":["203.0.113.0/24","2001:db8:beef::/48"],"api":[],"git":[],"packages":[]}
JSON
    cat > "$SB/meta-noranges.json" <<'JSON'
{"message":"Not Found","documentation_url":"https://docs.github.com/rest"}
JSON
    run_fw "$SB" $RI STUB_CURL_META="$SB/meta.json" >/dev/null
    OUT="$(run_fw_mode "$SB" --refresh-once $RI STUB_CURL_META="$SB/meta-noranges.json")"
    grep -q 'REUSING the published GitHub ranges the ruleset in force already carries' <<<"$OUT" \
        && grep -q -- '-d 203.0.113.0/24 -m multiport' "$SB/v4.rules" \
        && grep -q -- '-d 2001:db8:beef::/48 -m multiport' "$SB/v6.rules" \
        && ok "a 200 from api.github.com/meta that carries NO ranges is an empty answer too: the ranges in force are reused, not dropped" \
        || bad "a meta response with no ranges narrowed the live allowlist by GitHub's entire published address space"
    grep -q 'REFRESH: re-fetched the published GitHub ranges' <<<"$OUT" \
        && bad "the log claimed a successful re-fetch on the cycle that produced no ranges (claude-logs would show no signal at all)" \
        || ok "and the log does not claim a successful re-fetch on a cycle that produced no ranges"
    [[ -s "$SB/state/github.4" && -s "$SB/state/github.6" ]] \
        && ok "the remembered ranges survive, so the reuse fallback still has something to reuse next cycle" \
        || bad "the remembered ranges were overwritten with the empty result: the fallback is destroyed for every later cycle"
else
    bad "jq is unavailable, so the refresh's published-ranges retention could not be exercised"
fi

# THE ZERO-NETS RETAIN IS A LIVE GUARD, for the same reason the boot pass's fail-open
# one is: the published inbound range is folded in AFTER the cycle is counted, never
# before. A family whose cycle resolves nothing must retain what is in force rather
# than commit a table sealed to that one range. The boot below leaves IPv6 with a
# committed ruleset and no per-host answers at all, which is exactly the state that
# reaches the guard on the next cycle.
SB="$(sb_new refresh_zeronets)"
ALLHOSTS="$(hosts | tr '\n' ' ')"
run_fw "$SB" $RI STUB_NO_V6="$ALLHOSTS" >/dev/null
OUT="$(run_fw_mode "$SB" --refresh-once $RI STUB_NO_V6="$ALLHOSTS")"
grep -q 'the allowlist resolved to ZERO IPv6 nets this cycle, which would seal the family rather than refresh it' <<<"$OUT" \
    && ok "a refresh cycle that resolves ZERO nets for a family RETAINS it (the guard is reachable, not decoration)" \
    || bad "the zero-nets retain never fired: the published range was counted as this cycle's resolution"
grep -q 'REFRESH: IPv4 allowlist re-resolved and the refreshed ruleset committed atomically' <<<"$OUT" \
    && ok "and the family that did resolve still refreshes beside it" \
    || bad "a zero-nets family stopped the other family's refresh"

# --- lockdown off, and an unconfigured interval, start nothing ------------------------
# Lockdown off never runs this script at all (entrypoint.sh §12a, covered in
# test/unit.sh). What is proved here is the other half of that promise: the refresh
# feature is invisible to composition, so a container that never asked for one gets a
# byte-identical host set and no new files anywhere.
[[ "$(hosts CLAUDE_EGRESS_REFRESH_INTERVAL=900)" == "$OFF" ]] \
    && ok "the composed host set is byte-identical with and without a refresh interval" \
    || bad "configuring the refresh interval changed the composed allowlist"
for _v in "" 0 -1 abc 15m 1.5; do
    [[ "$(hosts CLAUDE_EGRESS_REFRESH_INTERVAL="$_v")" == "$OFF" ]] \
        || bad "CLAUDE_EGRESS_REFRESH_INTERVAL='$_v' changed the composed allowlist"
done
ok "no interval value, valid or malformed, can change which hosts are allowlisted"

SB="$(sb_new refresh_unconfigured)"
run_fw "$SB" >/dev/null                       # boot with NO interval configured
[[ ! -e "$SB/state" ]] \
    && ok "a boot with no refresh interval writes no refresh state at all (nothing new is touched)" \
    || bad "an unconfigured container still wrote refresh state"
OUT="$(run_fw_mode "$SB" --refresh-daemon)"
grep -q 'the daemon has nothing to do and is not starting' <<<"$OUT" && grep -qxF 'fw_rc=0' <<<"$OUT" \
    && ok "the daemon refuses to loop without a positive interval, and says so, instead of spinning" \
    || bad "the refresh daemon started (or hung) without a configured interval"
for _v in 0 abc 15m -5; do
    OUT="$(run_fw_mode "$SB" --refresh-daemon CLAUDE_EGRESS_REFRESH_INTERVAL="$_v")"
    grep -q 'the daemon has nothing to do and is not starting' <<<"$OUT" \
        || bad "CLAUDE_EGRESS_REFRESH_INTERVAL='$_v' was treated as a usable interval"
done
ok "absent, malformed and non-positive intervals are all one case, and it is the safe one"

# The boot pass is unchanged by any of this: same exit status, same posture lines.
SB="$(sb_new refresh_bootcontract)"
OUT="$(run_fw "$SB" $RI)"
grep -qxF 'fw_rc=0' <<<"$OUT" \
    && grep -q 'egress posture: IPv4 default-deny, IPv6 default-deny' <<<"$OUT" \
    && ok "a boot pass WITH a refresh interval still reports the same posture and the same exit 0" \
    || bad "configuring a refresh changed the boot pass's per-family status contract"

echo
echo "egress-packages-unit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
