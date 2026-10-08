#!/usr/bin/env bash
# Unit tests for private per-container state (/state): NO docker daemon, NO root.
#
# /cache is one volume shared by every container on the host, all running as UID 1000, so a
# database or a key kept there is readable from every other container. /state is each
# container's own claude-state-<name> volume. These pin that:
#   - claude-compose-gen: every service mounts exactly ONE state volume at /state, its own,
#     declared by the stack (not external); no service mounts another's; CLAUDE_STATE_DIR is
#     set; the shared cache is still shared; --no-cache leaves state alone; --mount refuses
#     another container's state or config volume and the /state path; --env cannot override
#     CLAUDE_STATE_DIR
#   - claude-launch: its own claude-state-<name> at /state (docker is stubbed)
#   - claude-rm --purge deletes the container's state volume and no other
#   - entrypoint.sh 2c, run for real in a sandbox: /state is made, owned and mode 700, the
#     boot log says whether it is a volume, and private-looking files the container still
#     keeps in the shared cache are named (never moved)
#   - the image, the compose template and SSH logins carry /state and CLAUDE_STATE_DIR
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

GEN="$REPO_ROOT/bin/claude-compose-gen"
LAUNCH="$REPO_ROOT/bin/claude-launch"
RM="$REPO_ROOT/bin/claude-rm"

# A docker stub: answers the read-only questions, records `docker run` arguments per
# container name, and logs every call so a test can see which volumes were removed.
STUBD="$TMPD/stub"; mkdir -p "$STUBD"
cat > "$STUBD/docker" <<'STUB'
#!/usr/bin/env bash
d="${STUB_STATE:?}"
printf '%s\n' "$*" >> "$d/calls"
case "$1" in
    info)    echo "ok" ;;
    inspect) [[ -e "$d/created" ]] && { echo running; exit 0; }; exit 1 ;;
    image)   [[ "$*" == *Labels* ]] && echo 0; exit 0 ;;
    volume)  exit 0 ;;
    ps)      exit 0 ;;
    run)     shift; printf '%s\n' "$@" > "$d/run-args"; touch "$d/created"; echo deadbeef ;;
    *)       exit 0 ;;
esac
STUB
chmod +x "$STUBD/docker"

gen() { STUB_STATE="$TMPD" PATH="$STUBD:$PATH" CLAUDE_PORTS_USED_OVERRIDE="" "$GEN" "$@"; }
svc_block() {  # svc_block <file> <service>: that service's YAML only
    awk -v s="  $2:" 'index($0,s)==1{f=1;next} f && /^  [a-z0-9-]+:$/{exit} f{print}' "$1"
}
vol_lines() {  # vol_lines <file> <service>: the service's volumes list entries
    svc_block "$1" "$2" | awk '/^    volumes:$/{f=1;next} f && /^    [a-z_]+:/{exit} f && /^      - /{sub(/^      - /,""); print}'
}
top_vol() {  # top_vol <file> <key>: the top-level volumes: entry for <key>
    awk '/^volumes:$/{f=1;next} f && /^[a-z]/{exit} f' "$1" | awk -v k="  $2:" 'index($0,k)==1{f=1;print;next} f && /^  [^ ]/{exit} f{print}'
}

# ======================================================================================
echo "== claude-compose-gen: each service gets its own claude-state-<svc> at /state =="
OUT="$TMPD/stack.yml"
SVCS=(api web gpu grp)
gen_out="$(gen --out "$OUT" --browser web --gpu gpu --group grp=o/x,o/y acme/api acme/web acme/gpu 2>&1)"
if [[ ! -s "$OUT" ]]; then
    bad "compose-gen produced no file: $gen_out"
else
    for s in "${SVCS[@]}"; do
        v="$(vol_lines "$OUT" "$s")"
        state_lines="$(grep -E ':/state(:|$)' <<<"$v" || true)"
        [[ "$state_lines" == "claude-state-$s:/state" ]] \
            && ok "$s mounts exactly one volume at /state, its own claude-state-$s" \
            || bad "$s must mount exactly claude-state-$s:/state (got: ${state_lines:-nothing})"
        others="$(grep -E '^claude-state-' <<<"$v" | grep -vxF "claude-state-$s:/state" || true)"
        [[ -z "$others" ]] \
            && ok "$s mounts no other service's state volume" \
            || bad "$s mounts another service's state: $others"
        grep -qxF 'claude-cache:/cache' <<<"$v" \
            && ok "$s still mounts the shared tool cache at /cache" \
            || bad "$s lost the shared cache mount"
        grep -qxF '      CLAUDE_STATE_DIR: "/state"' <<<"$(svc_block "$OUT" "$s")" \
            && ok "$s sets CLAUDE_STATE_DIR=/state" || bad "$s must set CLAUDE_STATE_DIR=/state"
        tv="$(top_vol "$OUT" "claude-state-$s")"
        grep -qxF "    name: claude-state-$s" <<<"$tv" && ! grep -q 'external' <<<"$tv" \
            && ok "claude-state-$s is declared by this stack (named, not external)" \
            || bad "claude-state-$s must be a stack-owned named volume: $tv"
    done
    # Across the whole file: each state volume appears in exactly one service's mounts.
    n_mounts="$(grep -cE '^      - claude-state-[a-z0-9._-]+:/state$' "$OUT")"
    n_uniq="$(grep -E '^      - claude-state-[a-z0-9._-]+:/state$' "$OUT" | sort -u | wc -l)"
    (( n_mounts == ${#SVCS[@]} && n_uniq == ${#SVCS[@]} )) \
        && ok "${#SVCS[@]} services, ${#SVCS[@]} distinct state mounts: no state volume is shared" \
        || bad "state mounts must be one per service and distinct (mounts=$n_mounts distinct=$n_uniq)"
    grep -q 'claude-state-<service> volume at /state' "$OUT" \
        && ok "the generated header says where private state lives" \
        || bad "the generated header must explain /state"
fi

# The shared cache is optional; private state is not.
OUTN="$TMPD/nocache.yml"
gen --out "$OUTN" --no-cache acme/api >/dev/null 2>&1
if [[ -s "$OUTN" ]]; then
    v="$(vol_lines "$OUTN" api)"
    grep -qxF 'claude-state-api:/state' <<<"$v" && ! grep -q ':/cache' <<<"$v" \
        && ok "--no-cache drops /cache and keeps the private state volume" \
        || bad "--no-cache must keep claude-state-api:/state (volumes: $v)"
else
    bad "compose-gen --no-cache produced no file"
fi

# ======================================================================================
echo "== claude-compose-gen --mount / --env: one container's state is never another's =="
refused() {  # refused <label> <expected message part> <gen args...>
    local label="$1" want="$2"; shift 2
    local out rc o="$TMPD/refuse-$PASS-$FAIL.yml"
    out="$(gen --out "$o" "$@" 2>&1)"; rc=$?
    if (( rc != 0 )) && [[ "$out" == *"$want"* ]] && [[ ! -e "$o" ]]; then
        ok "$label"
    else
        bad "$label (rc=$rc, file written: $([[ -e "$o" ]] && echo yes || echo no)): $out"
    fi
}
refused "--mount of a sibling service's state volume is refused" \
    "is one container's private state or config" --mount api=claude-state-web:/web acme/api acme/web
refused "--mount of another stack's state volume is refused" \
    "is one container's private state or config" --mount api=claude-state-box:/other:ro acme/api
refused "--mount of another container's config volume is refused" \
    "is one container's private state or config" --mount api=claude-config-box:/cfg:ro acme/api
refused "--mount at /state (shadowing the service's own state) is refused" \
    "would shadow a mount the service already has" --mount api=claude-ws-other:/state acme/api
refused "--env cannot point CLAUDE_STATE_DIR somewhere else" \
    "the generator already sets it" --env api=CLAUDE_STATE_DIR=/cache/api acme/api
# A foreign workspace (the documented use of --mount) still works.
if gen --out "$TMPD/ws.yml" --mount api=claude-ws-other:/other:ro acme/api >/dev/null 2>&1 \
        && grep -qxF 'claude-ws-other:/other:ro' <<<"$(vol_lines "$TMPD/ws.yml" api)"; then
    ok "--mount of another stack's workspace (read-only) still works"
else
    bad "--mount of a foreign workspace must still be accepted"
fi

# ======================================================================================
echo "== claude-launch: its own claude-state-<name> at /state =="
mkdir -p "$TMPD/ws"
launch() {  # launch <project>: run the launcher against the stub
    rm -f "$TMPD/run-args" "$TMPD/created"
    STUB_STATE="$TMPD" PATH="$STUBD:$PATH" CLAUDE_PORTS_USED_OVERRIDE="" CLAUDE_GPU= \
        "$LAUNCH" "$1" --workspace "$TMPD/ws" --port 2299 >"$TMPD/launch.log" 2>&1
}
launch alpha; rc=$?
args="$(cat "$TMPD/run-args" 2>/dev/null)"
(( rc == 0 )) && grep -qxF 'claude-state-alpha:/state' <<<"$args" \
    && grep -B1 -xF 'claude-state-alpha:/state' <<<"$args" | head -1 | grep -qxF -- '-v' \
    && ok "claude-launch alpha mounts -v claude-state-alpha:/state" \
    || bad "claude-launch must mount its own state volume (rc=$rc): $(tail -3 "$TMPD/launch.log")"
grep -qxF 'CLAUDE_STATE_DIR=/state' <<<"$args" \
    && ok "claude-launch sets CLAUDE_STATE_DIR=/state" || bad "claude-launch must set CLAUDE_STATE_DIR=/state"
launch beta
args_b="$(cat "$TMPD/run-args" 2>/dev/null)"
grep -qxF 'claude-state-beta:/state' <<<"$args_b" && ! grep -q 'claude-state-alpha' <<<"$args_b" \
    && ok "a second container gets claude-state-beta, never alpha's" \
    || bad "beta must mount only claude-state-beta"

echo "== claude-rm --purge: the state volume goes with the container, and only its own =="
: > "$TMPD/calls"; touch "$TMPD/created"
STUB_STATE="$TMPD" PATH="$STUBD:$PATH" "$RM" alpha --yes --purge >"$TMPD/rm.log" 2>&1; rc=$?
(( rc == 0 )) && grep -qxF 'volume rm claude-state-alpha' "$TMPD/calls" \
    && ! grep -q 'volume rm claude-state-beta' "$TMPD/calls" \
    && ok "claude-rm --purge removes claude-state-alpha and no other state volume" \
    || bad "claude-rm --purge must remove claude-state-alpha (rc=$rc): $(grep 'volume rm' "$TMPD/calls" | tr '\n' ';') $(tail -2 "$TMPD/rm.log")"
: > "$TMPD/calls"; touch "$TMPD/created"
STUB_STATE="$TMPD" PATH="$STUBD:$PATH" "$RM" alpha --yes >/dev/null 2>&1
! grep -q 'volume rm' "$TMPD/calls" \
    && ok "claude-rm without --purge keeps the state volume" \
    || bad "claude-rm without --purge must not remove volumes"

# ======================================================================================
echo "== entrypoint.sh 2c: /state made private, the boot log honest, legacy state named =="
ENTRY="$REPO_ROOT/entrypoint.sh"
BLOCK="$(awk '/^# --- 2c\. Private state/{f=1} f&&/^# --- 3\./{exit} f{print}' "$ENTRY")"
OWN_TREE="$(awk '/^own_tree\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$ENTRY")"
SB="$TMPD/sb"
run_2c() {  # run_2c <project name> <mountinfo file> [state dir]: the real block, paths redirected
    local blk
    blk="$(sed -e "s#^STATE_DIR=.*#STATE_DIR=\"${3:-$SB/state}\"#" \
               -e "s#^STATE_MOUNTINFO=.*#STATE_MOUNTINFO=\"$2\"#" \
               -e "s#^STATE_SHARED_CACHE=.*#STATE_SHARED_CACHE=\"$SB/cache\"#" <<<"$BLOCK")"
    ( log() { echo "[entrypoint] $*"; }
      CLAUDE_USER="$(id -un)"; CLAUDE_UID="$(id -u)"; CLAUDE_GID="$(id -g)"; eval "$OWN_TREE"
      set -euo pipefail; CLAUDE_PROJECT_NAME="$1"; eval "$blk"
      echo "STATE_ENV=[$CLAUDE_STATE_DIR]" ) 2>&1
}
if [[ -z "$BLOCK" || -z "$OWN_TREE" ]]; then
    bad "could not extract 2c (or own_tree) from entrypoint.sh"
else
    grep -q '^STATE_DIR=' <<<"$BLOCK" && grep -q '^STATE_MOUNTINFO=' <<<"$BLOCK" && grep -q '^STATE_SHARED_CACHE=' <<<"$BLOCK" \
        && ok "2c names its paths on their own lines (so this sandbox redirect is real)" \
        || bad "2c must assign STATE_DIR, STATE_MOUNTINFO and STATE_SHARED_CACHE on their own lines"
    # Fixtures: box's tracker and web key in the shared cache, a sibling's database (not
    # box's business), a non-secret file, and a symlinked dir that must not be followed.
    mkdir -p "$SB/cache/tracker/box/logs" "$SB/cache/tracker/other" "$SB/cache/tools/box" "$SB/elsewhere"
    : > "$SB/cache/tracker/box/tracker.db"; : > "$SB/cache/tracker/box/web.key"
    : > "$SB/cache/tracker/other/tracker.db"; : > "$SB/cache/tools/box/readme.txt"
    : > "$SB/elsewhere/secret.key"; ln -s "$SB/elsewhere" "$SB/cache/linked"
    mkdir -p "$SB/cache/linked-parent"; ln -s "$SB/elsewhere" "$SB/cache/linked-parent/box"
    printf '36 35 98:0 /x /proc rw - proc proc rw\n' > "$TMPD/mi-none"
    out="$(run_2c box "$TMPD/mi-none")"; rc=$?
    (( rc == 0 )) && [[ -d "$SB/state" ]] && [[ "$(stat -c %a "$SB/state")" == 700 ]] \
        && [[ "$(stat -c %u "$SB/state")" == "$(id -u)" ]] \
        && ok "2c creates the state dir, owned by the agent user, mode 700 (rc 0 under set -euo pipefail)" \
        || bad "2c state dir (rc=$rc, mode $(stat -c %a "$SB/state" 2>/dev/null)): $out"
    grep -qxF "STATE_ENV=[$SB/state]" <<<"$out" \
        && ok "2c exports CLAUDE_STATE_DIR for everything the entrypoint starts" \
        || bad "2c must export CLAUDE_STATE_DIR: $out"
    grep -q "WARNING: $SB/state is not a volume" <<<"$out" && ! grep -q 'Private state       :' <<<"$out" \
        && ok "without a volume at /state the boot log says state will not survive a recreate" \
        || bad "2c must warn when /state is not a volume: $out"
    grep -q 'PRIVATE STATE IN THE SHARED CACHE: 2 file(s)' <<<"$out" \
        && grep -qxF "[entrypoint]   $SB/cache/tracker/box/tracker.db" <<<"$out" \
        && grep -qxF "[entrypoint]   $SB/cache/tracker/box/web.key" <<<"$out" \
        && ok "box's database and key in the shared cache are named in the boot log" \
        || bad "2c must name box's tracker.db and web.key: $out"
    ! grep -q 'tracker/other\|readme.txt\|secret.key' <<<"$out" \
        && ok "another container's files, non-secret files and symlinked dirs are left out" \
        || bad "2c listed something that is not this container's private state: $out"
    [[ -e "$SB/cache/tracker/box/tracker.db" && -e "$SB/cache/tracker/box/web.key" && -z "$(ls -A "$SB/state")" ]] \
        && ok "2c never moves anything (the app would start an empty one at the old path)" \
        || bad "2c must leave the legacy files where they are"
    printf '36 35 98:0 /x /proc rw - proc proc rw\n41 30 9:0 /volumes/claude-state-box/_data %s rw,relatime - ext4 /dev/sda1 rw\n' "$SB/state" > "$TMPD/mi-vol"
    rm -rf "$SB/cache/tracker/box"
    out="$(run_2c box "$TMPD/mi-vol")"; rc=$?
    (( rc == 0 )) && grep -q "Private state       : $SB/state (this container's own volume" <<<"$out" \
        && ! grep -q 'WARNING\|PRIVATE STATE IN THE SHARED CACHE' <<<"$out" \
        && ok "with its volume mounted and nothing left in the cache, 2c logs one quiet line" \
        || bad "2c with a volume and no legacy state (rc=$rc): $out"
    mkdir -p "$SB/cache/app/box"
    for i in 1 2 3 4 5 6 7; do : > "$SB/cache/app/box/s$i.sqlite"; done
    out="$(run_2c box "$TMPD/mi-vol")"
    grep -q 'PRIVATE STATE IN THE SHARED CACHE: 7 file(s)' <<<"$out" && grep -q '\.\.\. and 2 more' <<<"$out" \
        && ok "a long list is cut at five paths with a count of the rest" \
        || bad "2c must list at most five paths: $out"
    : > "$SB/not-a-dir"
    out="$(run_2c box "$TMPD/mi-vol" "$SB/not-a-dir/state")"; rc=$?
    (( rc == 0 )) && grep -q "WARNING: could not prepare $SB/not-a-dir/state" <<<"$out" \
        && ok "a state dir that cannot be made degrades loudly, it never stops the boot" \
        || bad "2c must warn and go on when the state dir cannot be prepared (rc=$rc): $out"
    : > "$SB/cache/app/top.db"
    out="$(run_2c .. "$TMPD/mi-vol")"; rc=$?
    (( rc == 0 )) && ! grep -q 'PRIVATE STATE' <<<"$out" \
        && ok "a name of '..' never widens the scan to the whole cache" \
        || bad "2c must refuse '.' and '..' as a container name (rc=$rc): $out"
fi

# ======================================================================================
echo "== the image, the template and SSH logins =="
grep -qE '^RUN install -d -o \$\{CLAUDE_UID\} -g \$\{CLAUDE_GID\} -m 700 /state$' "$REPO_ROOT/Dockerfile" \
    && ok "the image bakes /state owned by the agent user, mode 700 (a fresh volume is seeded so)" \
    || bad "the Dockerfile must create /state owned by the agent user, mode 700"
grep -qxF '[ -d /state ] && export CLAUDE_STATE_DIR=/state' "$REPO_ROOT/bash_profile" \
    && ok "bash_profile exports CLAUDE_STATE_DIR (sshd does not inherit the container env)" \
    || bad "bash_profile must export CLAUDE_STATE_DIR for SSH logins"
TPL="$REPO_ROOT/docker-compose.yml"
grep -qxF '      - claude-state:/state' "$TPL" && grep -qxF '      CLAUDE_STATE_DIR: /state' "$TPL" \
    && grep -qxF '    name: claude-state-${CLAUDE_PROJECT_NAME}' "$TPL" \
    && ok "the single-container compose template mounts its own claude-state-<project> at /state" \
    || bad "docker-compose.yml must mount claude-state-\${CLAUDE_PROJECT_NAME} at /state"
grep -q '/state/<app>' "$REPO_ROOT/claude-config/CLAUDE.md" && grep -q 'CLAUDE_STATE_DIR' "$REPO_ROOT/claude-config/CLAUDE.md" \
    && ok "the baked CLAUDE.md tells sessions where private state goes" \
    || bad "claude-config/CLAUDE.md must point private state at /state"

echo
echo "state-unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
