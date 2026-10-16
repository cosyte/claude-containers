#!/usr/bin/env bash
# Unit tests for bin/claude-list's IMAGE and BEHIND columns and --json: NO docker, NO network.
# A fake docker answers `ps` from a file; the script runs from a copy inside a git fixture repo
# whose origin/main is set by hand, so BEHIND counts against a known history:
#   - labelled and current (0), behind by 3, dirty (-dirty), unlabelled (unknown, ?), a
#     revision not in the checkout (?)
#   - the existing columns keep their order, the two new ones are appended
#   - --json carries image_revision, image_dirty, image_cli_version and behind_main
# shellcheck source=test/lib/prelude.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/prelude.sh"
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

# The fixture checkout: five commits, origin/main at the last, claude-list in its bin/.
CO="$TMPD/checkout"; mkdir -p "$CO/bin"
git -C "$CO" init -q
for i in 0 1 2 3 4; do
    git -C "$CO" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m "c$i"
done
git -C "$CO" update-ref refs/remotes/origin/main HEAD
MAIN="$(git -C "$CO" rev-parse HEAD)"
OLD="$(git -C "$CO" rev-parse HEAD~3)"
GONE=abcdef0123456789abcdef0123456789abcdef01
cp "$REPO_ROOT/bin/claude-list" "$REPO_ROOT/bin/_common.sh" "$CO/bin/"

# The fake docker logs each call; `ps` prints $F/ps, `inspect` an empty fleet.
F="$TMPD/f"; FAKES="$TMPD/bin"; mkdir -p "$F" "$FAKES"
cat > "$FAKES/docker" <<'SH'
#!/usr/bin/env bash
echo "docker $*" >> "$F/log"
case "$1" in
    info)    exit 0 ;;
    ps)      cat "$F/ps" ;;
    inspect) echo '[]' ;;
    *)       exit 1 ;;
esac
SH
chmod +x "$FAKES/docker"
export F

# row <name> <revision> <dirty> <cli>: one `docker ps` line in claude-list's format.
row() { printf '%s\trunning\t2201\tme/x\tUp 2 hours (healthy)\t%s\t%s\t%s\n' "$@"; }
{
    row cur   "$MAIN" false 2.1.293
    row old   "$OLD"  false 2.1.200
    row dirty "$MAIN" true  2.1.293
    row bare  ""      ""    ""
    row gone  "$GONE" false 2.1.293
} > "$F/ps"
: > "$F/log"
run() { PATH="$FAKES:$PATH" "$CO/bin/claude-list" "$@" 2>"$TMPD/err"; }
line() { grep "^$1 " <<<"$out"; }

# ======================================================================================
echo "== the table =="
out="$(run)"; rc=$?
(( rc == 0 )) && ok "exits 0" || bad "exit $rc: $(cat "$TMPD/err")"
read -r -a head <<<"$(head -n 1 <<<"$out")"
[[ "${head[*]}" == "NAME STATE SSH PORT SESSIONS REPO STATUS IMAGE BEHIND" ]] \
    && ok "the existing columns keep their order, IMAGE and BEHIND appended" || bad "header: ${head[*]}"
[[ "$(line cur | awk '{print $(NF-1), $NF}')" == "${MAIN:0:7} 0" ]] \
    && ok "labelled and current: its short commit, behind 0" || bad "current: $(line cur)"
[[ "$(line old | awk '{print $(NF-1), $NF}')" == "${OLD:0:7} 3" ]] \
    && ok "behind by 3" || bad "behind: $(line old)"
[[ "$(line dirty | awk '{print $(NF-1), $NF}')" == "${MAIN:0:7}-dirty 0" ]] \
    && ok "dirty: -dirty appended" || bad "dirty: $(line dirty)"
[[ "$(line bare | awk '{print $(NF-1), $NF}')" == "unknown ?" ]] \
    && ok "unlabelled: unknown, ?" || bad "unlabelled: $(line bare)"
[[ "$(line gone | awk '{print $(NF-1), $NF}')" == "${GONE:0:7} ?" ]] \
    && ok "a revision not in the checkout: ?" || bad "not in checkout: $(line gone)"
line cur | grep -qF 'me/x' && line cur | grep -qF 'Up 2 hours (healthy)' \
    && ok "the existing fields still read through" || bad "fields: $(line cur)"

# ======================================================================================
echo "== --json =="
if command -v jq >/dev/null; then
    out="$(run --json)"; rc=$?
    (( rc == 0 )) && jq -e 'length == 5' <<<"$out" >/dev/null \
        && ok "one object per container" || bad "json: exit $rc: $out"
    get() { jq -c --arg n "$1" '.[] | select(.name == $n)
        | [.image_revision, .image_dirty, .image_cli_version, .behind_main]' <<<"$out"; }
    [[ "$(get cur)" == "[\"$MAIN\",false,\"2.1.293\",0]" ]] && ok "current" || bad "current: $(get cur)"
    [[ "$(get old)" == "[\"$OLD\",false,\"2.1.200\",3]" ]] && ok "behind 3" || bad "behind: $(get old)"
    [[ "$(get dirty)" == "[\"$MAIN\",true,\"2.1.293\",0]" ]] && ok "dirty" || bad "dirty: $(get dirty)"
    [[ "$(get bare)" == '["unknown",null,"unknown",null]' ]] && ok "unlabelled" || bad "unlabelled: $(get bare)"
    [[ "$(get gone)" == "[\"$GONE\",false,\"2.1.293\",null]" ]] && ok "not in the checkout" || bad "gone: $(get gone)"
    jq -e '.[0] | .name == "cur" and .ssh_port == "2201" and .repo == "me/x"' <<<"$out" >/dev/null \
        && ok "the existing fields are there too" || bad "fields: $(jq -c '.[0]' <<<"$out")"
    : > "$F/ps"
    [[ "$(run --json)" == "[]" ]] && ok "no containers: []" || bad "empty fleet"
else
    echo "  SKIP  --json (no jq)"
fi
run --bogus >/dev/null && bad "an unknown argument is accepted" || ok "an unknown argument is refused"

echo
echo "list-unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
