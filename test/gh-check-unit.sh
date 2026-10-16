#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables set in subshells are read by the entrypoint blocks run with eval
# Unit tests for the GitHub token check: NO docker, NO root, NO network.
#
#   - bin/claude-gh-check against a fake curl on PATH returning scripted codes: every
#     permission held, each one missing, offline (skipped, exit 0), no GH_TOKEN (no call),
#     the repos it finds (ssh and https remotes, a non-GitHub one skipped, duplicates once)
#   - by source: it never names a merge endpoint, never sends a body, never puts the token
#     in argv, never calls gh
#   - entrypoint.sh §12f: writes the result world-readable, warns per missing permission,
#     removes a stale result without GH_TOKEN
# shellcheck source=test/lib/prelude.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/prelude.sh"
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/lib/entrypoint.sh
source "$REPO_ROOT/test/lib/entrypoint.sh"
ENTRY="$REPO_ROOT/entrypoint.sh"
CHECK="$REPO_ROOT/bin/claude-gh-check"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

# The fake curl: logs "<METHOD> <URL> | <argv>" per call and prints the code a FAKE_* env
# var scripts for that probe (default: the "held" code).
FAKE="$TMPD/fake"; mkdir -p "$FAKE"; CALLS="$TMPD/calls"
cat > "$FAKE/curl" <<'EOF'
#!/usr/bin/env bash
m=GET url=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
    [[ "${args[i]}" == -X ]] && m="${args[i+1]}"
    [[ "${args[i]}" == https://* ]] && url="${args[i]}"
done
echo "$m $url | $*" >> "$FAKE_CALLS"
case "$m $url" in
    "GET "*/check-runs*) printf '%s' "${FAKE_CHECKS:-200}" ;;
    "PUT "*/contents/*)  printf '%s' "${FAKE_PUT:-400}" ;;
    "POST "*/pulls)      printf '%s' "${FAKE_POST:-422}" ;;
    "GET "*)             printf '%s' "${FAKE_READ:-200}" ;;
    *)                   printf '000' ;;
esac
EOF
chmod +x "$FAKE/curl"

# A /workspace with: an ssh remote, an https remote, the ssh one's twin, a non-GitHub one,
# and a plain directory.
WS="$TMPD/ws"; mkdir -p "$WS/plain"
mkrepo() { git init -q "$WS/$1" && git -C "$WS/$1" remote add origin "$2"; }
mkrepo alpha git@github.com:me/alpha.git
mkrepo beta https://github.com/myorg/beta
mkrepo alpha2 ssh://git@github.com/me/alpha.git
mkrepo other git@gitlab.com:me/other.git
mkrepo gamma https://github.com/me/gamma/
mkrepo odd 'https://github.com/me/x#frag'

run() {  # run [ENV=VAL ...]: claude-gh-check against the sandbox; output in $out, code in $rc
    : > "$CALLS"
    out="$(env PATH="$FAKE:$PATH" FAKE_CALLS="$CALLS" CLAUDE_GH_CHECK_ROOT="$WS" GH_TOKEN=tok-secret-123 "$@" \
        bash "$CHECK" 2>&1)"; rc=$?
}

# ======================================================================================
echo "== claude-gh-check =="
run
(( rc == 0 )) && ok "exits 0" || bad "exit $rc"
[[ "$(grep -c '^github ' <<<"$out")" == 3 ]] \
    && grep -qxF 'github me/alpha: read ok, contents-write ok, pr ok, checks ok' <<<"$out" \
    && grep -qxF 'github myorg/beta: read ok, contents-write ok, pr ok, checks ok' <<<"$out" \
    && grep -qxF 'github me/gamma: read ok, contents-write ok, pr ok, checks ok' <<<"$out" \
    && ! grep -qF 'frag' "$CALLS" \
    && ok "all held: one ok line per github.com repo (ssh, https, trailing slash; twin once; gitlab and a malformed slug skipped)" \
    || bad "all held: $out"
grep -qF 'GET https://api.github.com/repos/me/alpha ' "$CALLS" \
    && grep -qF 'PUT https://api.github.com/repos/me/alpha/contents/.claude-gh-check ' "$CALLS" \
    && grep -qF 'POST https://api.github.com/repos/me/alpha/pulls ' "$CALLS" \
    && grep -qF 'GET https://api.github.com/repos/me/alpha/commits/HEAD/check-runs?per_page=1 ' "$CALLS" \
    && ok "probes the four documented endpoints" || bad "calls: $(cat "$CALLS")"
grep -q 'tok-secret-123' "$CALLS" && bad "the token is in curl's argv" || ok "the token never reaches argv"
grep -q -- '--max-time 5' "$CALLS" && ok "every call is capped at 5s" || bad "no --max-time 5"

run FAKE_PUT=403
grep -qxF 'github me/alpha: read ok, contents-write NO, pr ok, checks ok' <<<"$out" \
    && ok "contents 403: contents-write NO" || bad "contents 403: $out"
run FAKE_PUT=404
grep -qF 'contents-write NO' <<<"$out" && ok "contents 404: contents-write NO" || bad "contents 404: $out"
run FAKE_POST=403
grep -qxF 'github me/alpha: read ok, contents-write ok, pr NO, checks ok' <<<"$out" \
    && ok "pulls 403: pr NO" || bad "pulls 403: $out"
run FAKE_CHECKS=403
grep -qxF 'github me/alpha: read ok, contents-write ok, pr ok, checks NO' <<<"$out" \
    && ok "check-runs 403: checks NO" || bad "checks 403: $out"
run FAKE_READ=404
(( rc == 0 )) && grep -qxF 'github me/alpha: read NO (HTTP 404)' <<<"$out" \
    && ! grep -q '^PUT\|^POST' "$CALLS" \
    && ok "no read access: read NO, and no further probe" || bad "read 404: $out / $(cat "$CALLS")"
run FAKE_PUT=429
grep -qF 'contents-write ?429' <<<"$out" && ok "a rate limit (429) reads ?429, never ok" || bad "contents 429: $out"
run FAKE_PUT=422 FAKE_POST=400
grep -qxF 'github me/alpha: read ok, contents-write ok, pr ok, checks ok' <<<"$out" \
    && ok "contents 422 and pulls 400 also read held" || bad "422/400: $out"
run FAKE_POST=500
grep -qF 'pr ?500' <<<"$out" && ok "an unexpected code reads ?<code>, not ok" || bad "pulls 500: $out"

run FAKE_READ=000
(( rc == 0 )) && [[ "$out" == "github: skipped (offline or timeout)" ]] \
    && [[ "$(wc -l < "$CALLS")" == 1 ]] \
    && ok "offline: skipped, exit 0, stops after the first call" || bad "offline (rc=$rc): $out"
run FAKE_CHECKS=000
(( rc == 0 )) && [[ "$out" == "github: skipped (offline or timeout)" ]] \
    && ok "a timeout mid-way: skipped, exit 0" || bad "timeout (rc=$rc): $out"

: > "$CALLS"
out="$(env -u GH_TOKEN PATH="$FAKE:$PATH" FAKE_CALLS="$CALLS" CLAUDE_GH_CHECK_ROOT="$WS" bash "$CHECK")"; rc=$?
(( rc == 0 )) && [[ "$out" == "github: skipped (no GH_TOKEN)" ]] && [[ ! -s "$CALLS" ]] \
    && ok "no GH_TOKEN: skipped, exit 0, no call made" || bad "no token (rc=$rc): $out / $(cat "$CALLS")"

EMPTY="$TMPD/empty"; mkdir -p "$EMPTY"
run CLAUDE_GH_CHECK_ROOT="$EMPTY"
(( rc == 0 )) && grep -qF 'skipped (no github.com repo' <<<"$out" && [[ ! -s "$CALLS" ]] \
    && ok "no github.com repo: skipped, no call" || bad "empty root: $out"

# ======================================================================================
echo "== claude-gh-check by source =="
if command -v rg >/dev/null 2>&1; then GREP=(rg -n); else GREP=(grep -nE); fi
"${GREP[@]}" '/merge' "$CHECK" >/dev/null && bad "names /merge (an empty-body merge call merges)" \
    || ok "never names /merge"
"${GREP[@]}" -- '(^|[[:space:]])(-d|--data[a-z-]*|--json|-F|--form|-T|--upload-file)([[:space:]='"'"'"$@{]|$)' "$CHECK" >/dev/null \
    && bad "sends a body (-d/--data/--json/-F/-T)" || ok "never sends a body"
"${GREP[@]}" '(^|[[:space:];(|&])gh[[:space:]]' "$CHECK" >/dev/null \
    && bad "calls gh" || ok "never calls gh (curl only)"

# ======================================================================================
echo "== entrypoint.sh §12f =="
B12F="$(awk '/^# --- 12f\. GitHub token check/{f=1; print; next} f' "$(ep_section 12f)")"
grep -qE '^GH_CHECK_FILE=' <<<"$B12F" && grep -qE '^GH_CHECK_CMD=' <<<"$B12F" \
    && ok "§12f names GH_CHECK_FILE and GH_CHECK_CMD on their own lines" \
    || bad "§12f must assign GH_CHECK_FILE and GH_CHECK_CMD on their own lines"
GHF="$TMPD/run/claude/gh-check.txt"
run_12f() {  # run_12f <GH_TOKEN> <fake check output>
    printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$2" > "$TMPD/fake-check"; chmod +x "$TMPD/fake-check"
    local blk; blk="$(sed -e "s#^GH_CHECK_FILE=.*#GH_CHECK_FILE=\"$GHF\"#" \
        -e "s#^GH_CHECK_CMD=.*#GH_CHECK_CMD=\"$TMPD/fake-check\"#" <<<"$B12F")"
    ( log() { echo "[entrypoint] $*"; }; asclaude() { "$@"; }; set -euo pipefail
      GH_TOKEN="$1"; eval "$blk"; wait )
}
out="$(run_12f tok 'github me/alpha: read ok, contents-write ok, pr ok, checks ok')"; rc=$?
(( rc == 0 )) && grep -qxF 'github me/alpha: read ok, contents-write ok, pr ok, checks ok' "$GHF" \
    && [[ "$(stat -c %a "$GHF")" == 644 ]] && ! grep -q WARNING <<<"$out" \
    && ok "all held: result written 644, no warning" || bad "§12f held (rc=$rc): $out"
out="$(run_12f tok 'github me/alpha: read ok, contents-write NO, pr NO, checks ok')"
[[ "$(grep -c 'WARNING: GH_TOKEN is missing a permission: github me/alpha' <<<"$out")" == 1 ]] \
    && ok "a missing permission: one WARNING line for the repo" || bad "§12f warn: $out"
out="$(run_12f "" 'unused')"; rc=$?
(( rc == 0 )) && [[ ! -e "$GHF" ]] && ok "no GH_TOKEN: stale result removed, nothing runs" || bad "§12f no token: $out"

# ======================================================================================
echo "== image wiring =="
grep -q 'COPY bin/claude-gh-check /usr/local/bin/claude-gh-check' "$REPO_ROOT/Dockerfile" \
    && ok "the check is baked" || bad "the Dockerfile must COPY bin/claude-gh-check"
bash -n "$ENTRY" && ok "entrypoint.sh parses" || bad "entrypoint.sh has a syntax error"

echo
echo "gh-check-unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
