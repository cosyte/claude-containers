#!/usr/bin/env bash
# Unit tests for --gpu: NO docker daemon, NO GPU, NO root.
#
#   - claude-compose-gen: a GPU service gets the CDI device, a RAM /scratch and
#     CLAUDE_GPU=1 on plain runc with cap_drop ALL kept; a non-GPU service is untouched;
#     an unknown repo is an error
#   - claude-launch --gpu / --no-gpu: the docker run arguments (docker is stubbed)
#   - claude-gpu: the state machine against a fake nvidia-smi on PATH (idle, a busy
#     co-tenant, short VRAM, busy-then-free, out-of-memory then CPU retry, NVML failure,
#     a hung nvidia-smi, no device), and the device contract a CPU run gets
#   - claude-blender-install: a checksum mismatch fails closed; the happy path is atomic
#     and idempotent
#   - entrypoint.sh §2b: a broken GPU degrades loudly and never stops the boot
#   - claude-healthcheck: a degraded GPU is reported and never fails health
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

GEN="$REPO_ROOT/bin/claude-compose-gen"
LAUNCH="$REPO_ROOT/bin/claude-launch"
GUARD="$REPO_ROOT/bin/claude-gpu"
INSTALL="$REPO_ROOT/bin/claude-blender-install"

# A docker stub: answers the generator's and the launcher's read-only questions, records
# `docker run` arguments, and lists the CDI device unless STUB_NO_CDI=1.
STUBD="$TMPD/stub"; mkdir -p "$STUBD"
cat > "$STUBD/docker" <<'STUB'
#!/usr/bin/env bash
d="${STUB_STATE:?}"
case "$1" in
    info)
        if [[ "$*" == *DiscoveredDevices* ]]; then
            [[ "${STUB_NO_CDI:-0}" == 1 ]] || echo "nvidia.com/gpu=0 nvidia.com/gpu=all "
        else
            echo "ok"
        fi ;;
    inspect) [[ -e "$d/created" ]] && { echo running; exit 0; }; exit 1 ;;
    image)   [[ "$*" == *Labels* ]] && echo 0; exit 0 ;;
    volume)  exit 0 ;;
    ps)      exit 0 ;;
    run)     shift; printf '%s\n' "$@" > "$d/run-args"; touch "$d/created"; echo deadbeef ;;
    *)       exit 0 ;;
esac
STUB
chmod +x "$STUBD/docker"

svc_block() {  # svc_block <file> <service>: that service's YAML only
    awk -v s="  $2:" 'index($0,s)==1{f=1;next} f && /^  [a-z0-9-]+:$/{exit} f{print}' "$1"
}

# ======================================================================================
echo "== claude-compose-gen --gpu =="
OUT="$TMPD/gpu.yml"
gen_out="$(STUB_STATE="$TMPD" PATH="$STUBD:$PATH" CLAUDE_PORTS_USED_OVERRIDE="" "$GEN" \
    --out "$OUT" --gpu api --browser web --gpu web acme/api acme/web acme/plain 2>&1)"
if [[ ! -s "$OUT" ]]; then
    bad "compose-gen --gpu produced no file: $gen_out"
else
    api="$(svc_block "$OUT" api)"; web="$(svc_block "$OUT" web)"; plain="$(svc_block "$OUT" plain)"
    grep -qE '^    devices:$' <<<"$api" && grep -qE '^      - nvidia\.com/gpu=all$' <<<"$api" \
        && ok "a GPU service gets the CDI device nvidia.com/gpu=all" \
        || bad "a GPU service must list devices: - nvidia.com/gpu=all"
    [[ "$api" != *"runtime:"* ]] \
        && ok "a GPU service sets no runtime: (plain runc, not the nvidia runtime)" \
        || bad "a GPU service must not set a runtime"
    grep -qE '^    cap_drop:$' <<<"$api" && grep -qE '^      - ALL$' <<<"$api" \
        && grep -q 'no-new-privileges:true' <<<"$api" \
        && ok "a GPU service keeps cap_drop ALL and no-new-privileges" \
        || bad "a GPU service must keep cap_drop ALL and no-new-privileges"
    if grep -qE '^    cap_add:$' <<<"$api"; then
        caps="$(awk '/^    cap_add:$/{f=1;next} f && /^      - /{print $2; next} f{exit}' <<<"$api" | tr '\n' ' ')"
        [[ " $caps " != *" SYS_ADMIN "* && " $caps " != *" NET_ADMIN "* && " $caps " != *" SYS_PTRACE "* ]] \
            && ok "a GPU service adds no capability beyond the minimal set ($caps)" \
            || bad "a GPU service must add no extra capability (got: $caps)"
    fi
    [[ "$api" != *"privileged"* && "$api" != *"network_mode: host"* && "$api" != *"docker.sock"* ]] \
        && ok "a GPU service gets no privilege, no host network, no docker socket" \
        || bad "a GPU service must not be privileged, on the host network, or given the socket"
    grep -q -- '- /scratch:rw,nosuid,nodev,exec,size=4g' <<<"$api" && grep -q 'TMPDIR: "/scratch"' <<<"$api" \
        && ok "a GPU service puts /scratch (TMPDIR) on a 4g RAM tmpfs" \
        || bad "a GPU service must mount /scratch as a tmpfs and point TMPDIR at it"
    [[ "$api" != *"claude-scratch-api:/scratch"* ]] && ! grep -qE '^  claude-scratch-api:' "$OUT" \
        && ok "a GPU service has no disk scratch volume (mounted or declared)" \
        || bad "a GPU service must not mount or declare claude-scratch-<svc>"
    grep -q 'CLAUDE_GPU: "1"' <<<"$api" \
        && ok "a GPU service sets CLAUDE_GPU=1 for the entrypoint and healthcheck" \
        || bad "a GPU service must set CLAUDE_GPU=1"
    grep -q -- '- /scratch:rw,nosuid,nodev,exec,size=4g' <<<"$web" \
        && ok "a GPU + browser service gets the larger of the two scratch sizes (4g over 3g)" \
        || bad "a GPU + browser service must get the larger scratch size"
    [[ "$plain" != *"nvidia.com"* && "$plain" != *"CLAUDE_GPU"* && "$plain" != *"devices:"* ]] \
        && grep -q 'claude-scratch-plain:/scratch' <<<"$plain" \
        && ok "a non-GPU service in the same stack gets no device, no CLAUDE_GPU, and keeps its disk scratch" \
        || bad "a non-GPU service must be untouched by --gpu"
    grep -q 'claude-plain.*ACTIVE$' <<<"$gen_out" && grep -q 'claude-api .*+gpu' <<<"$gen_out" \
        && ok "the generator summary marks GPU services +gpu" \
        || bad "the summary must show +gpu on GPU services only: $gen_out"
    docker_compose_ok=skip
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        docker compose -f "$OUT" config -q >/dev/null 2>&1 && docker_compose_ok=yes || docker_compose_ok=no
    fi
    case "$docker_compose_ok" in
        yes) ok "docker compose config accepts the generated GPU stack" ;;
        no)  bad "docker compose config rejects the generated GPU stack" ;;
        *)   echo "  SKIP  docker compose config (no docker compose on this runner)" ;;
    esac
fi
# The byte-level proof that --gpu changes nothing for a non-GPU service: the same stack
# generated without --gpu differs ONLY in the GPU service's lines.
OUT0="$TMPD/nogpu.yml"
STUB_STATE="$TMPD" PATH="$STUBD:$PATH" CLAUDE_PORTS_USED_OVERRIDE="" "$GEN" \
    --out "$OUT0" --browser web acme/api acme/web acme/plain >/dev/null 2>&1
if [[ -s "$OUT0" && -s "$OUT" ]]; then
    [[ "$(svc_block "$OUT0" plain)" == "$(svc_block "$OUT" plain)" ]] \
        && ok "the non-GPU service's YAML is byte-identical with and without --gpu on its siblings" \
        || bad "--gpu on a sibling changed a non-GPU service's YAML"
fi
out="$(STUB_STATE="$TMPD" PATH="$STUBD:$PATH" "$GEN" --out "$TMPD/bad.yml" --gpu nosuch acme/api 2>&1)"; rc=$?
(( rc != 0 )) && [[ "$out" == *"--gpu names 'nosuch', which is not a repo in this stack"* ]] && [[ ! -e "$TMPD/bad.yml" ]] \
    && ok "--gpu naming an unknown repo is an error, and nothing is written" \
    || bad "--gpu with an unknown repo must fail (rc=$rc): $out"
out="$(STUB_STATE="$TMPD" PATH="$STUBD:$PATH" STUB_NO_CDI=1 CLAUDE_PORTS_USED_OVERRIDE="" "$GEN" --out "$TMPD/nocdi.yml" --gpu api acme/api 2>&1)"
[[ "$out" == *"no CDI device nvidia.com/gpu=all"* ]] \
    && ok "the generator warns when the host has no CDI spec (Docker would refuse the service)" \
    || bad "the generator must warn about a missing CDI device: $out"

# ======================================================================================
echo "== claude-launch --gpu / --no-gpu =="
mkdir -p "$TMPD/ws"
launch() {  # launch <env...> -- <args...>: run the launcher against the stub, echo its args
    local envs=()
    while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done; shift
    rm -f "$TMPD/run-args" "$TMPD/created"
    env "${envs[@]}" STUB_STATE="$TMPD" PATH="$STUBD:$PATH" CLAUDE_PORTS_USED_OVERRIDE="" \
        "$LAUNCH" gputest --workspace "$TMPD/ws" --port 2299 "$@" >"$TMPD/launch.log" 2>&1
}
launch CLAUDE_GPU= -- --gpu; rc=$?
args="$(cat "$TMPD/run-args" 2>/dev/null)"
(( rc == 0 )) && grep -qxF -- '--device' <<<"$args" && grep -qxF 'nvidia.com/gpu=all' <<<"$args" \
    && ok "--gpu passes --device nvidia.com/gpu=all" \
    || bad "--gpu must pass --device nvidia.com/gpu=all (rc=$rc): $(tail -3 "$TMPD/launch.log")"
grep -qxF 'CLAUDE_GPU=1' <<<"$args" \
    && ok "--gpu sets CLAUDE_GPU=1" || bad "--gpu must set CLAUDE_GPU=1"
grep -qxF -- '--tmpfs' <<<"$args" && grep -qxF '/scratch:rw,nosuid,nodev,exec,size=4g' <<<"$args" \
    && ! grep -q 'claude-scratch-gputest:/scratch' <<<"$args" \
    && ok "--gpu puts /scratch on a 4g RAM tmpfs instead of the disk volume" \
    || bad "--gpu must mount /scratch as a tmpfs"
grep -qxF 'ALL' <<<"$args" && grep -qxF -- '--cap-drop' <<<"$args" \
    && ! grep -qE -- '^--(privileged|runtime|gpus)' <<<"$args" \
    && ok "--gpu keeps --cap-drop ALL and adds no --privileged, --runtime or --gpus" \
    || bad "--gpu must keep the hardening and use CDI only"
launch CLAUDE_GPU=1 -- --no-gpu
args="$(cat "$TMPD/run-args" 2>/dev/null)"
! grep -q 'nvidia.com/gpu' <<<"$args" && grep -q 'claude-scratch-gputest:/scratch' <<<"$args" \
    && ok "--no-gpu overrides an ambient CLAUDE_GPU=1 (no device, disk scratch)" \
    || bad "--no-gpu must win over CLAUDE_GPU=1"
launch CLAUDE_GPU=1 --
grep -q 'nvidia.com/gpu=all' "$TMPD/run-args" 2>/dev/null \
    && ok "CLAUDE_GPU=1 in the environment makes --gpu the default" \
    || bad "an ambient CLAUDE_GPU=1 must request the GPU"
launch CLAUDE_GPU= STUB_NO_CDI=1 -- --gpu; rc=$?
(( rc != 0 )) && [[ ! -e "$TMPD/run-args" ]] && grep -q 'no CDI device nvidia.com/gpu=all' "$TMPD/launch.log" \
    && ok "--gpu with no CDI spec on the host refuses before docker run, with the fix" \
    || bad "--gpu without CDI must refuse early (rc=$rc)"

# ======================================================================================
echo "== claude-gpu: the guard against a fake nvidia-smi =="
FAKE="$TMPD/fake"; mkdir -p "$FAKE"
cat > "$FAKE/nvidia-smi" <<'FAKE'
#!/usr/bin/env bash
# Fake nvidia-smi. FAKE_MODE picks the card's situation; FAKE_COUNT counts calls.
n=0; [[ -n "${FAKE_COUNT:-}" ]] && { n=$(( $(cat "$FAKE_COUNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_COUNT"; }
row() { echo "Fake GPU 2000, 580.00.00, 5120, $1, $2, $3, $4"; }   # free used util nvenc
case "${FAKE_MODE:-idle}" in
    idle)       row 5000 120 0 0 ;;
    plex)       row 4600 520 95 4 ;;
    shortvram)  row 800 4320 10 1 ;;
    busy2)      if (( n <= 2 )); then row 700 4400 90 3; else row 5000 120 0 0; fi ;;
    nvml)       echo "Failed to initialize NVML: Driver/library version mismatch"; echo "NVML library version: 580.95"; exit 18 ;;
    hang)       sleep 30 ;;
    garbage)    echo "[N/A], [N/A], [N/A], [N/A], [N/A], [N/A], [N/A]" ;;
esac
FAKE
chmod +x "$FAKE/nvidia-smi"
g() { env PATH="$FAKE:$PATH" CLAUDE_GPU_POLL=1 "$@"; }
# A PATH with the tools claude-gpu uses but no nvidia-smi, even on a host that has one in
# /usr/bin: the "no device attached" cases.
NOSMI="$TMPD/nosmi"; mkdir -p "$NOSMI"
for t in bash sh env timeout grep head sed mktemp mkfifo tee rm sleep cat tr; do
    ln -sf "$(command -v "$t")" "$NOSMI/$t"
done

out="$(g FAKE_MODE=idle "$GUARD" status)"; rc=$?
(( rc == 0 )) && grep -qx 'gpu: ok' <<<"$out" && grep -q 'device: Fake GPU 2000' <<<"$out" \
    && grep -q 'vram: 5000 MiB free of 5120 MiB' <<<"$out" && grep -q 'nvenc sessions: 0' <<<"$out" \
    && ok "status: an idle card is ok (exit 0) with name, VRAM and NVENC count" \
    || bad "status idle (rc=$rc): $out"
out="$(g FAKE_MODE=nvml CLAUDE_GPU=1 "$GUARD" status --oneline)"; rc=$?
(( rc == 3 )) && [[ "$out" == "gpu: degraded (nvidia-smi failed (exit 18): Failed to initialize NVML: Driver/library version mismatch)" ]] \
    && ok "status: an NVML mismatch is degraded (exit 3) and quotes the driver's reason" \
    || bad "status nvml (rc=$rc): $out"
out="$(g FAKE_MODE=hang CLAUDE_GPU_PROBE_TIMEOUT=1 "$GUARD" status --oneline)"; rc=$?
(( rc == 3 )) && [[ "$out" == *"hung for 1s"* ]] \
    && ok "status: a hung nvidia-smi is degraded after the probe timeout, never a hang" \
    || bad "status hang (rc=$rc): $out"
out="$(g FAKE_MODE=garbage "$GUARD" status --oneline)"; rc=$?
(( rc == 3 )) && [[ "$out" == *"unparseable"* ]] \
    && ok "status: unparseable output is degraded, not ok" || bad "status garbage (rc=$rc): $out"
out="$(env PATH="$NOSMI" CLAUDE_GPU= "$GUARD" status --oneline)"; rc=$?
(( rc == 4 )) && [[ "$out" == "gpu: off" ]] \
    && ok "status: no nvidia-smi and no CLAUDE_GPU is off (exit 4)" || bad "status off (rc=$rc): $out"
out="$(env PATH="$NOSMI" CLAUDE_GPU=1 "$GUARD" status --oneline)"; rc=$?
(( rc == 3 )) && [[ "$out" == *"not in this container"* ]] \
    && ok "status: CLAUDE_GPU=1 with no device attached is degraded, not off" || bad "status missing device (rc=$rc): $out"

probe_cmd='echo "dev=$CLAUDE_GPU_DEVICE cuda=[${CUDA_VISIBLE_DEVICES-unset}] egl=${__EGL_VENDOR_LIBRARY_FILENAMES:-none}"'
out="$(g FAKE_MODE=idle "$GUARD" run --wait 0 -- sh -c "$probe_cmd" 2>&1)"; rc=$?
(( rc == 0 )) && grep -q '^claude-gpu: device=GPU (Fake GPU 2000' <<<"$out" && grep -q 'dev=gpu cuda=\[unset\] egl=none' <<<"$out" \
    && grep -q 'claude-gpu: done on GPU: exit 0' <<<"$out" \
    && ok "run: an idle card runs on GPU, says so, and leaves CUDA/EGL alone" || bad "run idle (rc=$rc): $out"
out="$(g FAKE_MODE=plex "$GUARD" run --wait 0 -- sh -c "$probe_cmd" 2>&1)"; rc=$?
grep -q 'device=CPU (GPU still busy after 0s (utilization 95% > 80%))' <<<"$out" \
    && grep -q 'dev=cpu cuda=\[\] egl=/usr/share/glvnd/egl_vendor.d/50_mesa.json' <<<"$out" \
    && ok "run: a busy co-tenant (95% util, 4 NVENC) sends the job to CPU with CUDA hidden and EGL on Mesa" \
    || bad "run plex busy: $out"
out="$(g FAKE_MODE=plex "$GUARD" run --wait 0 --max-util 99 -- true 2>&1)"
grep -q 'device=CPU (GPU still busy after 0s (4 NVENC sessions > 2))' <<<"$out" \
    && ok "run: the NVENC session count alone can hold the job off the card" || bad "run nvenc: $out"
out="$(g FAKE_MODE=shortvram "$GUARD" run --wait 0 -- true 2>&1)"
grep -q 'device=CPU (GPU still busy after 0s (800 MiB free < 2048 MiB required))' <<<"$out" \
    && ok "run: short VRAM falls back to CPU and names the numbers" || bad "run short vram: $out"
out="$(g FAKE_MODE=idle "$GUARD" run --wait 0 --min-free-mib 999999 -- true 2>&1)"
grep -q 'device=CPU (GPU still busy after 0s (5000 MiB free < 999999 MiB required))' <<<"$out" \
    && ok "run: --min-free-mib above the card's VRAM falls back to CPU" || bad "run min-free: $out"
echo 0 > "$TMPD/count"
out="$(g FAKE_MODE=busy2 FAKE_COUNT="$TMPD/count" "$GUARD" run --wait 10 -- true 2>&1)"
grep -q 'GPU busy (700 MiB free < 2048 MiB required); waiting up to 10s' <<<"$out" && grep -q 'device=GPU' <<<"$out" \
    && ok "run: a card that frees up within --wait is waited for, then used" || bad "run busy then free: $out"
out="$(g FAKE_MODE=busy2 FAKE_COUNT="$TMPD/count2" "$GUARD" run --wait 1 -- true 2>&1)"
grep -q 'device=CPU (GPU still busy after 1s' <<<"$out" \
    && ok "run: --wait runs out, then the job goes to CPU" || bad "run wait expiry: $out"
oom_cmd='if [ "$CLAUDE_GPU_DEVICE" = gpu ]; then echo "CUDA error: out of memory" >&2; exit 1; fi; echo "rendered on $CLAUDE_GPU_DEVICE"'
out="$(g FAKE_MODE=idle "$GUARD" run --wait 0 -- sh -c "$oom_cmd" 2>&1)"; rc=$?
(( rc == 0 )) && grep -q 'retrying once on CPU' <<<"$out" && grep -q 'rendered on cpu' <<<"$out" \
    && grep -q 'done on CPU: exit 0' <<<"$out" \
    && ok "run: a GPU out-of-memory failure is retried once on CPU, and the retry's exit wins" \
    || bad "run oom retry (rc=$rc): $out"
out="$(g FAKE_MODE=idle "$GUARD" run --wait 0 -- sh -c 'echo "some other error" >&2; exit 5' 2>&1)"; rc=$?
(( rc == 5 )) && ! grep -q 'retrying' <<<"$out" \
    && ok "run: a non-OOM failure is NOT retried and keeps its exit code" || bad "run non-oom (rc=$rc): $out"
out="$(g FAKE_MODE=nvml CLAUDE_GPU=1 "$GUARD" run --wait 30 -- true 2>&1)"
grep -q 'device=CPU (GPU degraded: nvidia-smi failed' <<<"$out" && ! grep -q 'waiting up to' <<<"$out" \
    && ok "run: a degraded GPU goes straight to CPU (no waiting on a broken driver)" || bad "run degraded: $out"
out="$(g FAKE_MODE=idle "$GUARD" run -- sh -c 'printf out; printf "err\n" >&2' 2>"$TMPD/err")"
[[ "$out" == "out" && "$(grep -v '^claude-gpu:' "$TMPD/err")" == "err" ]] \
    && ok "run: the command's stdout and stderr stay separate (callers can redirect either)" \
    || bad "run must keep stdout/stderr apart: out=[$out] err=[$(cat "$TMPD/err")]"
out="$("$GUARD" env cpu)"
grep -qx 'export CLAUDE_GPU_DEVICE=cpu' <<<"$out" && grep -qx 'export CUDA_VISIBLE_DEVICES=' <<<"$out" \
    && grep -qx 'export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json' <<<"$out" \
    && ok "env cpu prints the documented CPU contract" || bad "env cpu: $out"
"$GUARD" bogus >/dev/null 2>&1; rc=$?
(( rc == 64 )) && ok "an unknown subcommand is a usage error (64)" || bad "unknown subcommand rc=$rc"

# claude-gpu blender: the device goes after the first `--`, so a caller's own script
# args (also after `--`) keep working. A fake blender records its arguments.
BL="$TMPD/bl"; mkdir -p "$BL"
cat > "$BL/blender" <<'FAKEB'
#!/usr/bin/env bash
if [[ "$*" == *CLAUDE_GPU_BACKENDS* ]]; then echo "CLAUDE_GPU_BACKENDS=${FAKE_BACKENDS-OPTIX,CUDA}"; exit 0; fi
[[ "$1" == --version ]] && { echo "Blender 0.0 fake"; exit 0; }
printf '%s\n' "$@" > "${FAKE_BLENDER_ARGS:?}"
FAKEB
chmod +x "$BL/blender"
bl() { rm -f /tmp/claude-gpu-blender-backends "$TMPD/bargs"; env PATH="$BL:$FAKE:$PATH" FAKE_BLENDER_ARGS="$TMPD/bargs" "$@"; }
bl FAKE_MODE=idle "$GUARD" blender -b scene.blend -f 1 >/dev/null 2>&1
[[ "$(tr '\n' ' ' < "$TMPD/bargs")" == "-b scene.blend -f 1 -- --cycles-device OPTIX " ]] \
    && ok "blender: an idle card with OptiX renders on OPTIX (appended after a new --)" \
    || bad "blender optix args: $(tr '\n' ' ' < "$TMPD/bargs" 2>/dev/null)"
bl FAKE_MODE=idle FAKE_BACKENDS=CUDA "$GUARD" blender -b s.blend --python x.py -- --mine 1 >/dev/null 2>&1
[[ "$(tr '\n' ' ' < "$TMPD/bargs")" == "-b s.blend --python x.py -- --cycles-device CUDA --mine 1 " ]] \
    && ok "blender: no OptiX falls back to CUDA, inserted right after the caller's own --" \
    || bad "blender cuda args: $(tr '\n' ' ' < "$TMPD/bargs" 2>/dev/null)"
bl FAKE_MODE=plex CLAUDE_GPU_WAIT=0 "$GUARD" blender -b s.blend -f 1 >/dev/null 2>&1
[[ "$(tr '\n' ' ' < "$TMPD/bargs")" == "-b s.blend -f 1 -- --cycles-device CPU " ]] \
    && ok "blender: a busy card renders on CPU" \
    || bad "blender busy args: $(tr '\n' ' ' < "$TMPD/bargs" 2>/dev/null)"
rm -f /tmp/claude-gpu-blender-backends

# ======================================================================================
echo "== claude-blender-install: fail closed, then atomic and idempotent =="
mkdir -p "$TMPD/pkg/blender-9.9.9-linux-x64"
printf '#!/bin/sh\necho fake\n' > "$TMPD/pkg/blender-9.9.9-linux-x64/blender"
chmod +x "$TMPD/pkg/blender-9.9.9-linux-x64/blender"
tar -cJf "$TMPD/blender.tar.xz" -C "$TMPD/pkg" blender-9.9.9-linux-x64
fake_sha="$(sha256sum "$TMPD/blender.tar.xz" | awk '{print $1}')"
if [[ "$(uname -m)" != x86_64 ]]; then
    echo "  SKIP  installer checks (the pinned build is x86_64 only; this runner is $(uname -m))"
else
    out="$(CLAUDE_BLENDER_ROOT="$TMPD/root" CLAUDE_BLENDER_URLS="file://$TMPD/blender.tar.xz" "$INSTALL" 2>&1)"; rc=$?
    (( rc != 0 )) && grep -q 'CHECKSUM MISMATCH' <<<"$out" && grep -q 'Refusing to install' <<<"$out" \
        && [[ ! -e "$TMPD/root/current" ]] && [[ -z "$(find "$TMPD/root" -name '*.tar.xz' 2>/dev/null)" ]] \
        && ok "a tarball that does not match the pinned SHA-256 is refused and deleted, nothing installed" \
        || bad "checksum mismatch must fail closed (rc=$rc): $out"
    CLAUDE_BLENDER_ROOT="$TMPD/root" "$INSTALL" --check; rc=$?
    (( rc == 1 )) && ok "--check says not installed (exit 1)" || bad "--check before install rc=$rc"
    out="$(CLAUDE_BLENDER_ROOT="$TMPD/root" CLAUDE_BLENDER_URLS="file://$TMPD/nope.tar.xz file://$TMPD/blender.tar.xz" \
        CLAUDE_BLENDER_TEST_SHA256="$fake_sha" "$INSTALL" 2>&1)"; rc=$?
    (( rc == 0 )) && grep -q 'TEST SEAM ACTIVE' <<<"$out" && grep -q 'trying the next source' <<<"$out" \
        && [[ "$(readlink "$TMPD/root/current")" == 5.2.2 && -x "$TMPD/root/5.2.2/blender" ]] \
        && [[ "$(cat "$TMPD/root/5.2.2/.claude-sha256")" == "$fake_sha" ]] \
        && ok "a verified tarball installs into <root>/<version>, current points at it, a dead mirror is skipped" \
        || bad "happy path (rc=$rc): $out"
    [[ -z "$(find "$TMPD/root" -maxdepth 1 -name '.work.*')" ]] \
        && ok "no temporary work directory is left behind" || bad "a .work.* directory was left in the cache"
    out="$(CLAUDE_BLENDER_ROOT="$TMPD/root" CLAUDE_BLENDER_URLS="file://$TMPD/nope.tar.xz" \
        CLAUDE_BLENDER_TEST_SHA256="$fake_sha" "$INSTALL" 2>&1)"; rc=$?
    (( rc == 0 )) && grep -q 'already installed' <<<"$out" \
        && ok "a second run is a no-op (no download attempted)" || bad "idempotent re-run (rc=$rc): $out"
    grep -qE '^BLENDER_SHA256="[0-9a-f]{64}"$' "$INSTALL" && grep -q '^# PIN_EVIDENCE:' "$INSTALL" \
        && ok "the pin carries a full SHA-256 and its recorded evidence" || bad "the pin must carry a SHA-256 and PIN_EVIDENCE"
fi

# ======================================================================================
echo "== entrypoint.sh §2b: a broken GPU degrades loudly, never stops the boot =="
BLOCK="$(awk '/^# --- 2b\. GPU probe/{f=1} f{print} f&&/^fi$/{exit}' "$REPO_ROOT/entrypoint.sh")"
FG="$TMPD/fakeguard"
run_2b() {  # run_2b <guard-output> <guard-exit>: run the real block against a fake guard
    printf '#!/bin/sh\necho "%s"\nexit %s\n' "$1" "$2" > "$FG"; chmod +x "$FG"
    local blk; blk="$(sed -e "s#^GPU_STATE_FILE=.*#GPU_STATE_FILE=\"$TMPD/run/state\"#" \
                            -e "s#^GPU_GUARD=.*#GPU_GUARD=\"$FG\"#" <<<"$BLOCK")"
    ( log() { echo "[entrypoint] $*"; }; set -euo pipefail; CLAUDE_GPU=1; eval "$blk"
      echo "REASON=[$GPU_DEGRADED_REASON]" ) 2>&1
}
if [[ -z "$BLOCK" ]]; then
    bad "could not extract §2b from entrypoint.sh"
else
    grep -q '^GPU_STATE_FILE=' <<<"$BLOCK" && grep -q '^GPU_GUARD=' <<<"$BLOCK" \
        && ok "§2b names its root-only paths on their own lines (so this sandbox redirect is real)" \
        || bad "§2b must assign GPU_STATE_FILE and GPU_GUARD on their own lines"
    out="$(run_2b "gpu: ok (Fake GPU 2000, driver 580.00.00, 5000/5120 MiB free, util 0%, nvenc 0)" 0)"; rc=$?
    (( rc == 0 )) && grep -q 'GPU                 : ok (Fake GPU 2000' <<<"$out" && grep -q 'REASON=\[\]' <<<"$out" \
        && grep -q '^gpu: ok' "$TMPD/run/state" \
        && ok "an ok GPU logs one line and records 'gpu: ok' in the state file" || bad "§2b ok (rc=$rc): $out"
    out="$(run_2b "gpu: degraded (nvidia-smi failed (exit 18): Failed to initialize NVML: Driver/library version mismatch)" 3)"; rc=$?
    (( rc == 0 )) && grep -q 'GPU DEGRADED: nvidia-smi failed (exit 18): Failed to initialize NVML: Driver/library version mismatch' <<<"$out" \
        && grep -q 'starting WITHOUT a usable GPU' <<<"$out" && grep -q 'REASON=\[nvidia-smi failed' <<<"$out" \
        && grep -q '^gpu: degraded (nvidia-smi failed' "$TMPD/run/state" \
        && ok "an NVML mismatch boots anyway (rc 0 under set -euo pipefail) with a loud banner and a recorded state" \
        || bad "§2b degraded (rc=$rc): $out"
    out="$(run_2b "" 124)"; rc=$?
    (( rc == 0 )) && grep -q 'GPU DEGRADED: the boot probe timed out' <<<"$out" \
        && ok "a probe that times out degrades, it does not hang or fail the boot" || bad "§2b timeout (rc=$rc): $out"
    [[ "$(stat -c %a "$TMPD/run/state")" == 644 ]] \
        && ok "the state file is world-readable (0644) for the agent, the guard and SSH users" \
        || bad "the state file must be 0644"
fi
grep -q 'GPU DEGRADED: ${GPU_DEGRADED_REASON' "$REPO_ROOT/entrypoint.sh" && grep -q 'status-right' "$REPO_ROOT/entrypoint.sh" \
    && ok "a degraded GPU is also put on the tmux status line" || bad "the tmux status banner is missing"

# ======================================================================================
echo "== claude-healthcheck: the GPU is reported, never fatal =="
HC="$REPO_ROOT/bin/claude-healthcheck"
HCSTUB="$TMPD/hc"; mkdir -p "$HCSTUB"
for b in pgrep gosu; do printf '#!/bin/sh\nexit 0\n' > "$HCSTUB/$b"; chmod +x "$HCSTUB/$b"; done
hc() {  # hc <guard output> <guard exit>
    local d="$TMPD/hcguard"; mkdir -p "$d"
    printf '#!/bin/sh\necho "%s"\nexit %s\n' "$1" "$2" > "$d/claude-gpu"; chmod +x "$d/claude-gpu"
    sed "s#/usr/local/bin/claude-gpu#$d/claude-gpu#" "$HC" > "$TMPD/hc.sh"
    env PATH="$HCSTUB:$PATH" CLAUDE_GPU=1 CLAUDE_RC_DEBUG_LOG="" bash "$TMPD/hc.sh"
}
out="$(hc "gpu: ok (Fake GPU 2000, driver 580, 5000/5120 MiB free, util 0%, nvenc 0)" 0)"; rc=$?
(( rc == 0 )) && [[ "$out" == "healthy; gpu: ok" ]] \
    && ok "healthy; gpu: ok" || bad "healthcheck ok (rc=$rc): $out"
out="$(hc "gpu: degraded (nvidia-smi failed (exit 18): Failed to initialize NVML: Driver/library version mismatch)" 3)"; rc=$?
(( rc == 0 )) && [[ "$out" == "healthy; gpu: degraded (nvidia-smi failed (exit 18): Failed to initialize NVML: Driver/library version mismatch)" ]] \
    && ok "a degraded GPU is reported on the healthy line and exit stays 0" || bad "healthcheck degraded (rc=$rc): $out"
out="$(hc "" 124)"; rc=$?
(( rc == 0 )) && [[ "$out" == "healthy; gpu: degraded (the GPU probe did not answer)" ]] \
    && ok "a GPU probe that does not answer is degraded, still healthy" || bad "healthcheck silent probe (rc=$rc): $out"
out="$(env PATH="$HCSTUB:$PATH" CLAUDE_GPU= CLAUDE_RC_DEBUG_LOG="" bash "$HC")"
[[ "$out" == "healthy" ]] && ok "a non-GPU session's health line is unchanged ('healthy')" || bad "non-GPU health line: $out"

# ======================================================================================
echo "== the image and the GPU note =="
DF="$REPO_ROOT/Dockerfile"
for p in libglvnd0 libegl1 libgl1 libopengl0 libglx0 libegl-mesa0 libgl1-mesa-dri libosmesa6 libxi6 libxxf86vm1 libxkbcommon0 libsm6 libice6; do
    grep -qE "^[[:space:]]+[^#]*\\b${p}\\b" "$DF" || { bad "the Dockerfile must install $p"; continue; }
done
ok "the Dockerfile installs the glvnd dispatch, Mesa and Blender's X client libraries"
if grep -vE '^[[:space:]]*#' "$DF" | grep -qiE 'libnvidia|nvidia-driver|libcuda|nvidia-container|cuda-toolkit'; then
    bad "the Dockerfile must never install NVIDIA driver libraries (CDI injects them, matched to the host)"
else
    ok "the Dockerfile installs no NVIDIA driver library"
fi
grep -q 'COPY bin/claude-gpu /usr/local/bin/claude-gpu' "$DF" && grep -q 'COPY bin/claude-blender-install' "$DF" \
    && ok "claude-gpu and claude-blender-install are baked" || bad "the GPU tools must be baked into the image"
NOTE="$REPO_ROOT/claude-config/CLAUDE.gpu.md"
[[ -f "$NOTE" ]] && grep -q 'claude-gpu status' "$NOTE" && grep -q 'claude-gpu run' "$NOTE" && grep -q 'claude-blender-install' "$NOTE" \
    && ok "the GPU note teaches claude-gpu status/run and claude-blender-install" || bad "the GPU note is missing its essentials"
grep -q 'claude-containers: GPU session note' "$NOTE" && grep -q 'GPU_NOTE_MARK="claude-containers: GPU session note"' "$REPO_ROOT/entrypoint.sh" \
    && ok "the note carries the marker the entrypoint uses to never overwrite an operator's file" || bad "the note's marker must match the entrypoint's"
awk '/^# --- 7b\. GPU note/,/^# --- 8\./' "$REPO_ROOT/entrypoint.sh" | grep -q 'CLAUDE_GPU:-0' \
    && ok "the note is written only when CLAUDE_GPU=1" || bad "the GPU note must be gated on CLAUDE_GPU"

echo
echo "gpu-unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
