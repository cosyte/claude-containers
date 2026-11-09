#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables set in subshells are read by the entrypoint blocks run with eval
# Unit tests for the workspace: one repo at /workspace, or several in /workspace/<repo>.
# NO docker daemon, NO network, NO root: the repos are local bare repos (file://).
#
#   - entrypoint.sh section 9, run for real: GIT_REPOS clones each repo into its own
#     directory, honours URL#BRANCH, clones only what is missing on the next boot, and
#     refuses a name collision, GIT_REPOS with GIT_REPO_URL, and nesting into a
#     single-repo workspace; the single-repo path is unchanged
#   - entrypoint.sh section 9, GIT_UMBRELLA: the repo at /workspace comes with its submodules,
#     github.com SSH URLs are rewritten to HTTPS in the agent's global git config, every boot
#     checks out only the submodules not checked out yet, a submodule that cannot be fetched is
#     a WARNING (never a failed boot), a submodule fetch that hangs is stopped at
#     GIT_SUBMODULE_TIMEOUT with a WARNING and fetched on the next boot, COSYTE_UMBRELLA is
#     exported and written for SSH logins, and GIT_REPOS, a workspace with no repo at its root,
#     and an unrecognised value are refused
#   - claude-compose-gen --group: one service with GIT_REPOS, per-repo flags applied to it,
#     single-repo siblings untouched, bad groups refused
#   - claude-launch with several --repo: GIT_REPOS, the label, and the refusals
# shellcheck source=test/lib/prelude.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/prelude.sh"
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

# --- fixtures: three bare repos, one with a second branch --------------------------------
mkbare() {  # mkbare <name> [extra-branch]
    local src="$TMPD/src/$1"
    git init -q -b main "$src"
    echo "$1 on main" > "$src/README"
    git -C "$src" add README
    GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t git -C "$src" commit -qm init
    if [[ -n "${2:-}" ]]; then
        git -C "$src" checkout -q -b "$2"
        echo "$1 on $2" > "$src/README"
        GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t git -C "$src" commit -qam "$2"
        git -C "$src" checkout -q main
    fi
    git clone -q --bare "$src" "$TMPD/bare/$1.git"
}
mkdir -p "$TMPD/bare"
mkbare home; mkbare 3d; mkbare keys dev

# --- entrypoint section 9, extracted and run -------------------------------------------
# shellcheck source=test/lib/entrypoint.sh
source "$REPO_ROOT/test/lib/entrypoint.sh"
# Its one root-only path (the SSH-login profile file) is redirected into the sandbox, so no
# case can write to the real /etc/profile.d; the redirect is asserted below.
UM_PROFILE="$TMPD/profile.d/claude-umbrella.sh"; mkdir -p "${UM_PROFILE%/*}"
BLOCK="$(awk '/^# --- 9\. Workspace/{f=1} f{print}' "$(ep_section 9)" \
    | sed "s#^UMBRELLA_PROFILE_D=.*#UMBRELLA_PROFILE_D=\"$UM_PROFILE\"#")"
run9() {  # run9 <workspace> <env...>: section 9 as the entrypoint runs it, sandboxed
    local ws="$1"; shift
    # shellcheck disable=SC2163  # "$@" is VAR=VAL pairs, exported as given
    ( unset GIT_UMBRELLA COSYTE_UMBRELLA
      export "$@" 2>/dev/null
      log()  { echo "[entrypoint] $*"; }
      die()  { echo "[entrypoint] ERROR: $*" >&2; exit 1; }
      asclaude() { "$@"; }
      set -euo pipefail
      WORKSPACE="$ws" CLAUDE_UID="$(id -u)" CLAUDE_GID="$(id -g)"
      mkdir -p "$WORKSPACE"
      eval "$BLOCK"
      echo "COSYTE_UMBRELLA=${COSYTE_UMBRELLA-<unset>}" ) 2>&1
}
B="file://$TMPD/bare"
echo "== entrypoint section 9: GIT_REPOS =="
if [[ -z "$BLOCK" ]]; then
    bad "could not extract section 9 from entrypoint.sh"
else
    WS="$TMPD/ws1"
    out="$(run9 "$WS" GIT_REPOS="$B/home.git $B/3d.git $B/keys.git#dev")"; rc=$?
    (( rc == 0 )) && [[ -d "$WS/home/.git" && -d "$WS/3d/.git" && -d "$WS/keys/.git" ]] \
        && ok "each repo is cloned into /workspace/<repo>" || bad "multi-repo clone (rc=$rc): $out"
    [[ "$(cat "$WS/keys/README" 2>/dev/null)" == "keys on dev" && "$(cat "$WS/home/README" 2>/dev/null)" == "home on main" ]] \
        && ok "URL#BRANCH checks out that branch; no suffix takes the default" || bad "branch selection"
    [[ ! -e "$WS/.git" ]] && ok "/workspace itself is not a repo (a parent of the repos)" || bad "/workspace became a repo"
    grep -q 'Workspace           : .* holds 3 repos (home 3d keys)' <<<"$out" \
        && ok "the boot log lists the repos in the configured order" || bad "summary line: $out"
    echo "local work" > "$WS/3d/WIP"
    out="$(run9 "$WS" GIT_REPOS="$B/home.git $B/3d.git $B/keys.git#dev")"; rc=$?
    (( rc == 0 )) && [[ -f "$WS/3d/WIP" ]] && grep -q '3d (existing checkout, left as it is)' <<<"$out" \
        && ok "a second boot leaves existing checkouts (and their work) alone" || bad "re-boot (rc=$rc): $out"
    rm -rf "${WS:?}/home"
    out="$(run9 "$WS" GIT_REPOS="$B/home.git $B/3d.git $B/keys.git#dev")"
    [[ -d "$WS/home/.git" ]] && grep -q 'cloning .*home.git' <<<"$out" && ! grep -q 'cloning .*3d.git' <<<"$out" \
        && ok "a missing (or newly listed) repo is cloned on the next boot, and only that one" || bad "partial re-clone: $out"
    out="$(run9 "$TMPD/ws2" GIT_REPOS="$B/keys.git file://$TMPD/elsewhere/keys.git")"; rc=$?
    (( rc != 0 )) && grep -q 'two repos would both clone into' <<<"$out" \
        && ok "two repos with the same name are refused" || bad "collision (rc=$rc): $out"
    out="$(run9 "$TMPD/ws3" GIT_REPOS="$B/home.git" GIT_REPO_URL="$B/3d.git")"; rc=$?
    (( rc != 0 )) && grep -q 'GIT_REPOS and GIT_REPO_URL are both set' <<<"$out" \
        && ok "GIT_REPOS together with GIT_REPO_URL is refused" || bad "both set (rc=$rc): $out"
    out="$(run9 "$TMPD/ws4" GIT_REPO_URL="$B/3d.git")"; rc=$?
    (( rc == 0 )) && [[ -d "$TMPD/ws4/.git" ]] && [[ "$(cat "$TMPD/ws4/README" 2>/dev/null)" == "3d on main" ]] \
        && ok "GIT_REPOS UNSET (every ordinary container): the single repo clones into /workspace under set -u" \
        || bad "single repo with GIT_REPOS unset (rc=$rc): $out"
    out="$(run9 "$TMPD/ws4" GIT_REPOS="$B/home.git")"; rc=$?
    (( rc != 0 )) && grep -q 'already holds a single repo at its root' <<<"$out" && [[ ! -e "$TMPD/ws4/home" ]] \
        && ok "GIT_REPOS on a single-repo workspace is refused (no nested repos)" || bad "nesting (rc=$rc): $out"
    out="$(run9 "$TMPD/ws5" GIT_REPOS="$B/missing.git")"; rc=$?
    (( rc != 0 )) && grep -q 'git clone of .*missing.git' <<<"$out" \
        && ok "a clone that fails stops the boot and names the repo" || bad "clone failure (rc=$rc): $out"
    out="$(run9 "$TMPD/ws6" GIT_REPO_URL="$B/3d.git" GIT_REPOS="  ")"; rc=$?
    (( rc == 0 )) && [[ -d "$TMPD/ws6/.git" ]] && [[ "$(cat "$TMPD/ws6/README")" == "3d on main" ]] \
        && ok "the single-repo path is unchanged (and a blank GIT_REPOS is ignored)" || bad "single repo (rc=$rc): $out"
fi

# --- entrypoint section 9: an umbrella with its submodules ------------------------------
# The umbrella pins home and 3d as submodules by file:// URLs. git refuses that transport for a
# submodule unless protocol.file.allow says otherwise, so the cases that must fetch pass it in
# through GIT_CONFIG_* (FILEOK), and leaving it out is how a case makes a fetch fail. HOME is a
# sandbox in every case: the block writes the agent's global git config.
echo "== entrypoint section 9: GIT_UMBRELLA =="
UMSRC="$TMPD/src/umbrella"
git init -q -b main "$UMSRC"
git -C "$UMSRC" -c protocol.file.allow=always submodule --quiet add "$B/home.git" home
git -C "$UMSRC" -c protocol.file.allow=always submodule --quiet add "$B/3d.git" 3d
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t git -C "$UMSRC" commit -qm pins
git clone -q --bare "$UMSRC" "$TMPD/bare/umbrella.git"
UMH="$TMPD/umhome"; mkdir -p "$UMH"
FILEOK=(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always)
um9() {  # um9 <workspace> <env...>: run9 with the sandboxed HOME
    local ws="$1"; shift
    run9 "$ws" HOME="$UMH" XDG_CONFIG_HOME="$UMH/.config" "$@"
}
insteadof() { HOME="$UMH" XDG_CONFIG_HOME="$UMH/.config" git config --global --get-all url.https://github.com/.insteadOf 2>/dev/null; }
geturl()    { HOME="$UMH" XDG_CONFIG_HOME="$UMH/.config" git ls-remote --get-url "$1" 2>/dev/null; }

! grep -q '/etc/profile.d' <<<"$BLOCK" && grep -qF "UMBRELLA_PROFILE_D=\"$UM_PROFILE\"" <<<"$BLOCK" \
    && ok "section 9's profile file is redirected into the sandbox (no case writes /etc)" \
    || bad "section 9 did not extract, or UMBRELLA_PROFILE_D did not redirect: these cases would write to /etc"

WS="$TMPD/um1"
out="$(um9 "$WS" GIT_UMBRELLA=1 GIT_REPO_URL="$B/umbrella.git" GH_TOKEN=x "${FILEOK[@]}")"; rc=$?
(( rc == 0 )) && [[ -d "$WS/.git" ]] && [[ "$(cat "$WS/home/README" 2>/dev/null)" == "home on main" ]] \
    && [[ "$(cat "$WS/3d/README" 2>/dev/null)" == "3d on main" ]] \
    && ok "GIT_UMBRELLA=1: the umbrella is cloned into /workspace with its submodules checked out" \
    || bad "umbrella clone (rc=$rc): $out"
grep -qxF "COSYTE_UMBRELLA=$WS" <<<"$out" && grep -qxF "export COSYTE_UMBRELLA=$WS" "$UM_PROFILE" 2>/dev/null \
    && [[ "$(stat -c %a "$UM_PROFILE")" == 644 ]] \
    && ok "COSYTE_UMBRELLA is exported for the sessions and written (644) for SSH logins" \
    || bad "COSYTE_UMBRELLA: $out / $(cat "$UM_PROFILE" 2>&1)"
! grep -q 'WARNING' <<<"$out" && ok "with GH_TOKEN and every submodule fetched: no warning" || bad "unexpected warning: $out"
[[ "$(insteadof)" == $'git@github.com:\nssh://git@github.com/' ]] \
    && [[ "$(geturl git@github.com:me/x.git)" == https://github.com/me/x.git ]] \
    && [[ "$(geturl ssh://git@github.com/me/x.git)" == https://github.com/me/x.git ]] \
    && [[ "$(geturl git@gitlab.com:me/x.git)" == git@gitlab.com:me/x.git ]] \
    && ok "the agent's git rewrites github.com SSH URLs (scp and ssh:// forms) to HTTPS, and nothing else" \
    || bad "insteadOf: $(insteadof | tr '\n' ' ') / $(geturl git@github.com:me/x.git)"

echo "local work" > "$WS/home/WIP"
git -C "$WS" submodule --quiet deinit -f 3d
out="$(um9 "$WS" GIT_UMBRELLA=1 GIT_REPO_URL="$B/umbrella.git" GH_TOKEN=x "${FILEOK[@]}")"; rc=$?
(( rc == 0 )) && [[ -f "$WS/home/WIP" ]] && [[ "$(cat "$WS/3d/README" 2>/dev/null)" == "3d on main" ]] \
    && grep -qF 'checking out 1 submodules not checked out yet (3d)' <<<"$out" \
    && ok "a later boot checks out only the submodule not checked out, and leaves the others' work alone" \
    || bad "re-boot (rc=$rc): $out"
[[ "$(insteadof | wc -l)" == 2 ]] && ok "a later boot adds no duplicate insteadOf line" || bad "insteadOf duplicated: $(insteadof | tr '\n' ' ')"

out="$(um9 "$TMPD/um2" GIT_UMBRELLA=1 GIT_REPO_URL="$B/umbrella.git" GH_TOKEN= "${FILEOK[@]}")"; rc=$?
(( rc == 0 )) && grep -qF 'WARNING: GIT_UMBRELLA without GH_TOKEN' <<<"$out" \
    && ok "no GH_TOKEN: a WARNING (private submodules need it over HTTPS), and the boot goes on" \
    || bad "no token (rc=$rc): $out"

out="$(um9 "$TMPD/um3" GIT_UMBRELLA=yes GIT_REPO_URL="$B/umbrella.git" GH_TOKEN=x)"; rc=$?
(( rc == 0 )) && [[ -d "$TMPD/um3/.git" && ! -e "$TMPD/um3/home/README" ]] \
    && grep -qF 'WARNING: umbrella submodules still not checked out: 3d home' <<<"$out" \
    && grep -qxF "COSYTE_UMBRELLA=$TMPD/um3" <<<"$out" \
    && ok "a submodule that cannot be fetched: a WARNING naming it, the boot goes on, COSYTE_UMBRELLA still set" \
    || bad "fetch failure (rc=$rc): $out"

out="$(um9 "$TMPD/um4" GIT_UMBRELLA=1 GIT_REPOS="$B/home.git")"; rc=$?
(( rc != 0 )) && grep -qF 'GIT_UMBRELLA and GIT_REPOS are both set' <<<"$out" && [[ ! -e "$TMPD/um4/home" ]] \
    && ok "GIT_UMBRELLA with GIT_REPOS is refused, before any clone" || bad "with GIT_REPOS (rc=$rc): $out"
mkdir -p "$TMPD/um5"; echo notes > "$TMPD/um5/notes.txt"
out="$(um9 "$TMPD/um5" GIT_UMBRELLA=1)"; rc=$?
(( rc != 0 )) && grep -qF 'holds no repo at its root' <<<"$out" \
    && ok "GIT_UMBRELLA on a workspace with no repo at its root is refused" || bad "no repo (rc=$rc): $out"
out="$(um9 "$TMPD/um6" GIT_UMBRELLA=maybe GIT_REPO_URL="$B/umbrella.git")"; rc=$?
(( rc != 0 )) && grep -qF "GIT_UMBRELLA='maybe' is not a recognised value" <<<"$out" && [[ ! -e "$TMPD/um6/.git" ]] \
    && ok "an unrecognised GIT_UMBRELLA is refused, quoted back, before any clone" || bad "typo (rc=$rc): $out"

rm -rf "$UMH"; mkdir -p "$UMH"; echo stale > "$UM_PROFILE"
out="$(um9 "$TMPD/um7" GIT_UMBRELLA=0 GIT_REPO_URL="$B/umbrella.git" "${FILEOK[@]}")"; rc=$?
(( rc == 0 )) && [[ -d "$TMPD/um7/.git" && ! -e "$TMPD/um7/home/README" ]] \
    && grep -qxF 'COSYTE_UMBRELLA=<unset>' <<<"$out" && [[ -z "$(insteadof)" ]] && [[ ! -e "$UM_PROFILE" ]] \
    && ok "GIT_UMBRELLA=0: a plain clone, no submodules, no rewrite, no COSYTE_UMBRELLA, a stale profile file removed" \
    || bad "umbrella off (rc=$rc): $out / $(insteadof)"

# A submodule fetch that hangs (a stalled connection: git sets no transfer timeout of its own).
# The 3d submodule's URL is rewritten to an ext:: command that never answers, so its clone
# waits until the command exits, 20 s later; home's fetch is untouched.
HANG=(GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
      GIT_CONFIG_KEY_1=protocol.ext.allow GIT_CONFIG_VALUE_1=always
      "GIT_CONFIG_KEY_2=url.ext::sleep 20.insteadOf" "GIT_CONFIG_VALUE_2=$B/3d.git")
rm -rf "$UMH"; mkdir -p "$UMH"
s=$SECONDS
out="$(um9 "$TMPD/um8" GIT_UMBRELLA=1 GIT_REPO_URL="$B/umbrella.git" GH_TOKEN=x GIT_SUBMODULE_TIMEOUT=2 "${HANG[@]}")"; rc=$?
took=$((SECONDS - s))
(( rc == 0 && took < 15 )) && [[ "$(cat "$TMPD/um8/home/README" 2>/dev/null)" == "home on main" && ! -e "$TMPD/um8/3d/README" ]] \
    && grep -qF 'WARNING: umbrella submodule 3d: the fetch took over 2s and was stopped' <<<"$out" \
    && grep -qF 'WARNING: umbrella submodules still not checked out: 3d' <<<"$out" \
    && grep -qxF "COSYTE_UMBRELLA=$TMPD/um8" <<<"$out" \
    && ok "a hung submodule fetch is stopped at GIT_SUBMODULE_TIMEOUT: a WARNING naming it, the others fetched, the boot goes on" \
    || bad "hung submodule (rc=$rc, ${took}s): $out"
out="$(um9 "$TMPD/um8" GIT_UMBRELLA=1 GIT_REPO_URL="$B/umbrella.git" GH_TOKEN=x "${FILEOK[@]}")"; rc=$?
(( rc == 0 )) && [[ "$(cat "$TMPD/um8/3d/README" 2>/dev/null)" == "3d on main" ]] && ! grep -q WARNING <<<"$out" \
    && ok "the next boot fetches the submodule that was stopped (nothing half-cloned is left in its way)" \
    || bad "after a stopped fetch (rc=$rc): $out"
for v in abc 0 ' '; do
    rm -rf "$UMH"; mkdir -p "$UMH"
    out="$(um9 "$TMPD/um9-$RANDOM" GIT_UMBRELLA=1 GIT_REPO_URL="$B/umbrella.git" GH_TOKEN=x GIT_SUBMODULE_TIMEOUT="$v" "${FILEOK[@]}")"; rc=$?
    (( rc == 0 )) && grep -qF "WARNING: GIT_SUBMODULE_TIMEOUT='$v' is not a positive number of seconds: 300 applies" <<<"$out" \
        && grep -qF 'checking out 2 submodules' <<<"$out" && ! grep -q 'still not checked out' <<<"$out" \
        && ok "GIT_SUBMODULE_TIMEOUT='$v': a WARNING, the default applies, the boot goes on" \
        || bad "bad GIT_SUBMODULE_TIMEOUT '$v' (rc=$rc): $out"
done

# --- claude-compose-gen --group --------------------------------------------------------
echo "== claude-compose-gen --group =="
GEN="$REPO_ROOT/bin/claude-compose-gen"
STUBD="$TMPD/stub"; mkdir -p "$STUBD"
printf '#!/usr/bin/env bash\ncase "$1" in info) [[ "$*" == *DiscoveredDevices* ]] && echo "nvidia.com/gpu=all ";; image) [[ "$*" == *Labels* ]] && echo 0;; esac\nexit 0\n' > "$STUBD/docker"
chmod +x "$STUBD/docker"
gen() { PATH="$STUBD:$PATH" CLAUDE_PORTS_USED_OVERRIDE="" "$GEN" "$@"; }
svc_block() { awk -v s="  $2:" 'index($0,s)==1{f=1;next} f && /^  [a-z0-9-]+:$/{exit} f{print}' "$1"; }
OUT="$TMPD/g.yml"
gen --out "$OUT" --port-base 2230 me/3d me/keys >/dev/null 2>&1
before_3d="$(svc_block "$OUT" 3d)"
out="$(gen --out "$OUT" --port-base 2230 --group maker=me/home,me/3d,other/keys:dev --gpu maker --cpu maker=8 --active maker me/3d me/keys 2>&1)"; rc=$?
m="$(svc_block "$OUT" maker)"
(( rc == 0 )) && grep -qF 'GIT_REPOS: "git@github.com:me/home.git git@github.com:me/3d.git git@github.com:other/keys.git#dev"' <<<"$m" \
    && ! grep -q 'GIT_REPO_URL' <<<"$m" \
    && ok "a group service gets GIT_REPOS (owner/repo, :branch as #branch) and no GIT_REPO_URL" || bad "group env (rc=$rc): $m"
grep -q 'claude.repo: "group:me/home,me/3d,other/keys"' <<<"$m" \
    && ok "its claude.repo label lists the group" || bad "group label"
grep -q '^    cpus: 8$' <<<"$m" && grep -q 'nvidia.com/gpu=all' <<<"$m" && grep -q 'container_name: claude-maker' <<<"$m" \
    && ! grep -q 'profiles:' <<<"$m" \
    && ok "per-repo flags (--cpu, --gpu, --active) apply to the group by its name" || bad "group flags: $m"
grep -q 'claude-ws-maker:/workspace' <<<"$m" && grep -qE '^  claude-ws-maker:' "$OUT" \
    && ok "the group has its own workspace volume" || bad "group workspace volume"
grep -q 'claude-maker .*ssh :2232' <<<"$out" \
    && ok "a new group takes the next free port" || bad "group port: $out"
[[ "$(svc_block "$OUT" 3d | grep -vE 'profiles|dormant')" == "$(grep -vE 'profiles|dormant' <<<"$before_3d")" ]] \
    && grep -q '"2230:22"' <<<"$(svc_block "$OUT" 3d)" \
    && ok "single-repo siblings keep their YAML and ports (only their profile changes with --active)" || bad "sibling changed"
docker_ok=skip
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose -f "$OUT" config -q >/dev/null 2>&1 && docker_ok=yes || docker_ok=no
fi
case "$docker_ok" in yes) ok "docker compose config accepts it" ;; no) bad "docker compose config rejects it" ;; *) echo "  SKIP  docker compose config" ;; esac
for c in "3d=me/home|already a service in this stack" "m=a/x,b/x|would both clone into /workspace/x" \
         "m=nope|has no owner" "m=a/b:bad\$x|has characters a branch name cannot" "noequals|must be NAME=REPO"; do
    arg="${c%%|*}"; want="${c#*|}"
    out="$(gen --out "$TMPD/bad.yml" --group "$arg" me/3d 2>&1)"; rc=$?
    (( rc != 0 )) && [[ "$out" == *"$want"* ]] && ok "--group '$arg' is refused ($want)" || bad "--group '$arg' (rc=$rc): $out"
done
out="$(gen --out "$TMPD/only.yml" --group maker=me/home,me/3d 2>&1)"; rc=$?
(( rc == 0 )) && grep -qE '^  maker:$' "$TMPD/only.yml" \
    && ok "a stack can be only groups (no single-repo args, no --org)" || bad "groups only (rc=$rc): $out"

# --- claude-launch with several --repo -------------------------------------------------
echo "== claude-launch --repo (repeated) =="
LAUNCH="$REPO_ROOT/bin/claude-launch"
cat > "$STUBD/docker" <<'STUB'
#!/usr/bin/env bash
d="${STUB_STATE:?}"
case "$1" in
    info)    echo ok ;;
    inspect) [[ -e "$d/created" ]] && { echo running; exit 0; }; exit 1 ;;
    image)   [[ "$*" == *Labels* ]] && echo 0; exit 0 ;;
    run)     shift; printf '%s\n' "$@" > "$d/run-args"; touch "$d/created"; echo deadbeef ;;
    *)       exit 0 ;;
esac
STUB
launch() { rm -f "$TMPD/run-args" "$TMPD/created"; env STUB_STATE="$TMPD" PATH="$STUBD:$PATH" CLAUDE_PORTS_USED_OVERRIDE="" \
    "$LAUNCH" multitest --port 2298 "$@" > "$TMPD/launch.log" 2>&1; }
launch --repo git@github.com:me/home.git --repo git@github.com:me/3d.git#dev; rc=$?
args="$(cat "$TMPD/run-args" 2>/dev/null)"
(( rc == 0 )) && grep -qxF 'GIT_REPOS=git@github.com:me/home.git git@github.com:me/3d.git#dev' <<<"$args" \
    && grep -qxF 'GIT_REPO_URL=' <<<"$args" \
    && ok "several --repo become GIT_REPOS (URL#BRANCH kept) with an empty GIT_REPO_URL" || bad "launch multi (rc=$rc): $(tail -3 "$TMPD/launch.log")"
grep -qxF 'claude.repo=group:git@github.com:me/home.git,git@github.com:me/3d.git#dev' <<<"$args" \
    && ok "the claude.repo label lists them" || bad "launch multi label"
launch --repo git@github.com:me/3d.git --branch dev
args="$(cat "$TMPD/run-args" 2>/dev/null)"
grep -qxF 'GIT_REPO_URL=git@github.com:me/3d.git' <<<"$args" && grep -qxF 'GIT_REPOS=' <<<"$args" && grep -qxF 'GIT_REPO_BRANCH=dev' <<<"$args" \
    && ok "a single --repo is unchanged (GIT_REPO_URL + --branch)" || bad "launch single"
for c in "--repo a/x --repo b/x|would both clone into /workspace/x" "--repo a --repo b --branch dev|--branch applies to a single --repo"; do
    read -r -a a <<<"${c%%|*}"; want="${c#*|}"
    launch "${a[@]}"; rc=$?
    (( rc != 0 )) && grep -qF -- "$want" "$TMPD/launch.log" && [[ ! -e "$TMPD/run-args" ]] \
        && ok "claude-launch ${c%%|*} is refused before docker run" || bad "launch ${c%%|*} (rc=$rc)"
done

echo
echo "workspace-unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
