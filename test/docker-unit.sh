#!/usr/bin/env bash
# Unit tests for the --docker (inner Docker engine) surface — NO docker, NO sysbox, NO root.
#
# The feature: a session with its own Docker engine, so the agent can build images and run
# containers/compose stacks. The container runs under Sysbox, whose user namespace maps
# container-root to an unprivileged host uid — which is what makes an inner daemon safe with
# no --privileged and no host-socket mount (both remain forbidden: either would hand a
# prompt-injectable agent the host).
#
# This is NOT the retired worker broker (docs/legacy-sysbox-broker.md). It reuses that era's
# runtime and nothing else: no broker, no worker plane, no spool.
#
# What this covers, all of it reachable without a daemon:
#   - harden_run_args: cap-drop is skipped in docker mode, KEPT otherwise, NNP always
#   - docker_volume naming
#   - preflight_sysbox fails closed when the runtime is absent
#   - claude-launch flag parsing: --docker/--no-docker, and --sysbox pointing at --docker
#   - claude-compose-gen: per-service runtime/env/volume/label emission, and that a
#     non-docker service in the SAME stack keeps its cap-drop
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

# --- harden_run_args ------------------------------------------------------------------
# The crux of the whole design. An inner dockerd cannot run under the minimal cap set (it
# needs NET_ADMIN for its bridge/iptables and SYS_ADMIN to mount layers — neither is even
# in Docker's DEFAULT set), so docker mode must not cap-drop. That is safe only because
# Sysbox userns-scopes the caps; if someone ever drops the sysbox runtime while keeping
# this branch, they hand the agent real host caps. These tests pin both halves.
echo "== harden_run_args: docker mode skips cap-drop, ordinary mode keeps it =="

CLAUDE_HARDEN_CAPS=1
plain="$(harden_run_args)"
dock="$(harden_run_args 1)"

[[ "$plain" == *"--cap-drop ALL"* ]] \
    && ok "ordinary session still drops ALL caps" \
    || bad "ordinary session MUST keep --cap-drop ALL (got: $plain)"
[[ "$dock" != *"--cap-drop"* ]] \
    && ok "docker mode does not cap-drop (an inner daemon cannot start under the minimal set)" \
    || bad "docker mode must not cap-drop (got: $dock)"
[[ "$dock" != *"--cap-add"* ]] \
    && ok "docker mode adds no caps either (Sysbox grants the full set inside the userns)" \
    || bad "docker mode should not need explicit cap-adds (got: $dock)"
[[ "$plain" == *"no-new-privileges"* && "$dock" == *"no-new-privileges"* ]] \
    && ok "no-new-privileges is applied in BOTH modes (verified: nested build+run works with it)" \
    || bad "no-new-privileges must be applied in both modes"

# Explicit falsy values must behave like ordinary mode — a stray "0"/"" must never be read
# as "docker mode" and silently disarm the cap-drop.
for falsy in "" 0 no off false; do
    got="$(harden_run_args "$falsy")"
    [[ "$got" == *"--cap-drop ALL"* ]] \
        && ok "harden_run_args '$falsy' → still hardened (not mistaken for docker mode)" \
        || bad "harden_run_args '$falsy' must stay hardened (got: $got)"
done

# CLAUDE_HARDEN_CAPS=0 is the pre-existing opt-out; docker mode must not resurrect a drop.
CLAUDE_HARDEN_CAPS=0
[[ "$(harden_run_args 1)" != *"--cap-drop"* ]] \
    && ok "CLAUDE_HARDEN_CAPS=0 + docker mode: still no cap-drop" \
    || bad "CLAUDE_HARDEN_CAPS=0 + docker mode must not cap-drop"
CLAUDE_HARDEN_CAPS=1

# --- docker_volume --------------------------------------------------------------------
echo "== docker_volume: per-project inner image store =="
[[ "$(docker_volume foo)" == "claude-docker-foo" ]] \
    && ok "docker_volume foo → claude-docker-foo" \
    || bad "docker_volume foo → got '$(docker_volume foo)'"
[[ "$(docker_volume foo)" != "$(ws_volume foo)" && "$(docker_volume foo)" != "$(cfg_volume foo)" ]] \
    && ok "the image store is its own volume (never the workspace or config volume)" \
    || bad "docker_volume collides with an existing volume name"

# --- preflight_sysbox -----------------------------------------------------------------
# Must FAIL CLOSED on a host with no sysbox-runc. Without the runtime the inner daemon has
# no userns, and the container dies on an opaque 60s entrypoint timeout instead.
echo "== preflight_sysbox: fails closed when the runtime is absent =="
(
    # Stub `docker info` with a runtime list that has no sysbox-runc.
    docker() { [[ "$1" == "info" ]] && { echo "runc io.containerd.runc.v2"; return 0; }; return 1; }
    export -f docker 2>/dev/null
    out="$(preflight_sysbox 2>&1)"; rc=$?
    (( rc != 0 )) || { echo "  FAIL  preflight_sysbox must exit non-zero with no sysbox-runc"; exit 1; }
    [[ "$out" == *"Sysbox"* ]] || { echo "  FAIL  the error must name Sysbox and how to fix it"; exit 1; }
    # It must NOT suggest --privileged or a socket mount as a workaround.
    [[ "$out" != *"--privileged"* || "$out" == *"acceptable substitute"* ]] \
        || { echo "  FAIL  preflight must not offer --privileged as a fallback"; exit 1; }
    echo "  PASS  preflight_sysbox fails closed, names Sysbox, offers no unsafe fallback"
    exit 0
)
if (( $? == 0 )); then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi

(
    docker() { [[ "$1" == "info" ]] && { echo "runc sysbox-runc io.containerd.runc.v2"; return 0; }; return 1; }
    export -f docker 2>/dev/null
    preflight_sysbox >/dev/null 2>&1
)
[[ $? -eq 0 ]] \
    && ok "preflight_sysbox passes when sysbox-runc IS registered" \
    || bad "preflight_sysbox must pass when sysbox-runc is present"

# --- claude-launch flag surface --------------------------------------------------------
echo "== claude-launch: --docker / --no-docker / the retired --sysbox =="
LAUNCH="$REPO_ROOT/bin/claude-launch"

grep -qE -- '--docker\)' "$LAUNCH" \
    && ok "--docker is a recognized flag" || bad "--docker is not parsed"
grep -qE -- '--no-docker\)' "$LAUNCH" \
    && ok "--no-docker opts out of an ambient CLAUDE_DOCKER=1" || bad "--no-docker is not parsed"

# --sysbox was the BROKER's flag and stays dead — but its error must point at the live
# feature rather than dead-ending, since the runtime it named is exactly what --docker uses.
out="$("$LAUNCH" --sysbox x 2>&1)"; rc=$?
(( rc != 0 )) && [[ "$out" == *"--docker"* ]] \
    && ok "--sysbox still dies, but redirects to --docker" \
    || bad "--sysbox must die and point at --docker (rc=$rc, out=$out)"
for dead in --broker --worker-tarball; do
    out="$("$LAUNCH" "$dead" x 2>&1)"; rc=$?
    (( rc != 0 )) && ok "$dead is still a hard error (broker substrate stays retired)" \
        || bad "$dead must remain a hard error"
done

# The launcher must never reach for the two forbidden shortcuts. Strip comments first: the
# file *discusses* --privileged and the socket at length (explaining why they're forbidden),
# and matching prose would fail a correct implementation.
#
# Materialize the stripped text rather than piping into `grep -q`: this suite sets
# `pipefail`, where `producer | grep -q X` fails the pipeline on a MATCH (grep -q exits
# early, the producer takes SIGPIPE 141). That yields a test that reds CI at random.
code_only() { sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$1"; }
launch_code="$(code_only "$LAUNCH")"
entry_code="$(code_only "$REPO_ROOT/entrypoint.sh")"

if grep -qE -- '--privileged|/var/run/docker\.sock' <<<"$launch_code"; then
    bad "claude-launch must NEVER use --privileged or mount the host docker socket"
else
    ok "claude-launch mounts no host socket and grants no --privileged"
fi
if grep -qE -- '--privileged' <<<"$entry_code"; then
    bad "entrypoint must NEVER grant --privileged"
else
    ok "entrypoint grants no --privileged (Sysbox's userns is the whole mechanism)"
fi

# --- claude-compose-gen emission -------------------------------------------------------
echo "== claude-compose-gen: per-service docker emission =="
OUT="$TMPD/dc.yml"
# Stub the host preflight + image inspection so this stays docker-free.
PATH_STUB="$TMPD/stub"; mkdir -p "$PATH_STUB"
cat > "$PATH_STUB/docker" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    info)   echo "runc sysbox-runc" ;;               # pretend Sysbox is installed
    image)  echo "1" ;;                              # pretend the variant images exist
    volume) exit 0 ;;
    *)      exit 0 ;;
esac
STUB
chmod +x "$PATH_STUB/docker"

PATH="$PATH_STUB:$PATH" "$REPO_ROOT/bin/claude-compose-gen" \
    --out "$OUT" --active api --docker api --browser web --docker web \
    acme/api acme/web acme/plain >/dev/null 2>&1

if [[ ! -s "$OUT" ]]; then
    bad "compose-gen produced no file — the rest of this section is void"
else
    svc_block() {  # svc_block <service> — that service's YAML only
        awk -v s="  $1:" 'index($0,s)==1{f=1;next} f && /^  [a-z0-9-]+:$/{exit} f{print}' "$OUT"
    }
    api="$(svc_block api)"; web="$(svc_block web)"; plain="$(svc_block plain)"

    [[ "$api" == *"runtime: sysbox-runc"* ]] \
        && ok "a --docker service runs under sysbox-runc" \
        || bad "a --docker service must emit 'runtime: sysbox-runc'"
    [[ "$api" == *'CLAUDE_DOCKER: "1"'* ]] \
        && ok "a --docker service gets CLAUDE_DOCKER=1 (the entrypoint's dockerd gate)" \
        || bad "a --docker service must set CLAUDE_DOCKER=1"
    [[ "$api" == *"claude-docker-api:/var/lib/docker"* ]] \
        && ok "a --docker service mounts its own image store at /var/lib/docker" \
        || bad "a --docker service must mount claude-docker-<svc> at /var/lib/docker"
    [[ "$api" != *"cap_drop"* ]] \
        && ok "a --docker service does not cap-drop (the daemon needs the caps Sysbox scopes)" \
        || bad "a --docker service must not cap_drop"
    [[ "$api" == *"no-new-privileges"* ]] \
        && ok "a --docker service still sets no-new-privileges" \
        || bad "a --docker service must keep no-new-privileges"

    # The regression that matters most: docker mode must relax hardening for ITS service
    # only. A lean sibling in the same stack keeps every control it had.
    [[ "$plain" == *"cap_drop"* && "$plain" != *"runtime: sysbox-runc"* ]] \
        && ok "a NON-docker service in the same stack keeps cap_drop and plain runc" \
        || bad "docker mode leaked into a non-docker service (cap_drop/runtime)"
    [[ "$plain" != *"/var/lib/docker"* ]] \
        && ok "a non-docker service gets no image-store volume" \
        || bad "a non-docker service must not mount an image store"

    # Baked, not mounted: a service that is both needs the image that has both.
    [[ "$web" == *"claude-code-box:docker-browser"* ]] \
        && ok "--docker + --browser selects the combined image" \
        || bad "--docker + --browser must select the docker-browser image"

    # Top-level volume declarations, only for docker services.
    grep -qE '^  claude-docker-api:' "$OUT" \
        && ok "the image store is declared as a top-level volume" \
        || bad "claude-docker-api must be declared under volumes:"
    grep -qE '^  claude-docker-plain:' "$OUT" \
        && bad "a non-docker service must not get an image-store volume declaration" \
        || ok "no image-store volume is declared for the non-docker service"

    # Never the forbidden shortcuts, in generated YAML either.
    grep -qE 'privileged:\s*true|/var/run/docker\.sock' "$OUT" \
        && bad "generated compose must NEVER use privileged: true or mount the host socket" \
        || ok "generated compose grants no privileged and mounts no host socket"
fi

# --- Disk-backed scratch (TMPDIR) ------------------------------------------------------
# /tmp is a tmpfs: RAM, 1g, charged to the memory cgroup. Anything honoring TMPDIR — pip/uv
# wheel builds, `docker save|load`, the inner containerd's mount dirs — hits that wall and
# dies with ENOSPC while the pool has terabytes free. These pin the fix: temp goes to disk.
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
        ok "compose-gen gives every service the scratch volume + TMPDIR"
    else
        bad "compose-gen must mount claude-scratch-<svc>:/scratch and set TMPDIR"
    fi
    grep -qE '^  claude-scratch-api:' "$OUT" \
        && ok "the scratch volume is declared top-level" \
        || bad "claude-scratch-api must be declared under volumes:"
    # Stack-owned, so a --mount naming it must be refused (else it is declared twice: once by
    # us, once as external — a duplicate YAML key — and `down -v` could delete another
    # stack's scratch).
    # Capture, don't pipe: the generator DIES here (exit 1) — that is the pass condition — and
    # under `pipefail` a `cmd | grep -q` pipeline would report that exit as failure even though
    # grep matched. Same trap that made test/unit.sh flaky.
    dup_out="$("$REPO_ROOT/bin/claude-compose-gen" --out "$TMPD/dup.yml" \
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

echo "docker-unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
