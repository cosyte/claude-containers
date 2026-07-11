#!/usr/bin/env bash
# apt-provision-unit.sh — pure-static tests for PKG-4: brokered, curated worker apt.
# NO docker, NO network, NO real apt, NO iptables, NO root — safe for CI / verify.sh.
#
# PKG-4 installs a curated, pinned apt manifest as root in a Sysbox WORKER, before the
# agent, opening deb.debian.org egress for the window then re-locking. The live proof
# ("a manifest package installs in a real worker AND `id` shows root→non-root host uid;
# a leaf refuses; egress re-locked after") needs a Sysbox host and is the on-host gate
# (docs/package-provisioning-security.md §4). Here we drive the provisioner's LOGIC
# through its seams — the tier gate, the deny-by-default validator, curated-not-open
# resolution, and the install-then-relock ORDER — since a regression in any is a
# supply-chain or safety break that must gate in CI, not wait for a build.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/bin/claude-apt-provision"
FIREWALL="$REPO_ROOT/bin/claude-egress-firewall"
PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "PKG-4 brokered curated worker apt (claude-apt-provision)"

# ---- sources cleanly as a library (test seam), defines aptp_* and does NOT dispatch --------------
# shellcheck disable=SC1090
if source "$SCRIPT" 2>/dev/null && declare -F aptp_provision >/dev/null && declare -F aptp_valid_spec >/dev/null; then
    ok "sources as a library — aptp_* defined, no dispatch on source"
else
    bad "sourcing the script failed or did not define the aptp_* functions"
    echo "PKG-4: $PASS passed, $FAIL failed"; exit 1
fi

# ---- deny-by-default spec validator --------------------------------------------------------------
for good in libpq5 lib3 gcc-12 libpq5=15.10-0+deb12u1 zlib1g=1:1.2.13.dfsg-1 ca-certificates; do
    aptp_valid_spec "$good" && ok "valid spec accepted: $good" || bad "valid spec REJECTED: $good"
done
for bad_spec in 'libpq5 libssl' '../evil' 'foo;rm' 'foo/bar' 'Foo' 'foo=' '-foo' '$(x)' 'foo=bad ver'; do
    if aptp_valid_spec "$bad_spec"; then bad "INVALID spec accepted: '$bad_spec'"; else ok "invalid spec refused: '$bad_spec'"; fi
done

# ---- manifest loader: strip comments/blanks, fail closed on a bad line ----------------------------
man="$TMP/manifest.txt"
cat >"$man" <<'EOF'
# a comment
libpq5=15.10-0+deb12u1

ca-certificates   # trailing comment
EOF
out="$(CLAUDE_APT_MANIFEST_FILE="$man" aptp_load_manifest)"; rc=$?
if [[ $rc == 0 && "$out" == $'libpq5=15.10-0+deb12u1\nca-certificates' ]]; then
    ok "manifest load: comments/blank lines stripped, two specs returned"
else
    bad "manifest load wrong (rc=$rc): $(echo "$out" | tr '\n' '|')"
fi

badman="$TMP/bad.txt"; printf 'libpq5\nnot ok\n' >"$badman"
if CLAUDE_APT_MANIFEST_FILE="$badman" aptp_load_manifest >/dev/null 2>&1; then
    bad "a malformed manifest entry did NOT fail closed"
else
    ok "malformed manifest entry fails the whole load closed (all-or-refuse)"
fi

# DEFAULT manifest path absent (no explicit override) = a legitimate empty no-op.
# Override APTP_MANIFEST_DEFAULT to a missing path with CLAUDE_APT_MANIFEST_FILE unset.
if out="$( unset CLAUDE_APT_MANIFEST_FILE; APTP_MANIFEST_DEFAULT="$TMP/no-default.txt" aptp_load_manifest 2>/dev/null )" && [[ -z "$out" ]]; then
    ok "absent DEFAULT manifest (no override) = empty, rc 0"
else
    bad "absent default manifest should be an empty rc-0 load"
fi

# An EXPLICIT CLAUDE_APT_MANIFEST_FILE override that doesn't resolve is a MISCONFIG —
# fail closed (rc 2), not a silent empty no-op. Closes the "typo the path / pass a
# broker-host path" footgun where a worker boots without an expected syslib.
if CLAUDE_APT_MANIFEST_FILE="$TMP/typo-none.txt" aptp_load_manifest >/dev/null 2>&1; then
    bad "an explicit missing manifest override did NOT fail closed"
else
    ok "explicit missing manifest override fails closed (rc 2, no silent no-op)"
fi

# ---- resolve: whole manifest vs a curated subset; out-of-manifest is REFUSED ---------------------
out="$(CLAUDE_APT_MANIFEST_FILE="$man" aptp_resolve_specs)"
[[ "$out" == $'libpq5=15.10-0+deb12u1\nca-certificates' ]] \
    && ok "resolve with no args = the whole manifest" || bad "resolve-all wrong: $out"

# a request resolves to the manifest's OWN pinned spec, not the requested version
out="$(CLAUDE_APT_MANIFEST_FILE="$man" aptp_resolve_specs libpq5=9.9-evil)"
[[ "$out" == 'libpq5=15.10-0+deb12u1' ]] \
    && ok "a request resolves to the curated pin (can't smuggle a version)" || bad "resolve-subset wrong: $out"

if CLAUDE_APT_MANIFEST_FILE="$man" aptp_resolve_specs curl >/dev/null 2>&1; then
    bad "an out-of-manifest package was NOT refused"
else
    ok "out-of-manifest request refused (curated-not-open)"
fi

# ---- tier gate: as a non-root CI user, provisioning refuses with the documented leaf message -----
if [[ "$(id -u)" != 0 ]]; then
    if aptp_is_userns_root; then bad "aptp_is_userns_root true as a non-root user"; else ok "tier gate: non-root is not a worker"; fi
    err="$(CLAUDE_APT_MANIFEST_FILE="$man" aptp_provision 2>&1 >/dev/null)"; rc=$?
    if (( rc == 3 )) && grep -q 'worker-tier only' <<<"$err" && grep -qi 'mise' <<<"$err"; then
        ok "leaf provision refused (rc 3) with the documented 'use mise/static binaries' message"
    else
        bad "leaf refusal wrong (rc=$rc): $err"
    fi
else
    ok "(running as root — leaf-refusal case exercised by the resolve/window tests instead)"
fi

# ---- install-then-relock ORDER, with the firewall + apt stubbed and the tier gate forced ---------
# Stub the firewall to record the CLAUDE_EGRESS_APT env it saw; stub apt to record argv + exit code.
fwlog="$TMP/fw.log"; aptlog="$TMP/apt.log"
fwstub="$TMP/fw"; cat >"$fwstub" <<EOF
#!/usr/bin/env bash
echo "fw APT=\${CLAUDE_EGRESS_APT:-unset}" >>"$fwlog"
exit \${FW_RC:-0}
EOF
aptstub="$TMP/apt"; cat >"$aptstub" <<EOF
#!/usr/bin/env bash
echo "apt \$*" >>"$aptlog"
[[ "\$1" == install ]] && exit \${APT_INSTALL_RC:-0}
exit 0
EOF
chmod +x "$fwstub" "$aptstub"

run_provision() (
    # subshell: override the tier gate to "worker" and point the seams at the stubs
    aptp_is_userns_root() { return 0; }
    CLAUDE_EGRESS_LOCKDOWN=1 CLAUDE_APT_MANIFEST_FILE="$man" \
        APTP_FIREWALL="$fwstub" APTP_APT="$aptstub" aptp_provision
)

: >"$fwlog"; : >"$aptlog"
if run_provision >/dev/null 2>&1; then ok "happy-path provision returns success"; else bad "happy-path provision failed"; fi
# firewall called twice: first WITH the apt profile (open), then WITHOUT (relock)
if [[ "$(cat "$fwlog")" == $'fw APT=1\nfw APT=unset' ]]; then
    ok "egress order: opened WITH the apt profile, then re-locked WITHOUT it"
else
    bad "egress open/relock order wrong: $(tr '\n' '|' <"$fwlog")"
fi
grep -q 'apt install -y --no-install-recommends -- libpq5=15.10-0+deb12u1 ca-certificates' "$aptlog" \
    && ok "apt install ran with the resolved curated specs (after \`--\` end-of-options)" || bad "apt install argv wrong: $(cat "$aptlog")"

# all-or-refuse: even when the install FAILS, the relock still runs (no egress-open worker)
: >"$fwlog"; : >"$aptlog"
if APT_INSTALL_RC=1 run_provision >/dev/null 2>&1; then
    bad "a failed install must make provision refuse (non-zero)"
else
    ok "a failed install refuses (non-zero) — no partial trust"
fi
if [[ "$(tail -1 "$fwlog")" == 'fw APT=unset' ]]; then
    ok "install-then-relock holds on FAILURE: egress re-locked after a failed install"
else
    bad "relock did NOT run after a failed install: $(tr '\n' '|' <"$fwlog")"
fi

# EMPTY manifest (the SHIPPED default) through FULL aptp_provision: a true no-op —
# rc 0, NO egress window opened, NO apt install. Regression guard: an empty array fed
# to `printf '%s\n'` prints a lone blank line that mapfile reads as one empty element,
# which would otherwise open the window and run `apt-get install ''`.
emptyman="$TMP/empty.txt"; printf '# only comments\n\n# nothing curated\n' >"$emptyman"
: >"$fwlog"; : >"$aptlog"
run_provision_man() ( aptp_is_userns_root() { return 0; }
    CLAUDE_EGRESS_LOCKDOWN=1 CLAUDE_APT_MANIFEST_FILE="$1" \
        APTP_FIREWALL="$fwstub" APTP_APT="$aptstub" aptp_provision )
if run_provision_man "$emptyman" >/dev/null 2>&1 && [[ ! -s "$fwlog" && ! -s "$aptlog" ]]; then
    ok "empty (comments-only) manifest = true no-op: rc 0, no egress window, no apt install"
else
    bad "empty-manifest provision was NOT a no-op — fw=[$(tr '\n' '|' <"$fwlog")] apt=[$(cat "$aptlog")] rc=$?"
fi
# an EXPLICIT missing manifest override through full provision = REFUSE (rc 2), and
# crucially no egress window opened and no apt install (fail closed, no partial trust).
: >"$fwlog"; : >"$aptlog"
if run_provision_man "$TMP/does-not-exist.txt" >/dev/null 2>&1; then
    bad "explicit missing manifest override should REFUSE through full provision"
elif [[ ! -s "$fwlog" && ! -s "$aptlog" ]]; then
    ok "explicit missing manifest = refuse through full provision (no window, no install)"
else
    bad "missing-override provision touched the firewall/apt: fw=[$(cat "$fwlog")] apt=[$(cat "$aptlog")]"
fi

# egress lockdown OFF ⇒ the window is a no-op (no firewall calls), install still runs
: >"$fwlog"; : >"$aptlog"
( aptp_is_userns_root() { return 0; }
  CLAUDE_EGRESS_LOCKDOWN=0 CLAUDE_APT_MANIFEST_FILE="$man" \
      APTP_FIREWALL="$fwstub" APTP_APT="$aptstub" aptp_provision >/dev/null 2>&1 )
if [[ ! -s "$fwlog" ]] && grep -q 'apt install' "$aptlog"; then
    ok "egress lockdown off: no firewall change, install still runs (fail-safe)"
else
    bad "lockdown-off path touched the firewall or skipped install: fw=$(cat "$fwlog")"
fi

# ---- --check dry-run: prints the plan, touches NOTHING -------------------------------------------
: >"$fwlog"; : >"$aptlog"
chk="$(CLAUDE_APT_MANIFEST_FILE="$man" APTP_FIREWALL="$fwstub" APTP_APT="$aptstub" bash "$SCRIPT" --check 2>/dev/null)"
if grep -q '^tier:' <<<"$chk" && grep -q 'libpq5=15.10-0+deb12u1' <<<"$chk" && [[ ! -s "$fwlog" && ! -s "$aptlog" ]]; then
    ok "--check prints tier + plan and runs no firewall/apt"
else
    bad "--check wrong or had side effects: $chk"
fi

# ---- firewall CLAUDE_EGRESS_APT profile: additive, off by default --------------------------------
base="$(CLAUDE_EGRESS_PRINT_HOSTS=1 "$FIREWALL" 2>/dev/null)"
withapt="$(CLAUDE_EGRESS_APT=1 CLAUDE_EGRESS_PRINT_HOSTS=1 "$FIREWALL" 2>/dev/null)"
if ! grep -q 'deb.debian.org' <<<"$base"; then
    ok "firewall: debian mirrors absent by default (leaf never reaches them)"
else
    bad "firewall leaked debian mirrors with the apt profile OFF"
fi
if grep -q 'deb.debian.org' <<<"$withapt" && grep -q 'security.debian.org' <<<"$withapt"; then
    ok "firewall: CLAUDE_EGRESS_APT=1 adds deb.debian.org + security.debian.org"
else
    bad "firewall apt profile did not add the debian mirrors"
fi
# additive: every default host survives with the profile on
missing=""; while read -r h; do [[ -z "$h" ]] && continue; grep -qx "$h" <<<"$withapt" || missing+="$h "; done <<<"$base"
[[ -z "$missing" ]] && ok "firewall apt profile is purely additive (no default host dropped)" || bad "apt profile dropped hosts: $missing"

# ---- wiring: entrypoint hook, broker passthrough (off-by-default), Dockerfile bake ---------------
grep -q 'claude-apt-provision' "$REPO_ROOT/entrypoint.sh" \
    && grep -q 'CLAUDE_APT_PROVISION' "$REPO_ROOT/entrypoint.sh" \
    && ok "entrypoint runs claude-apt-provision under CLAUDE_APT_PROVISION" || bad "entrypoint hook missing"
# entrypoint distinguishes a benign leaf no-op (rc 3) from a REAL failure, and warns
# when provisioning is on but egress lockdown is off (apt over open egress).
grep -q 'apt_rc == 3' "$REPO_ROOT/entrypoint.sh" && grep -q 'apt_rc=' "$REPO_ROOT/entrypoint.sh" \
    && ok "entrypoint distinguishes leaf-refusal (rc 3) from a real install failure" || bad "entrypoint conflates rc 3 with failure"
grep -q 'without CLAUDE_EGRESS_LOCKDOWN' "$REPO_ROOT/entrypoint.sh" \
    && ok "entrypoint warns on CLAUDE_APT_PROVISION without egress lockdown" || bad "entrypoint missing the incoherent-config warning"
grep -q 'CLAUDE_APT_PROVISION' "$REPO_ROOT/bin/claude-worker-broker" \
    && ok "broker passes CLAUDE_APT_PROVISION into the worker template" || bad "broker passthrough missing"
# the broker must NOT forward CLAUDE_APT_MANIFEST_FILE (a worker-internal path; a
# broker-host path would silently no-op in the worker).
grep -q 'printf.*CLAUDE_APT_MANIFEST_FILE=' "$REPO_ROOT/bin/claude-worker-broker" \
    && bad "broker forwards CLAUDE_APT_MANIFEST_FILE (host path would silently no-op in the worker)" \
    || ok "broker does NOT forward CLAUDE_APT_MANIFEST_FILE (baked worker path only)"
grep -q 'COPY bin/claude-apt-provision' "$REPO_ROOT/Dockerfile" \
    && grep -q '/usr/local/bin/claude-apt-provision' "$REPO_ROOT/Dockerfile" \
    && ok "Dockerfile bakes + chmods claude-apt-provision" || bad "Dockerfile does not bake the provisioner"
[[ -f "$REPO_ROOT/claude-config/apt-manifest.txt" ]] \
    && ok "curated manifest file present (baked via claude-config/)" || bad "curated manifest file missing"

echo
echo "PKG-4: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
