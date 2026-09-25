#!/usr/bin/env bash
# Unit tests for the workspace: one repo at /workspace, or several in /workspace/<repo>.
# NO docker daemon, NO network, NO root: the repos are local bare repos (file://).
#
#   - entrypoint.sh section 9, run for real: GIT_REPOS clones each repo into its own
#     directory, honours URL#BRANCH, clones only what is missing on the next boot, and
#     refuses a name collision, GIT_REPOS with GIT_REPO_URL, and nesting into a
#     single-repo workspace; the single-repo path is unchanged
#   - claude-compose-gen --group: one service with GIT_REPOS, per-repo flags applied to it,
#     single-repo siblings untouched, bad groups refused
#   - claude-launch with several --repo: GIT_REPOS, the label, and the refusals
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
BLOCK="$(awk '/^# --- 9\. Workspace/{f=1} f&&/^# --- 10\./{exit} f{print}' "$REPO_ROOT/entrypoint.sh")"
run9() {  # run9 <workspace> <env...>: section 9 as the entrypoint runs it, sandboxed
    local ws="$1"; shift
    ( export "$@" 2>/dev/null
      log()  { echo "[entrypoint] $*"; }
      die()  { echo "[entrypoint] ERROR: $*" >&2; exit 1; }
      asclaude() { "$@"; }
      set -euo pipefail
      WORKSPACE="$ws" CLAUDE_UID="$(id -u)" CLAUDE_GID="$(id -g)"
      mkdir -p "$WORKSPACE"
      eval "$BLOCK" ) 2>&1
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
    rm -rf "$WS/home"
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
