#!/usr/bin/env bash
# Unit tests for the shape of the boot path: NO docker, NO root.
#
# entrypoint.sh is a loader: its numbered sections live in entrypoint.d/, one file each,
# sourced in order. These pin that:
#   - each file is one section: named NN[x]-name.sh, its first header is that section's own
#     "# --- <n>." line, and no section is also still in entrypoint.sh
#   - the loader, run for real against a sandbox, sources them in number order whatever the
#     locale (00- before 00b-), announces each as "§<n> <name>", and refuses an empty directory
#   - the image installs entrypoint.d/ where the loader reads it
# shellcheck source=test/lib/prelude.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/prelude.sh"
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/lib/entrypoint.sh
source "$REPO_ROOT/test/lib/entrypoint.sh"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

echo "== entrypoint.d/: one file per section =="
n_files=0
for f in "$EP_D"/*; do
    b="${f##*/}"; n_files=$((n_files + 1))
    if [[ ! "$b" =~ ^([0-9]{2}[a-z]?)-[a-z0-9-]+\.sh$ ]]; then
        bad "$b is not named NN[x]-name.sh"; continue
    fi
    n="${BASH_REMATCH[1]}"; n="${n#0}"
    first="$(grep -m1 '^# --- ' "$f")"
    [[ "$first" == "# --- $n. "* ]] \
        && ok "$b holds §$n (its header: ${first:0:40})" \
        || bad "$b does not start with the header of §$n: '$first'"
    grep -q "^# --- $n\\. " "$EP_LOADER" \
        && bad "§$n is in $b AND still in entrypoint.sh" \
        || ok "§$n is no longer in entrypoint.sh"
done
(( n_files > 0 )) && ok "entrypoint.d/ holds $n_files sections" || bad "entrypoint.d/ is empty"

echo "== the loader, run in a sandbox =="
LOOP="$(awk '/^ENTRYPOINT_D=/{f=1} f{print} f&&/^unset _sections/{exit}' "$EP_LOADER")"
SB="$TMPD/entrypoint.d"
LOOP_SB="$(sed "s|^ENTRYPOINT_D=.*|ENTRYPOINT_D=$SB|" <<<"$LOOP")"
grep -qxF "ENTRYPOINT_D=$SB" <<<"$LOOP_SB" && [[ "$LOOP_SB" == *'source "$_section"'* ]] \
    && ok "the loader's loop is extracted and pointed at the sandbox" \
    || bad "could not extract the loader's loop (or redirect it): the checks below would be vacuous"
mkdir -p "$SB"
for s in 00-first 00b-second 01-third 02c-fourth 10b-fifth; do
    printf 'ran+=(%s)\n' "${s%%-*}" > "$SB/$s.sh"
done
loader() {  # loader <LC_ALL>: the loop under the entrypoint's options, then what ran
    ( log() { echo "[entrypoint] $*"; }; die() { echo "[entrypoint] ERROR: $*" >&2; exit 1; }
      export LC_ALL="$1"; set -euo pipefail; ran=()
      eval "$LOOP_SB"; echo "ran=${ran[*]}" ) 2>&1
}
for loc in C C.UTF-8 en_US.UTF-8; do
    out="$(loader "$loc")"
    grep -qxF 'ran=00 00b 01 02c 10b' <<<"$out" \
        && ok "LC_ALL=$loc: the sections run in number order (00 before 00b)" \
        || bad "LC_ALL=$loc: the sections ran out of order: $(tail -1 <<<"$out")"
done
out="$(loader C)"
[[ "$(grep '§' <<<"$out")" == $'[entrypoint] §0 first\n[entrypoint] §0b second\n[entrypoint] §1 third\n[entrypoint] §2c fourth\n[entrypoint] §10b fifth' ]] \
    && ok "each section is announced as '§<n> <name>' before it runs" \
    || bad "the section announcements are wrong: $(grep '§' <<<"$out" | tr '\n' '|')"
rm -f "$SB"/*.sh
out="$(loader C)" || true
grep -q 'ERROR: no sections in' <<<"$out" && ! grep -q '^ran=' <<<"$out" \
    && ok "an empty entrypoint.d/ stops the boot, naming it" \
    || bad "an empty entrypoint.d/ did not stop the boot: $out"

echo "== the image =="
want="$(sed -n 's/^ENTRYPOINT_D=//p' "$EP_LOADER")"
grep -qE "^COPY (--chmod=[0-7]+ )?entrypoint\\.d/\\*\\.sh ${want}/\$" "$REPO_ROOT/Dockerfile" \
    && ok "the Dockerfile installs entrypoint.d/ at $want, where the loader reads it" \
    || bad "the Dockerfile must COPY entrypoint.d/*.sh to $want/"

echo
echo "entrypoint-unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
