#!/usr/bin/env bash
# Unit tests for bin/claude-image-rebuild: NO docker, NO network. Fake git, docker and make
# on PATH answer from files a case writes and log what they were asked:
#   - --check: an image at main (behind 0), one behind (behind N), an unlabelled one (behind
#     null), a missing image (exit 2)
#   - rebuild: a dirty checkout and one not on main are refused (exit 3) before any pull or
#     build; a browser-labelled image builds with build-browser, a lean one with build;
#     --dry-run runs neither
#   - the script never recreates, restarts or removes a container and never prunes
# shellcheck source=test/lib/prelude.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/prelude.sh"
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/bin/claude-image-rebuild"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

# The fakes read their answers from $F (one file per answer) and append each call to $F/log.
F="$TMPD/f"; FAKES="$TMPD/bin"; mkdir -p "$F" "$FAKES"
cat > "$FAKES/git" <<'EOF'
#!/usr/bin/env bash
echo "git $*" >> "$F/log"
[[ "$1" == -C ]] && shift 2
case "$1" in
    fetch)      exit "$(cat "$F/fetch_rc" 2>/dev/null || echo 0)" ;;
    status)     cat "$F/status" 2>/dev/null; exit 0 ;;
    rev-parse)  case "$2" in
                    origin/main)  echo "$MAIN" ;;
                    --abbrev-ref) cat "$F/branch" ;;
                esac ;;
    cat-file)   [[ -f "$F/known" ]] && grep -qxF "${3%^\{commit\}}" "$F/known" ;;
    rev-list)   cat "$F/behind" ;;
    pull)       exit 0 ;;
    *)          exit 1 ;;
esac
EOF
cat > "$FAKES/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$F/log"
[[ "$1 $2" == "image inspect" && -f "$F/labels" ]] || exit 1
cat "$F/labels"
EOF
cat > "$FAKES/make" <<'EOF'
#!/usr/bin/env bash
echo "make $*" >> "$F/log"
[[ -f "$F/labels.after" ]] && cp "$F/labels.after" "$F/labels"
exit 0
EOF
chmod +x "$FAKES"/*
export F

MAIN=1111111111111111111111111111111111111111
OLD=2222222222222222222222222222222222222222
reset() { rm -rf "$F"; mkdir -p "$F"; : > "$F/log"; echo main > "$F/branch"; }
run() { PATH="$FAKES:$PATH" MAIN="$MAIN" "$SCRIPT" "$@" 2>"$TMPD/err"; }

# ======================================================================================
echo "== --check =="
reset; echo "$MAIN|false|2.1.293|0" > "$F/labels"; echo "$MAIN" > "$F/known"; echo 0 > "$F/behind"
out="$(run --check --image t:1)"; rc=$?
(( rc == 0 )) && ok "current: exit 0" || bad "current: exit $rc"
[[ "$out" == "{\"image\":\"t:1\",\"revision\":\"$MAIN\",\"dirty\":false,\"cli_version\":\"2.1.293\",\"main\":\"$MAIN\",\"behind\":0,\"checkout_clean\":true}" ]] \
    && ok "current: the JSON line, behind 0" || bad "current: $out"
grep -q '^git .*fetch' "$F/log" && ok "it fetches first" || bad "no fetch: $(cat "$F/log")"
command -v jq >/dev/null && { jq -e . <<<"$out" >/dev/null && ok "valid JSON" || bad "not JSON: $out"; }

reset; echo "$OLD|true|2.1.200|0" > "$F/labels"; echo "$OLD" > "$F/known"; echo 7 > "$F/behind"
echo " M Makefile" > "$F/status"
out="$(run --check --image t:1)"; rc=$?
(( rc == 0 )) && ok "behind: exit 0" || bad "behind: exit $rc"
grep -qF '"behind":7' <<<"$out" && grep -qF "\"revision\":\"$OLD\"" <<<"$out" \
    && grep -qF '"dirty":true' <<<"$out" && grep -qF '"cli_version":"2.1.200"' <<<"$out" \
    && ok "behind: the count past the image's revision" || bad "behind: $out"
grep -qF '"checkout_clean":false' <<<"$out" && ok "a checkout with changes reads not clean" || bad "clean: $out"

reset; echo "|||" > "$F/labels"; echo 3 > "$F/behind"
out="$(run --check --image t:1)"; rc=$?
(( rc == 0 )) && ok "unlabelled: exit 0" || bad "unlabelled: exit $rc"
grep -qF '"revision":"unknown"' <<<"$out" && grep -qF '"behind":null' <<<"$out" \
    && grep -qF '"dirty":null' <<<"$out" && grep -qF '"cli_version":"unknown"' <<<"$out" \
    && ok "unlabelled: unknown revision, behind null" || bad "unlabelled: $out"
! grep -q 'rev-list' "$F/log" && ok "unlabelled: never counts from an unknown commit" || bad "counted"

reset; echo "$OLD|false|2.1.200|0" > "$F/labels"; echo 3 > "$F/behind"
out="$(run --check --image t:1)"
grep -qF '"behind":null' <<<"$out" && ok "a revision not in this checkout: behind null" || bad "unknown commit: $out"

reset; echo 1 > "$F/fetch_rc"; echo "$MAIN|false|2.1.293|0" > "$F/labels"; echo "$MAIN" > "$F/known"; echo 0 > "$F/behind"
out="$(run --check --image t:1)"; rc=$?
(( rc == 0 )) && grep -qF '"behind":0' <<<"$out" && grep -q 'fetch failed' "$TMPD/err" \
    && ok "a failed fetch warns and still answers" || bad "fetch failed: rc $rc $out"

reset
run --check --image t:none >/dev/null; rc=$?
(( rc == 2 )) && ok "no such image: exit 2" || bad "no image: exit $rc"

reset; echo "$MAIN|false|2.1.293|0" > "$F/labels"; echo 0 > "$F/behind"
run --check >/dev/null
grep -qF 'docker image inspect' "$F/log" && grep -qF 'claude-code-box:latest' "$F/log" \
    && ok "default image: the Makefile's CLAUDE_IMAGE" || bad "default: $(grep docker "$F/log")"

# ======================================================================================
echo "== rebuild =="
reset; echo "$OLD|false|2.1.200|0" > "$F/labels"; echo " M x" > "$F/status"
run --image t:1 >/dev/null; rc=$?
(( rc == 3 )) && grep -qF 'has changes' "$TMPD/err" && ok "a dirty checkout: refused, exit 3" || bad "dirty: exit $rc"
! grep -qE '^(git .*pull|make )' "$F/log" && ok "dirty: no pull, no build" || bad "dirty ran: $(cat "$F/log")"

reset; echo "$OLD|false|2.1.200|0" > "$F/labels"; echo feat/x > "$F/branch"
run --image t:1 >/dev/null; rc=$?
(( rc == 3 )) && grep -qF "not main" "$TMPD/err" && ok "not on main: refused, exit 3" || bad "branch: exit $rc"
! grep -qE '^(git .*pull|make )' "$F/log" && ok "not on main: no pull, no build" || bad "branch ran: $(cat "$F/log")"

reset; echo "$OLD|false|2.1.200|1" > "$F/labels"; echo "$MAIN|false|2.1.293|1" > "$F/labels.after"
out="$(run --image t:b)"; rc=$?
(( rc == 0 )) && ok "browser image: exit 0" || bad "browser: exit $rc $(cat "$TMPD/err")"
grep -qE '^make .*build-browser CLAUDE_IMAGE_BROWSER=t:b$' "$F/log" \
    && ok "a claude.browser=1 image builds with build-browser, same tag" || bad "browser: $(grep make "$F/log")"
grep -n '' "$F/log" | grep -E 'pull|make' | head -n 1 | grep -q pull \
    && ok "pulls before it builds" || bad "order: $(cat "$F/log")"
grep -qF "revision: $OLD -> $MAIN" <<<"$out" && grep -qF 'cli:      2.1.200 -> 2.1.293' <<<"$out" \
    && ok "prints the old and new revision and CLI" || bad "output: $out"

reset; echo "$OLD|false|2.1.200|0" > "$F/labels"; echo "$MAIN|false|2.1.293|0" > "$F/labels.after"
run --image t:l >/dev/null
grep -qE '^make .* build WITH_BROWSER=0 CLAUDE_IMAGE=t:l$' "$F/log" && ok "a lean image builds with build, WITH_BROWSER=0 pinned" || bad "lean: $(grep make "$F/log")"

reset; echo "$OLD|false|2.1.200|1" > "$F/labels"
out="$(run --image t:b --dry-run)"; rc=$?
(( rc == 0 )) && grep -qF 'pull --ff-only' <<<"$out" && grep -qF 'build-browser' <<<"$out" \
    && ok "--dry-run prints the pull and the build" || bad "dry-run: rc $rc $out"
! grep -qE '^(git .*pull|make )' "$F/log" && ok "--dry-run runs neither" || bad "dry-run ran: $(cat "$F/log")"

# ======================================================================================
echo "== never touches a container =="
for pat in 'compose up' 'restart' 'rm -f' 'prune'; do
    if command -v rg >/dev/null; then hit="$(rg -n -F -- "$pat" "$SCRIPT")"; else hit="$(grep -n -F -- "$pat" "$SCRIPT")"; fi
    [[ -z "$hit" ]] && ok "no '$pat'" || bad "contains '$pat': $hit"
done

echo
echo "image-rebuild-unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
