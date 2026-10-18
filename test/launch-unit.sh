#!/usr/bin/env bash
# Unit tests for what claude-launch and claude-compose-gen put at the container boundary:
# NO docker daemon, NO root.
#
# What this covers, all of it reachable without a daemon:
#   - harden_run_args: cap-drop ALL + the minimal set, no-new-privileges always
#   - the forbidden shortcuts: no --privileged, no host docker socket, anywhere
#   - removed flags refuse, naming the removal (never a silent no-op)
#   - claude-compose-gen emission: every service on plain runc, cap_drop kept
#   - the disk-backed scratch (TMPDIR) that keeps big installs off the 1g /tmp tmpfs
#   - --containers: exactly the options it adds (launch and compose), nothing privileged, the
#     host checks, and every other session unchanged; containers/seccomp.json is its filter's
# shellcheck source=test/lib/prelude.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/prelude.sh"
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/lib/entrypoint.sh
source "$REPO_ROOT/test/lib/entrypoint.sh"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# shellcheck disable=SC1091
source "$REPO_ROOT/bin/_common.sh"
set +e

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

LAUNCH="$REPO_ROOT/bin/claude-launch"
GEN="$REPO_ROOT/bin/claude-compose-gen"

# --- harden_run_args ------------------------------------------------------------------
echo "== harden_run_args: every session drops ALL caps and sets no-new-privileges =="
h="$(harden_run_args)"
[[ "$h" == *"--cap-drop ALL"* ]] \
    && ok "a session drops ALL caps" || bad "a session must drop ALL caps (got: $h)"
[[ "$h" == *"--security-opt no-new-privileges"* ]] \
    && ok "no-new-privileges is applied" || bad "no-new-privileges missing (got: $h)"
[[ "$h" != *"SYS_ADMIN"* && "$h" != *"NET_ADMIN"* ]] \
    && ok "no SYS_ADMIN, and no NET_ADMIN unless egress lockdown asks for it" \
    || bad "an admin capability leaked into the default set (got: $h)"
h="$(CLAUDE_EGRESS_LOCKDOWN=strict harden_run_args)"
[[ "$h" == *"--cap-add NET_ADMIN"* ]] \
    && ok "egress lockdown (strict too) adds NET_ADMIN for the root-only firewall" \
    || bad "strict lockdown must add NET_ADMIN (got: $h)"
h="$(CLAUDE_HARDEN_CAPS=0 harden_run_args)"
[[ "$h" != *"--cap-drop"* && "$h" == *"no-new-privileges"* ]] \
    && ok "CLAUDE_HARDEN_CAPS=0 keeps Docker's default set but still sets no-new-privileges" \
    || bad "CLAUDE_HARDEN_CAPS=0 must skip only the cap-drop (got: $h)"

# --- the forbidden shortcuts ------------------------------------------------------------
# Strip comments first: the files *discuss* --privileged and the socket (explaining why
# they are forbidden), and matching prose would fail a correct implementation.
# Materialize the stripped text rather than piping into `grep -q`: this suite sets
# `pipefail`, where `producer | grep -q X` fails the pipeline on a MATCH (grep -q exits
# early, the producer takes SIGPIPE 141). That yields a test that reds CI at random.
echo "== no --privileged and no host docker socket =="
code_only() { sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$1"; }
launch_code="$(code_only "$LAUNCH")"
for f in bin/claude-launch bin/claude-compose-gen entrypoint.sh $(cd "$REPO_ROOT" && echo entrypoint.d/*.sh); do
    if grep -qE -- '--privileged|privileged:|/var/run/docker\.sock' <<<"$(code_only "$REPO_ROOT/$f")"; then
        bad "$f must NEVER grant privileged or mount the host docker socket"
    else
        ok "$f grants no privileged and mounts no host docker socket"
    fi
done

# --- removed flags refuse ---------------------------------------------------------------
# A removed flag must refuse, not silently no-op (CONTRIBUTING.md): a scenario .conf that
# still carries --docker would otherwise regenerate into a service without the engine it
# asked for, and nobody would find out until a build failed inside it.
echo "== removed flags are hard errors that name the removal =="
for flag in --docker --no-docker --sysbox; do
    out="$("$LAUNCH" x "$flag" 2>&1)"; rc=$?
    (( rc != 0 )) && [[ "$out" == *"$flag was removed"* && "$out" == *"Docker engine"* ]] \
        && ok "claude-launch $flag dies and names the removed Docker engine" \
        || bad "claude-launch $flag must die naming the removal (rc=$rc, out=$out)"
    out="$("$GEN" --out "$TMPD/x.yml" "$flag" api acme/api 2>&1)"; rc=$?
    (( rc != 0 )) && [[ "$out" == *"$flag was removed"* && "$out" == *"scenario .conf"* ]] \
        && ok "claude-compose-gen $flag dies and says to drop it from the .conf" \
        || bad "claude-compose-gen $flag must die naming the removal (rc=$rc, out=$out)"
    [[ ! -e "$TMPD/x.yml" ]] \
        && ok "claude-compose-gen $flag wrote no compose file" \
        || { bad "claude-compose-gen $flag must not write a compose file"; rm -f "$TMPD/x.yml"; }
done
for dead in --broker --worker-tarball; do
    out="$("$LAUNCH" x "$dead" 2>&1)"; rc=$?
    (( rc != 0 )) && [[ "$out" == *"was removed"* ]] \
        && ok "claude-launch $dead is still a hard error (broker substrate stays retired)" \
        || bad "claude-launch $dead must remain a hard error"
done
out="$(CLAUDE_DOCKER=1 "$LAUNCH" x 2>&1)"; rc=$?
(( rc != 0 )) && [[ "$out" == *"CLAUDE_DOCKER=1 is set"* && "$out" == *"removed"* ]] \
    && ok "an ambient CLAUDE_DOCKER=1 refuses the launch and says to delete the line" \
    || bad "CLAUDE_DOCKER=1 must refuse (rc=$rc, out=$out)"
out="$(CLAUDE_DOCKER=0 "$LAUNCH" 2>&1)"
[[ "$out" != *"was removed"* && "$out" != *"CLAUDE_DOCKER"* ]] \
    && ok "CLAUDE_DOCKER=0 (a copied .env.example line) is inert" \
    || bad "CLAUDE_DOCKER=0 must not trip the removal refusal: $out"

# --- compose emission -------------------------------------------------------------------
echo "== claude-compose-gen: every service on plain runc, hardened =="
OUT="$TMPD/dc.yml"
# Stub docker so this stays daemon-free.
PATH_STUB="$TMPD/stub"; mkdir -p "$PATH_STUB"
cat > "$PATH_STUB/docker" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    image)  echo "1" ;;      # pretend the variant images exist and are labelled
    *)      exit 0 ;;
esac
STUB
chmod +x "$PATH_STUB/docker"

PATH="$PATH_STUB:$PATH" CLAUDE_PORTS_USED_OVERRIDE="" "$GEN" \
    --out "$OUT" --active api --browser web \
    acme/api acme/web acme/plain >/dev/null 2>&1

svc_block() {  # svc_block <service>: that service's YAML only
    awk -v s="  $1:" 'index($0,s)==1{f=1;next} f && /^  [a-z0-9-]+:$/{exit} f{print}' "$OUT"
}
if [[ ! -s "$OUT" ]]; then
    bad "compose-gen produced no file: the rest of this section is void"
else
    for svc in api web plain; do
        blk="$(svc_block "$svc")"
        [[ "$blk" != *"runtime:"* ]] \
            && ok "$svc: no runtime: line (plain runc)" || bad "$svc must not set a runtime"
        grep -qE '^    cap_drop:$' <<<"$blk" && grep -qE '^      - ALL$' <<<"$blk" \
            && ok "$svc: cap_drop ALL" || bad "$svc must cap_drop ALL"
        grep -q 'no-new-privileges:true' <<<"$blk" \
            && ok "$svc: no-new-privileges" || bad "$svc must set no-new-privileges"
        [[ "$blk" != *"claude.docker"* && "$blk" != *"WITH_DOCKER"* && "$blk" != *"CLAUDE_DOCKER"* ]] \
            && ok "$svc: no Docker-engine label, build arg or env" \
            || bad "$svc still carries a Docker-engine label/arg/env"
    done
    grep -qE 'privileged:|/var/run/docker\.sock' "$OUT" \
        && bad "generated compose must NEVER use privileged or mount the host socket" \
        || ok "generated compose grants no privileged and mounts no host socket"
    grep -q 'WITH_BROWSER: "1"' <<<"$(svc_block web)" && grep -q 'claude-code-box:browser' <<<"$(svc_block web)" \
        && ok "a --browser service still builds and runs the browser image" \
        || bad "a --browser service must select the browser image and build arg"
fi

# --- Disk-backed scratch (TMPDIR) ------------------------------------------------------
# /tmp is a tmpfs: RAM, 1g, charged to the memory cgroup. Anything honoring TMPDIR (pip/uv
# wheel builds, big archives) hits that wall and dies with ENOSPC while the pool has
# terabytes free. These pin the fix: temp goes to a disk-backed volume.
echo "== scratch volume: TMPDIR is disk-backed, not the RAM tmpfs =="

[[ "$(scratch_volume foo)" == "claude-scratch-foo" ]] \
    && ok "scratch_volume foo → claude-scratch-foo" \
    || bad "scratch_volume foo → got '$(scratch_volume foo)'"

if grep -qE -- '-e TMPDIR=/scratch' <<<"$launch_code" && grep -qE 'scratch_volume .*:/scratch' <<<"$launch_code"; then
    ok "claude-launch mounts the scratch volume and points TMPDIR at it"
else
    bad "claude-launch must mount claude-scratch-<proj> at /scratch and set TMPDIR=/scratch"
fi
# The regression that would silently undo all of this: TMPDIR left on the tmpfs.
grep -qE -- '-e TMPDIR=/tmp' <<<"$launch_code" \
    && bad "TMPDIR must NOT point at /tmp (that is the 1g RAM tmpfs this fixes)" \
    || ok "TMPDIR does not point back at the tmpfs"

if [[ -s "$OUT" ]]; then
    if grep -q 'TMPDIR: "/scratch"' "$OUT" && grep -q 'claude-scratch-api:/scratch' "$OUT"; then
        ok "compose-gen gives a build service the scratch volume + TMPDIR"
    else
        bad "compose-gen must mount claude-scratch-<svc>:/scratch and set TMPDIR"
    fi
    grep -qE '^  claude-scratch-api:' "$OUT" \
        && ok "the scratch volume is declared top-level" \
        || bad "claude-scratch-api must be declared under volumes:"
    # Stack-owned, so a --mount naming it must be refused (else it is declared twice: once by
    # us, once as external: a duplicate YAML key, and `down -v` could delete another
    # stack's scratch).
    # Capture, don't pipe: the generator DIES here (exit 1), that is the pass condition, and
    # under `pipefail` a `cmd | grep -q` pipeline would report that exit as failure even though
    # grep matched.
    dup_out="$(PATH="$PATH_STUB:$PATH" "$GEN" --out "$TMPD/dup.yml" \
                 --mount api=claude-scratch-api:/x acme/api 2>&1 || true)"
    if grep -q 'already managed by this stack' <<<"$dup_out"; then
        ok "--mount naming this stack's own scratch volume is refused"
    else
        bad "--mount of claude-scratch-<svc> must be refused (it is stack-owned)"
    fi
fi

# The entrypoint must CLEAR scratch on boot: it is a volume, so unlike a tmpfs it survives
# restarts and would otherwise accumulate abandoned wheel builds until the pool fills.
if grep -qE 'find "\$SCRATCH_DIR" -mindepth 1' "$(ep_section 2a)"; then
    ok "the entrypoint clears scratch on boot (a volume does not self-empty like a tmpfs)"
else
    bad "the entrypoint must clear the scratch dir on boot"
fi
# sshd builds a fresh env, so an SSH login would silently fall back to /tmp without this.
grep -q 'export TMPDIR=/scratch' "$REPO_ROOT/bash_profile" \
    && ok "bash_profile re-exports TMPDIR (sshd does not inherit the container env)" \
    || bad "bash_profile must export TMPDIR so SSH logins get the disk-backed temp too"

# --- --containers ------------------------------------------------------------------------
# A --containers session adds exactly the options the owner chose (docs/containers-in-sessions.md,
# helper mode) and nothing else: never privileged, never SYS_ADMIN, never a host socket, and
# cap-drop ALL and no-new-privileges kept. A session without it is unchanged.
echo "== --containers: exactly its options, nothing privileged, others unchanged =="
CSTUB="$TMPD/cstub"; mkdir -p "$CSTUB" "$TMPD/cws"
cat > "$CSTUB/docker" <<'STUB'
#!/usr/bin/env bash
d="${STUB_STATE:?}"
case "$1" in
    inspect) [[ -e "$d/created" ]] && { echo running; exit 0; }; exit 1 ;;
    run)     shift; printf '%s\n' "$@" > "$d/run-args"; touch "$d/created"; echo deadbeef ;;
    *)       exit 0 ;;
esac
STUB
printf '#!/bin/sh\nexit 0\n' > "$CSTUB/sleep"
chmod +x "$CSTUB/docker" "$CSTUB/sleep"
# /dev/null stands in for /dev/net/tun: a character device on every host.
claunch() {   # claunch <env...> -- <args...>: run-args in $TMPD/run-args, log in $TMPD/claunch.log
    local envs=()
    while [[ "$1" != -- ]]; do envs+=("$1"); shift; done; shift
    rm -f "$TMPD/run-args" "$TMPD/created"
    env -u CLAUDE_CONTAINERS STUB_STATE="$TMPD" PATH="$CSTUB:$PATH" CLAUDE_PORTS_USED_OVERRIDE="" \
        CLAUDE_CONTAINERS_TUN_DEV=/dev/null CLAUDE_CONTAINERS_USERNS_SYSCTL="$TMPD/no-sysctl" "${envs[@]}" \
        "$LAUNCH" ctest --workspace "$TMPD/cws" --port 2297 "$@" >"$TMPD/claunch.log" 2>&1
}
want_extra="--security-opt
seccomp=$REPO_ROOT/containers/seccomp.json
--security-opt
apparmor=unconfined
--security-opt
systempaths=unconfined
--device
/dev/null
-v
claude-containers-ctest:/home/claude/.local/share/containers
-e
CLAUDE_CONTAINERS=1"
claunch -- ; rc=$?; cp "$TMPD/run-args" "$TMPD/run-plain" 2>/dev/null
(( rc == 0 )) && [[ -s "$TMPD/run-plain" ]] && ! grep -qE 'CLAUDE_CONTAINERS|claude-containers-ctest|unconfined|seccomp|/dev/net/tun|DOCKER_HOST' "$TMPD/run-plain" \
    && ok "a launch without --containers adds none of its options" \
    || bad "a launch without --containers must be unchanged (rc=$rc): $(grep -E 'CONTAINERS|unconfined|seccomp' "$TMPD/run-plain" 2>/dev/null | tr '\n' ' ')"
claunch -- --containers; rc=$?
extra="$(diff <(cat "$TMPD/run-plain") "$TMPD/run-args" 2>/dev/null | sed -n 's/^> //p')"
(( rc == 0 )) && [[ "$extra" == "$want_extra" ]] \
    && ok "--containers adds exactly seccomp, apparmor and systempaths unconfined, the tun device, the store volume and CLAUDE_CONTAINERS=1" \
    || bad "--containers must add exactly its options (rc=$rc); added: ${extra//$'\n'/ }"
removed="$(diff <(cat "$TMPD/run-plain") "$TMPD/run-args" 2>/dev/null | sed -n 's/^< //p')"
[[ -z "$removed" ]] && grep -qx -- --cap-drop "$TMPD/run-args" && grep -qx no-new-privileges "$TMPD/run-args" \
    && ok "--containers keeps every other option: cap-drop ALL and no-new-privileges stay" \
    || bad "--containers must not drop an option; dropped: ${removed//$'\n'/ }"
grep -qiE -- 'privileged|SYS_ADMIN|docker\.sock|^--cap-add$' <<<"$extra" \
    && bad "--containers must add no privilege, no capability and no socket: $extra" \
    || ok "--containers adds no privileged, no capability and no Docker socket"
claunch CLAUDE_CONTAINERS_TUN_DEV="$TMPD/no-tun" -- --containers; rc=$?
(( rc != 0 )) && [[ ! -e "$TMPD/run-args" ]] && grep -q -- "--containers: this host has no $TMPD/no-tun" "$TMPD/claunch.log" \
    && ok "--containers on a host without /dev/net/tun refuses before docker run" \
    || bad "--containers without a tun device must refuse (rc=$rc): $(tail -2 "$TMPD/claunch.log")"
echo 1 > "$TMPD/userns-restricted"
claunch CLAUDE_CONTAINERS_USERNS_SYSCTL="$TMPD/userns-restricted" -- --containers; rc=$?
(( rc != 0 )) && [[ ! -e "$TMPD/run-args" ]] && grep -q "lets only AppArmor-profiled programs create user namespaces" "$TMPD/claunch.log" \
    && ok "--containers on a host restricting user namespaces (Ubuntu's AppArmor sysctl) refuses" \
    || bad "--containers with apparmor_restrict_unprivileged_userns=1 must refuse (rc=$rc): $(tail -2 "$TMPD/claunch.log")"
echo 0 > "$TMPD/userns-open"
claunch CLAUDE_CONTAINERS_USERNS_SYSCTL="$TMPD/userns-open" -- --containers; rc=$?
(( rc == 0 )) && ok "the sysctl at 0 lets --containers through" || bad "the sysctl at 0 must not refuse: $(tail -2 "$TMPD/claunch.log")"

# compose: the same options as YAML on the --containers service only.
COUT="$TMPD/cdc.yml"
cgen() { env STUB_STATE="$TMPD" PATH="$CSTUB:$PATH" CLAUDE_PORTS_USED_OVERRIDE="" CLAUDE_CONTAINERS_TUN_DEV=/dev/net/tun \
    "$GEN" "$@" >"$TMPD/cgen.log" 2>&1; }
cgen --out "$TMPD/cdc-plain.yml" acme/api acme/web
cgen --out "$COUT" --containers api acme/api acme/web; rc=$?
OUT="$COUT"
blk="$(svc_block api)"
(( rc == 0 )) && [[ "$(sed -n '/^    devices:$/,/^    [a-z_]*:$/p' <<<"$blk" | sed '$d')" == $'    devices:\n      - /dev/net/tun' ]] \
    && ok "compose: the --containers service gets /dev/net/tun and no other device" \
    || bad "compose: devices must be exactly /dev/net/tun (rc=$rc): $(grep -A3 'devices:' <<<"$blk" | tr '\n' ' ')"
[[ "$(sed -n '/^    security_opt:$/,/^    [a-z_]*:$/p' <<<"$blk" | sed '$d')" == "    security_opt:
      - no-new-privileges:true
      - \"seccomp=$REPO_ROOT/containers/seccomp.json\"
      - apparmor=unconfined
      - systempaths=unconfined" ]] \
    && ok "compose: security_opt is no-new-privileges plus exactly seccomp, apparmor and systempaths" \
    || bad "compose: security_opt is wrong: $(grep -A5 'security_opt:' <<<"$blk" | tr '\n' ' ')"
grep -qE '^      CLAUDE_CONTAINERS: "1"$' <<<"$blk" && grep -qE '^      - claude-containers-api:/home/claude/\.local/share/containers$' <<<"$blk" \
    && grep -qE '^  claude-containers-api:$' "$COUT" \
    && ok "compose: CLAUDE_CONTAINERS=1, the store volume mounted and declared" \
    || bad "compose: the --containers service needs CLAUDE_CONTAINERS and its store volume"
grep -qE '^    cap_drop:$' <<<"$blk" && ! grep -qE 'privileged|SYS_ADMIN|docker\.sock' <<<"$blk" \
    && ok "compose: cap_drop ALL kept, nothing privileged" \
    || bad "compose: the --containers service must keep cap_drop and add nothing privileged"
OUT="$TMPD/cdc-plain.yml"; web_plain="$(svc_block web)"; api_plain="$(svc_block api)"
OUT="$COUT"; web_c="$(svc_block web)"
[[ -n "$web_plain" && "$web_plain" == "$web_c" ]] \
    && ok "compose: the service without --containers is byte-identical" \
    || bad "compose: --containers on api must not change web"
! grep -qE 'claude-containers-api|unconfined|seccomp|/dev/net/tun|CLAUDE_CONTAINERS' "$TMPD/cdc-plain.yml" \
    && [[ "$(diff <(cat <<<"$api_plain") <(cat <<<"$blk") | grep -c '^>')" == 7 && "$(diff <(cat <<<"$api_plain") <(cat <<<"$blk") | grep -c '^<')" == 0 ]] \
    && ok "compose: a stack without --containers carries none of it; with it, api only gains its 7 lines" \
    || bad "compose: the plain stack must be unchanged and api gain only its lines: $(diff <(cat <<<"$api_plain") <(cat <<<"$blk") | tr '\n' ' ')"
cgen --out "$TMPD/cdc-bad.yml" --containers nosuch acme/api; rc=$?
(( rc != 0 )) && grep -q -- "--containers names 'nosuch', which is not a repo" "$TMPD/cgen.log" \
    && ok "compose: --containers naming no repo of the stack refuses" \
    || bad "compose: --containers nosuch must refuse (rc=$rc)"

# The ownership passes leave a nested container's ids alone (postgres's 999 is 100998 here): a
# real find over a tree holding the agent's file and a "nested" one, with chown recorded.
# shellcheck disable=SC2034  # read by the extracted own_tree
own_out="$(
    CLAUDE_UID=1000 CLAUDE_GID=1000
    eval "$(sed -n '/^OWN_TREE_KEEP_IDS=/,/^}/p' "$REPO_ROOT/entrypoint.sh")"
    find() { printf '%s\n' "$*"; }
    own_tree /ws; OWN_TREE_KEEP_IDS="100000 165535"; own_tree /ws
)"
[[ "$(sed -n 1p <<<"$own_out")" == '/ws ( ! -uid 1000 -o ! -gid 1000 ) -execdir chown -h 1000:1000 {} +' \
   && "$(sed -n 2p <<<"$own_out")" == '/ws ( ! -uid 1000 -o ! -gid 1000 ) ! ( -uid +99999 -uid -165536 ) -execdir chown -h 1000:1000 {} +' ]] \
    && grep -q 'OWN_TREE_KEEP_IDS="$CONTAINERS_SUBID_START' "$(ep_section 2d)" \
    && ok "own_tree is unchanged by default and skips the subordinate range on a --containers session" \
    || bad "own_tree must skip uids 100000..165535 only when §2d sets OWN_TREE_KEEP_IDS: $own_out"

# §2d creates the agent's podman store dirs without following a symlink the agent may have
# left at ~/.local. The shipped snippet is extracted and run in a sandbox with asclaude stubbed
# to run as the test user: a planted ~/.local symlink must be removed (never followed) and the
# store dir created inside the real home, never in the link's target.
D2D="$(sed -n '/for _d in "\$CLAUDE_HOME\/\.local"/,/asclaude chmod 700 "\$CONTAINERS_STORE_DIR"/p' "$(ep_section 2d)")"
LINKD="$(mktemp -d)"
mkdir -p "$LINKD/outside"
ln -s "$LINKD/outside" "$LINKD/home/.local" 2>/dev/null || { mkdir -p "$LINKD/home"; ln -s "$LINKD/outside" "$LINKD/home/.local"; }
(
    set -euo pipefail
    asclaude() { "$@"; }
    export CLAUDE_HOME="$LINKD/home"
    CONTAINERS_STORE_DIR="$LINKD/home/.local/share/containers"
    eval "$D2D"
) >/dev/null 2>&1
if [[ -n "$D2D" && ! -L "$LINKD/home/.local" && -d "$LINKD/home/.local/share/containers" \
   && ! -e "$LINKD/outside/share" ]]; then
    ok "§2d removed the ~/.local symlink and made the store dir inside the real home"
else
    bad "§2d followed the ~/.local symlink or did not create the store dir (local=$(stat -c %F "$LINKD/home/.local" 2>&1), outside/share exists: $([[ -e "$LINKD/outside/share" ]] && echo yes || echo no))"
fi
[[ "$(stat -c %a "$LINKD/home/.local/share/containers" 2>/dev/null)" == 700 ]] \
    && ok "§2d store dir is mode 700" \
    || bad "§2d store dir is not mode 700: $(stat -c %a "$LINKD/home/.local/share/containers" 2>&1)"
rm -rf "$LINKD"

# The profile is the vendored upstream through containers/seccomp.jq, nothing else.
if command -v jq >/dev/null 2>&1; then
    diff -q <(jq -f "$REPO_ROOT/containers/seccomp.jq" "$REPO_ROOT/containers/seccomp-upstream.json") \
        <(jq . "$REPO_ROOT/containers/seccomp.json") >/dev/null \
        && ok "containers/seccomp.json is containers/seccomp-upstream.json through containers/seccomp.jq" \
        || bad "containers/seccomp.json differs from its filter's output: rebuild it with jq -f containers/seccomp.jq"
else
    bad "jq is needed to check containers/seccomp.json"
fi

echo
echo "launch-unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
