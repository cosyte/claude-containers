#!/usr/bin/env bash
# Unit tests for claude-compose-gen's scenario/env-file surface — NO docker,
# NO gh, NO root. Covers:
#   - .conf expansion: one "--flag [value]" per line, literal rest-of-line
#     value (spaces/;/$/= need no quoting), full-line # comments skipped,
#     inline # preserved, blank lines skipped, bare boolean flags.
#   - CLI-after-scenario precedence: scalars override, repeatables append.
#   - CLAUDE_ENV_FILE layering: a scenario env override drives baked literals
#     AND the derived mem_reservation; a set-but-missing env fails closed.
#   - Cross-stack port reservation via the CLAUDE_PORTS_USED_OVERRIDE seam.
# The generator's docker calls are all warn-only / `|| true`, so it runs fully
# on a hosted runner. CLAUDE_PORTS_USED_OVERRIDE is set (often empty) in every
# generating test so a live docker on a dev box can't skew port assignment.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEN="$REPO_ROOT/bin/claude-compose-gen"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

# Run the generator with a clean, deterministic environment: no live docker
# port list (empty seam), a pinned image, quiet. Args are passed through.
gen() { env CLAUDE_PORTS_USED_OVERRIDE= "$GEN" "$@" >/dev/null 2>&1; }

# --- .conf expansion + per-repo flags -----------------------------------------------------
echo "== .conf expansion: flags + repos, verbatim values =="

ENVF="$TMPD/s.env"
cat > "$ENVF" <<EOF
SSH_PORT_RANGE_START=3900
SSH_PORT_RANGE_END=3910
CLAUDE_MEM_LIMIT=8g
EOF

OUT="$TMPD/a/dc.yml"
CONF="$TMPD/a.conf"
# Note the deliberately gnarly --dev-cmd (spaces, ;, $, --) and an inline # in a
# marketplace value; a full-line comment; a blank line; a bare --forks.
cat > "$CONF" <<EOF
# a full-line comment — skipped

--env-file $ENVF
--out $OUT
--port-base 3900
--active alpha
--expose alpha:4321:4321
--dev-cmd alpha=if [ -f pnpm-lock.yaml ]; then PM=pnpm; else PM=npm; fi; exec \$PM run dev -- --host 0.0.0.0 --port 4321
--browser alpha
--forks
--marketplace beta=mkt=https://example.com/r.git#frag
myorg/alpha
myorg/beta:dev
EOF

if gen --scenario "$CONF"; then
    devline="$(grep 'CLAUDE_DEV_CMD:' "$OUT")"
    # In compose, a literal $ is emitted as $$ (so the value is preserved, not interpolated).
    want='CLAUDE_DEV_CMD: "if [ -f pnpm-lock.yaml ]; then PM=pnpm; else PM=npm; fi; exec $$PM run dev -- --host 0.0.0.0 --port 4321"'
    [[ "$devline" == *"$want"* ]] && ok "--dev-cmd survives verbatim (spaces/;/\$/-- intact)" \
        || bad "--dev-cmd not verbatim: $devline"
    grep -q 'image: claude-code-box:browser' "$OUT" && ok "--browser selects the browser image" \
        || bad "--browser should switch the image"
    grep -q '"4321:4321"' "$OUT" && ok "--expose publishes the port" || bad "--expose missing"
    # Regression: the expose port must sit INSIDE the ports: block (after
    # `ports:`, before `security_opt:`), NOT after cap_add — otherwise YAML
    # parses the mapping as a bogus capability and the port isn't published.
    ab="$(awk '/^  alpha:/{f=1} f&&/^  beta:/{exit} f' "$OUT")"
    lp="$(grep -n '^    ports:$'        <<<"$ab" | head -1 | cut -d: -f1)"
    le="$(grep -n '"4321:4321"'         <<<"$ab" | head -1 | cut -d: -f1)"
    ls="$(grep -n '^    security_opt:$' <<<"$ab" | head -1 | cut -d: -f1)"
    if [[ -n "$lp" && -n "$le" && -n "$ls" && "$lp" -lt "$le" && "$le" -lt "$ls" ]]; then
        ok "--expose port lands under ports: (not parsed as a capability)"
    else
        bad "--expose port must be between ports: and security_opt: (ports=$lp expose=$le sec=$ls)"
    fi
    grep -q 'GIT_REPO_BRANCH: "dev"' "$OUT" && ok "repo:branch arg parsed (beta:dev)" \
        || bad "beta branch not parsed"
    grep -q 'example.com/r.git#frag' "$OUT" && ok "inline # in a value is preserved (not a comment)" \
        || bad "inline # was mangled"
    grep -q 'claude.ssh_port: "3900"' "$OUT" && ok "--port-base honored (alpha=3900)" \
        || bad "port-base not honored"
else
    bad "generation from a scenario failed"
fi

# Bare --forks must not inject a spurious empty positional (which would become an
# empty repo arg). We can't see forks directly, but a broken parse would have
# added a phantom service; assert exactly the two intended services exist.
if [[ -f "$OUT" ]]; then
    n="$(grep -c 'container_name: claude-' "$OUT")"
    [[ "$n" -eq 2 ]] && ok "bare --forks adds no phantom arg (exactly 2 services)" \
        || bad "expected 2 services, got $n (bare-flag parse leaked?)"
fi

# --- env-file layering drives literals + derived reservation ------------------------------
echo
echo "== CLAUDE_ENV_FILE layering: overrides baked literals + derived reservation =="
if [[ -f "$OUT" ]]; then
    # Base .env would give 16g; the scenario env set 8g → mem_limit 8g and the
    # derived reservation 6144m (75%). If the env layered too late, reservation
    # would be stale (12288m from 16g).
    grep -q 'mem_limit: 8g' "$OUT" && ok "scenario env overrides mem_limit (8g)" \
        || bad "mem_limit should be 8g from the scenario env"
    grep -q 'mem_reservation: 6144m' "$OUT" \
        && ok "derived mem_reservation tracks the override (6144m = 75% of 8g)" \
        || bad "mem_reservation should be 6144m (derivation saw the override), got: $(grep mem_reservation "$OUT" | head -1)"
fi

# --- CLI after --scenario overrides scalars, appends repeatables --------------------------
echo
echo "== CLI-after-scenario precedence =="
OUT2="$TMPD/b/dc.yml"
if gen --scenario "$CONF" --out "$OUT2" --active beta --dormant-profile paused; then
    # Both alpha (scenario) and beta (CLI-appended) are active → NO profiles emitted.
    if ! grep -q 'profiles:' "$OUT2"; then
        ok "--active appends (alpha+beta both active → no dormant profiles)"
    else
        bad "--active should have appended beta, leaving nothing dormant"
    fi
    # Scalar --out overrode the scenario's --out (we wrote to OUT2, and OUT is stale).
    [[ -f "$OUT2" ]] && ok "--out scalar override wins (wrote to the CLI path)" \
        || bad "--out override did not take effect"
    # The (unused) dormant-profile scalar override still shows in the header text.
    grep -q -- '--profile paused' "$OUT2" && ok "--dormant-profile scalar override wins" \
        || bad "--dormant-profile override not applied"
else
    bad "CLI-override generation failed"
fi

# --- --all-dormant puts every service behind the dormant profile --------------------------
echo
echo "== --all-dormant: every service dormant, none active =="
OUTD="$TMPD/d/dc.yml"
if env CLAUDE_PORTS_USED_OVERRIDE= "$GEN" --env-file "$ENVF" --out "$OUTD" \
    --port-base 3900 --all-dormant z/one z/two >/dev/null 2>&1; then
    nsvc="$(grep -c 'container_name: claude-' "$OUTD")"
    nprof="$(grep -c '^    profiles:$' "$OUTD")"
    [[ "$nsvc" -eq 2 && "$nprof" -eq 2 ]] \
        && ok "--all-dormant marks all services dormant ($nprof/$nsvc behind the profile)" \
        || bad "--all-dormant should put every service behind the profile (svc=$nsvc prof=$nprof)"
else
    bad "--all-dormant generation failed"
fi

# --- --network attaches services to a shared external network -----------------------------
echo
echo "== --network: shared external default network =="
OUTN="$TMPD/n/dc.yml"
if env CLAUDE_PORTS_USED_OVERRIDE= "$GEN" --env-file "$ENVF" --out "$OUTN" \
    --port-base 3900 --network claude z/one >/dev/null 2>&1; then
    if python3 - "$OUTN" <<'PY'
import yaml,sys
d=yaml.safe_load(open(sys.argv[1]))
n=d.get("networks",{}).get("default",{})
sys.exit(0 if (n.get("name")=="claude" and n.get("external") is True) else 1)
PY
    then ok "--network emits an external default network (name: claude)"
    else bad "--network should emit networks.default {name: claude, external: true}"; fi
    # Absent --network → no networks: block (backward compatible).
    grep -q '^networks:' "$OUT" && bad "no --network should emit no networks: block" \
        || ok "no --network → no networks: block (backward compatible)"
else
    bad "--network generation failed"
fi

# --- fail-closed paths --------------------------------------------------------------------
echo
echo "== fail-closed: missing env / scenario / value =="

badconf="$TMPD/bad.conf"
printf -- '--env-file /no/such/file.env\n--out %s/x.yml\nz/z\n' "$TMPD" > "$badconf"
gen --scenario "$badconf" && bad "missing --env-file in .conf should fail" \
    || ok "missing --env-file (in .conf) fails closed"

gen --scenario "$TMPD/nope.conf" && bad "missing scenario file should fail" \
    || ok "missing scenario file fails closed"

gen --scenario && bad "--scenario with no value should fail" \
    || ok "--scenario with no value fails closed"

# CLAUDE_ENV_FILE set directly (not via the generator) to a missing path: the
# _common.sh layer must refuse for ANY tool that sources it.
if env CLAUDE_ENV_FILE=/no/such.env bash -c "source '$REPO_ROOT/bin/_common.sh'" >/dev/null 2>&1; then
    bad "a set-but-missing CLAUDE_ENV_FILE must fail closed in _common.sh"
else
    ok "set-but-missing CLAUDE_ENV_FILE fails closed (fleet-wide)"
fi

# --- cross-stack port reservation via the seam --------------------------------------------
echo
echo "== cross-stack port reservation (CLAUDE_PORTS_USED_OVERRIDE seam) =="
OUT3="$TMPD/c/dc.yml"
# Pretend another stack / a standalone container already holds 3900 and 3902.
if env CLAUDE_PORTS_USED_OVERRIDE="3900 3902" "$GEN" \
    --env-file "$ENVF" --out "$OUT3" --port-base 3900 z/one z/two z/three >/dev/null 2>&1; then
    got="$(grep 'claude.ssh_port:' "$OUT3" | grep -oE '[0-9]+' | sort -n | tr '\n' ' ')"
    # 3900 and 3902 are reserved → the three repos take 3901, 3903, 3904.
    [[ "$got" == "3901 3903 3904 " ]] \
        && ok "new repos skip in-use cross-stack ports (got: $got)" \
        || bad "expected '3901 3903 3904', got '$got'"
else
    bad "port-seeding generation failed"
fi

# --- summary ------------------------------------------------------------------------------
echo
echo "compose-gen-unit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
