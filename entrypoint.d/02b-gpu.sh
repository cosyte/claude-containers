# shellcheck shell=bash
# --- 2b. GPU probe (CLAUDE_GPU=1, a --gpu session) ----------------------------
# A --gpu session has the host's NVIDIA device injected by CDI at creation. Probe it once,
# BOUNDED (a wedged driver must never hang boot), and record the result where the
# healthcheck, the guard and anyone who SSHes in can read it. A GPU that is unusable at
# boot DEGRADES the session loudly instead of failing it: the session still starts, CPU
# fallbacks still work, and the operator sees why in this log, on the tmux status line
# and in `claude-healthcheck`. The usual cause is a host driver update without a reboot
# (NVML "Driver/library version mismatch"). A MISSING CDI spec on the host is different:
# Docker refuses to create the container at all, so that case never reaches this code.
# GPU_STATE_FILE / GPU_GUARD are named (not inlined) so test/gpu-unit.sh can run this
# exact block unprivileged against a sandbox and a fake guard.
GPU_STATE_FILE=/run/claude-gpu/state
GPU_GUARD=/usr/local/bin/claude-gpu
GPU_DEGRADED_REASON=""
if [[ "${CLAUDE_GPU:-0}" =~ ^(1|true|yes|on)$ ]]; then
    mkdir -p "${GPU_STATE_FILE%/*}" && chmod 755 "${GPU_STATE_FILE%/*}"
    # `&& ... ||` keeps a non-zero probe from tripping `set -e`: a degraded GPU is a
    # result to report, not a reason to stop booting.
    gpu_line="$(CLAUDE_GPU_PROBE_TIMEOUT="${CLAUDE_GPU_PROBE_TIMEOUT:-10}" \
        timeout 20 "$GPU_GUARD" status --oneline 2>&1)" && gpu_rc=0 || gpu_rc=$?
    case "$gpu_rc" in
        0|3) ;;   # ok, or degraded: the guard's own line already says which, and why
        124) gpu_line="gpu: degraded (the boot probe timed out after 20s)" ;;
        *)   gpu_line="gpu: degraded (the boot probe failed, exit ${gpu_rc}: ${gpu_line:-no output})" ;;
    esac
    printf '%s\n' "$gpu_line" > "$GPU_STATE_FILE.tmp" && mv -f "$GPU_STATE_FILE.tmp" "$GPU_STATE_FILE"
    chmod 644 "$GPU_STATE_FILE" 2>/dev/null || true
    if [[ "$gpu_line" == "gpu: ok"* ]]; then
        log "GPU                 : ${gpu_line#gpu: }"
    else
        GPU_DEGRADED_REASON="${gpu_line#gpu: degraded (}"; GPU_DEGRADED_REASON="${GPU_DEGRADED_REASON%)}"
        log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        log "GPU DEGRADED: ${GPU_DEGRADED_REASON}"
        log "This --gpu session is starting WITHOUT a usable GPU. Everything else works, and"
        log "GPU jobs fall back to CPU through claude-gpu. Fix it on the host (a driver update"
        log "needs a reboot; 'nvidia-smi' on the host must work), then restart this container."
        log "Details: docs/troubleshooting.md, GPU."
        log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    fi
    unset gpu_line gpu_rc
fi
