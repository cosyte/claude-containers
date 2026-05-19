#!/usr/bin/env bash
# Self-test for bin/claude-compose-gen. No Docker / gh / OAuth needed — it
# only exercises the pure generation logic, so it runs in CI's lint job and
# locally in seconds. Guards the SSH-port contract (a same-port collision on
# fresh generation shipped once — see CHANGELOG) and GH_TOKEN passthrough.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEN="$ROOT/bin/claude-compose-gen"
TMP="$(mktemp -d)"
OUT="$TMP/compose.yml"
trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

gen() {  # generate with dummy host key paths so it never touches ~/.ssh
    SSH_AUTHORIZED_KEYS=/dev/null GIT_SSH_KEY=/dev/null \
        bash "$GEN" --out "$OUT" "$@" >/dev/null 2>&1
}
# svc -> host SSH port, from the emitted "NNNN:22" mappings keyed by service.
ports() { awk '
    /^  [a-z0-9._-]+:$/      { s=$1; sub(/:$/,"",s) }
    /^      - "[0-9]+:22"$/  { p=$2; gsub(/[^0-9:]/,"",p); sub(/:22$/,"",p);
                               if (s!="") print s"="p }' "$OUT"; }

echo "== compose-gen self-test =="

# 1. Fresh generation must give every repo a DISTINCT host port.
gen alpha bravo charlie
mapfile -t P < <(ports)
hp="$(printf '%s\n' "${P[@]}" | cut -d= -f2 | sort)"
if [[ "$(wc -l <<<"$hp")" -eq 3 && "$(uniq <<<"$hp" | wc -l)" -eq 3 ]]; then
    ok "fresh: 3 repos -> 3 distinct ports ($(paste -sd, <<<"$hp"))"
else
    bad "fresh: expected 3 distinct ports, got: ${P[*]}"
fi

# 2. Regeneration: surviving repos keep their exact port; new repo is distinct.
# port_of <svc> <ports-dump> — empty (not a set -e abort) if the svc is absent.
port_of() { grep -oP "(?<=^$1=)\\d+" <<<"$2" || true; }
before="$(ports)"
a_port="$(port_of alpha "$before")"
c_port="$(port_of charlie "$before")"
gen alpha charlie delta            # drop bravo, add delta
after="$(ports)"
a_now="$(port_of alpha "$after")"; c_now="$(port_of charlie "$after")"
d_port="$(port_of delta "$after")"
[[ -n "$a_port" && "$a_now" == "$a_port" ]] \
    && ok "regen: alpha keeps port $a_port" \
    || bad "regen: alpha port moved ($a_port -> $a_now)"
[[ -n "$c_port" && "$c_now" == "$c_port" ]] \
    && ok "regen: charlie keeps port $c_port" \
    || bad "regen: charlie port moved ($c_port -> $c_now)"
[[ -n "$d_port" && "$d_port" != "$a_port" && "$d_port" != "$c_port" ]] \
    && ok "regen: new repo delta gets a distinct port ($d_port)" \
    || bad "regen: delta port missing or colliding ($d_port)"

# 3. Every service forwards GH_TOKEN from the deploy environment, verbatim.
n_svc="$(grep -cE '^    container_name: claude-' "$OUT" || true)"
n_tok="$(grep -cF 'GH_TOKEN: "${GH_TOKEN:-}"' "$OUT" || true)"
[[ "$n_svc" -gt 0 && "$n_tok" -eq "$n_svc" ]] \
    && ok "GH_TOKEN passthrough present in all $n_svc services" \
    || bad "GH_TOKEN passthrough: $n_tok of $n_svc services"

echo "== PASS:$PASS FAIL:$FAIL =="
[[ "$FAIL" -eq 0 ]]
