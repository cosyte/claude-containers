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
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
for f in bin/claude-launch bin/claude-compose-gen entrypoint.sh; do
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
if grep -qE 'find "\$SCRATCH_DIR" -mindepth 1' "$REPO_ROOT/entrypoint.sh"; then
    ok "the entrypoint clears scratch on boot (a volume does not self-empty like a tmpfs)"
else
    bad "the entrypoint must clear the scratch dir on boot"
fi
# sshd builds a fresh env, so an SSH login would silently fall back to /tmp without this.
grep -q 'export TMPDIR=/scratch' "$REPO_ROOT/bash_profile" \
    && ok "bash_profile re-exports TMPDIR (sshd does not inherit the container env)" \
    || bad "bash_profile must export TMPDIR so SSH logins get the disk-backed temp too"

echo
echo "launch-unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
