# shellcheck shell=bash
# --- 12. The session's environment ---------------------------------------------
# Everything the tmux server and its panes inherit: exported here, before §12b starts the
# server, so every pane (and anything respawned in one) reads the same values.
CLAUDE_PROJECT_NAME="${CLAUDE_PROJECT_NAME:-claude}"
# RC debug log path: claude-session writes Remote Control events here; the
# watchdog and the Docker healthcheck read it. Exported so the tmux server (and
# anything respawned in it) inherits it; CLAUDE_RC_DEBUG_LOG is also a baked ENV
# so the healthcheck, a separate process spawned by dockerd, sees it too.
export CLAUDE_RC_DEBUG_LOG="${CLAUDE_RC_DEBUG_LOG-/tmp/claude-rc-debug.log}"
export CLAUDE_PROJECT_NAME CLAUDE_EXTRA_ARGS="${CLAUDE_EXTRA_ARGS:-}" \
       CLAUDE_DEV_CMD="${CLAUDE_DEV_CMD:-}"

# Model selection: default to the best available model. The `opus` alias always
# resolves to the latest Opus, so the fleet tracks the strongest model without a
# code change when a newer one ships. Override per-container with CLAUDE_MODEL:
# any Claude Code alias (opus, sonnet, haiku, opusplan, default) or a full model
# id (e.g. claude-opus-4-8). Both the interactive session and the autopilot loop
# read it and pass `--model`. To defer to Claude Code's own default, set
# CLAUDE_MODEL=default (empty/unset falls back to opus, the best available).
export CLAUDE_MODEL="${CLAUDE_MODEL:-opus}"
log "Model               : $CLAUDE_MODEL (override with CLAUDE_MODEL; 'default' = Claude Code's pick)"

# Two modes:
#   interactive (default): main pane is claude-session (Remote Control + SSH).
#   autopilot (CLAUDE_AUTOPILOT=1): main pane is claude-autopilot, a headless Claude
#                           loop running CLAUDE_AUTOPILOT_CMD for unattended build-out;
#                           there is no Remote Control link, so the RC watchdog is
#                           skipped.
# Either way SSH attaches to the live tmux pane. The third mode, CLAUDE_CONTROLLER, was
# removed and is refused up in §0b: long before we get here.
# shellcheck disable=SC2034  # MAIN_PANE_CMD is the pane §12b starts
case "${CLAUDE_AUTOPILOT:-0}" in
    1|true|yes|on) CLAUDE_MODE=autopilot;   MAIN_PANE_CMD=/usr/local/bin/claude-autopilot ;;
    # --boot: resume main's last conversation when CLAUDE_MAIN_RESUME=1; otherwise (the
    # default) a fresh one, exactly as before named sessions existed.
    *)             CLAUDE_MODE=interactive; MAIN_PANE_CMD="/usr/local/bin/claude-session --boot" ;;
esac
export CLAUDE_MODE \
       CLAUDE_AUTOPILOT_CMD="${CLAUDE_AUTOPILOT_CMD:-}" \
       CLAUDE_AUTOPILOT_INTERVAL="${CLAUDE_AUTOPILOT_INTERVAL:-}" \
       CLAUDE_AUTOPILOT_MAX_RUNS="${CLAUDE_AUTOPILOT_MAX_RUNS:-}" \
       CLAUDE_AUTOPILOT_BACKOFF_MAX="${CLAUDE_AUTOPILOT_BACKOFF_MAX:-}" \
       CLAUDE_AUTOPILOT_LOG_DIR="${CLAUDE_AUTOPILOT_LOG_DIR:-}" \
       CLAUDE_AUTOPILOT_RESUME="${CLAUDE_AUTOPILOT_RESUME:-}" \
       CLAUDE_AUTOPILOT_QUEUE="${CLAUDE_AUTOPILOT_QUEUE:-}" \
       CLAUDE_AUTOPILOT_QUEUE_DIR="${CLAUDE_AUTOPILOT_QUEUE_DIR:-}" \
       CLAUDE_AUTOPILOT_QUEUE_DELAY="${CLAUDE_AUTOPILOT_QUEUE_DELAY:-}" \
       CLAUDE_SCM_OBSERVER="${CLAUDE_SCM_OBSERVER:-}" \
       CLAUDE_SCM_INTERVAL="${CLAUDE_SCM_INTERVAL:-}" \
       CLAUDE_SCM_EVENTS="${CLAUDE_SCM_EVENTS:-}" \
       CLAUDE_SCM_PR_FILTER="${CLAUDE_SCM_PR_FILTER:-}" \
       CLAUDE_SCM_PR_LIMIT="${CLAUDE_SCM_PR_LIMIT:-}" \
       CLAUDE_SCM_PRIORITY="${CLAUDE_SCM_PRIORITY:-}" \
       CLAUDE_PERMISSION_MODE="${CLAUDE_PERMISSION_MODE:-bypassPermissions}"
# Named sessions (bin/claude-sessions, §12e). Exported so the tmux server carries them:
# claude-sessions run from an SSH login reads them back from tmux's global environment.
export CLAUDE_SESSIONS="${CLAUDE_SESSIONS:-}" \
       CLAUDE_MAIN_RESUME="${CLAUDE_MAIN_RESUME:-0}" \
       CLAUDE_RC_WATCHDOG="${CLAUDE_RC_WATCHDOG:-1}"

# OpenTelemetry: opt-in fleet observability. Claude Code reads OTEL_* + the
# enable flag straight from the process environment (env > settings.json), and
# the tmux panes inherit this exported env, so we just compose sane defaults and
# a per-container resource tag: no settings.json surgery, and the auth header (a
# secret) stays in process env, never persisted to the config volume. Enabled by
# CLAUDE_OTEL_ENABLED=1 or simply by supplying an OTLP endpoint. Orthogonal to
# the Remote-Control telemetry concern in §8b (that's nonessential-traffic, not
# this). Ref: code.claude.com/docs/en/monitoring-usage
if [[ "${CLAUDE_OTEL_ENABLED:-0}" =~ ^(1|true|yes|on)$ || -n "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" ]]; then
    export CLAUDE_CODE_ENABLE_TELEMETRY=1
    export OTEL_METRICS_EXPORTER="${OTEL_METRICS_EXPORTER:-otlp}"
    export OTEL_LOGS_EXPORTER="${OTEL_LOGS_EXPORTER:-otlp}"
    export OTEL_EXPORTER_OTLP_PROTOCOL="${OTEL_EXPORTER_OTLP_PROTOCOL:-http/protobuf}"
    # Traces are a Claude Code beta (needed for trace backends like Langfuse).
    if [[ "${CLAUDE_OTEL_TRACES:-0}" =~ ^(1|true|yes|on)$ ]]; then
        export CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1
        export OTEL_TRACES_EXPORTER="${OTEL_TRACES_EXPORTER:-otlp}"
    fi
    # service.name is fixed to "claude-code" upstream, so distinguish containers
    # with a custom tag (+ any operator-supplied attributes).
    _ra="service.instance.id=${CLAUDE_PROJECT_NAME},claude.project=${CLAUDE_PROJECT_NAME}"
    [[ -n "${OTEL_RESOURCE_ATTRIBUTES:-}" ]] && _ra="${_ra},${OTEL_RESOURCE_ATTRIBUTES}"
    export OTEL_RESOURCE_ATTRIBUTES="$_ra"
    # OTEL_EXPORTER_OTLP_ENDPOINT / _HEADERS arrive via env (-e/.env) and are
    # already exported into this environment, so the panes inherit them as-is.
    log "OpenTelemetry        : on → ${OTEL_EXPORTER_OTLP_ENDPOINT:-<no endpoint set!>} (${OTEL_EXPORTER_OTLP_PROTOCOL})$([[ -n "${OTEL_EXPORTER_OTLP_HEADERS:-}" ]] && echo ' +auth')"
    [[ -z "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" ]] && \
        log "OpenTelemetry        : WARNING, enabled but OTEL_EXPORTER_OTLP_ENDPOINT is empty; nothing will be exported"
fi

# Library thread pools.
# OpenMP, OpenBLAS, MKL, numexpr and Accelerate size their pools to the HOST's CPU count:
# nproc ignores the cgroup quota. On a 56-thread host `import numpy, build123d` alone starts
# 111 threads, and threads count against pids.max. Parallel test workers multiplied that:
# two pytest-xdist runs of 28 workers held ~8,000 threads, hit a pids.max of 8192, and every
# Claude session that then needed a thread crashed. Cap each process's pools unless the
# operator (or the image) already set a variable; CLAUDE_THREADS_PER_PROCESS=0 leaves them
# alone. A repo's own .claude/settings.json env still overrides these for its session.
# Written to /etc/profile.d as well, since an SSH login gets a fresh environment. GNU nproc
# honours OMP_NUM_THREADS, so the image's nproc (bin/nproc) reads the cgroup quota instead.
THREADS_PROFILE_D="/etc/profile.d/claude-threads.sh"
_tpp="${CLAUDE_THREADS_PER_PROCESS:-4}"
if [[ "$_tpp" =~ ^[1-9][0-9]*$ ]]; then
    : > "$THREADS_PROFILE_D.tmp" 2>/dev/null || true
    for _v in OMP_NUM_THREADS OPENBLAS_NUM_THREADS MKL_NUM_THREADS NUMEXPR_NUM_THREADS VECLIB_MAXIMUM_THREADS; do
        [[ -n "${!_v:-}" ]] || export "$_v=$_tpp"
        printf 'export %s="${%s:-%s}"\n' "$_v" "$_v" "${!_v}" >> "$THREADS_PROFILE_D.tmp" 2>/dev/null || true
    done
    mv -f "$THREADS_PROFILE_D.tmp" "$THREADS_PROFILE_D" 2>/dev/null && chmod 644 "$THREADS_PROFILE_D" 2>/dev/null || true
    log "Thread pools        : OMP/OpenBLAS/MKL/numexpr/vecLib ${OMP_NUM_THREADS} per process (CLAUDE_THREADS_PER_PROCESS; 0 = leave them alone)"
else
    rm -f "$THREADS_PROFILE_D" 2>/dev/null || true
    log "Thread pools        : NOT capped (CLAUDE_THREADS_PER_PROCESS=${_tpp}); libraries size them to the host's $(nproc --all) CPUs, not this container's $(nproc) (its cgroup quota)"
fi
unset _tpp

# Gradle builds.
# Every Gradle JVM sizes its workers to the whole CPU quota, so three sessions' builds at once
# ask for three times the quota and the cgroup throttles the whole container in bursts (load 43
# on 28 CPUs on 2026-10-21, a 2-minute gate taking 20+). Idle daemons sit for Gradle's 3 hours,
# 1-5 GB each. GRADLE_OPTS holds whatever GRADLE_USER_HOME a repo picks; its -D beats a repo's
# gradle.properties, and a command-line --max-workers or -D beats it. Appended to the
# operator's GRADLE_OPTS, never over a -D of the same name there. Unset: a third of the quota
# (at least 2) and 30 minutes; 0 or empty leaves Gradle's own default. claude-container-facts
# repeats the worker formula. The effective values go to /etc/profile.d as well, for SSH logins.
GRADLE_PROFILE_D="/etc/profile.d/claude-gradle.sh"
_n="$(nproc 2>/dev/null)" || true
[[ "$_n" =~ ^[0-9]+$ ]] || _n=0
_gw="${CLAUDE_GRADLE_WORKERS-$(( _n / 3 > 2 ? _n / 3 : 2 ))}"
_gi="${CLAUDE_GRADLE_IDLE_MS-1800000}"
: > "$GRADLE_PROFILE_D.tmp" 2>/dev/null || true
_glog=()
for _p in "org.gradle.workers.max=$_gw" "org.gradle.daemon.idletimeout=$_gi"; do
    _k="${_p%%=*}"
    if [[ ! "${_p#*=}" =~ ^[1-9][0-9]*$ ]]; then
        _glog+=("$_k Gradle's default")
        continue
    elif [[ " ${GRADLE_OPTS:-} " == *" -D$_k="* ]]; then
        # The operator's own: SSH logins (a fresh environment) get that value, not ours.
        _p="${GRADLE_OPTS##*-D"$_k"=}"; _p="$_k=${_p%% *}"
        _glog+=("$_p (the operator's GRADLE_OPTS)")
        [[ "${_p#*=}" =~ ^[0-9]+$ ]] || continue   # only a number goes into a shell file
    else
        export GRADLE_OPTS="${GRADLE_OPTS:+$GRADLE_OPTS }-D$_p"
        _glog+=("$_p")
    fi
    printf 'case " ${GRADLE_OPTS-} " in *" -D%s="*) ;; *) export GRADLE_OPTS="${GRADLE_OPTS:+$GRADLE_OPTS }-D%s" ;; esac\n' \
        "$_k" "$_p" >> "$GRADLE_PROFILE_D.tmp" 2>/dev/null || true
done
mv -f "$GRADLE_PROFILE_D.tmp" "$GRADLE_PROFILE_D" 2>/dev/null && chmod 644 "$GRADLE_PROFILE_D" 2>/dev/null || true
log "Gradle              : ${_glog[0]}, ${_glog[1]} (CLAUDE_GRADLE_WORKERS, CLAUDE_GRADLE_IDLE_MS; 0 = Gradle's default)"
unset _n _gw _gi _glog _p _k

# Native Claude Code CLI tuning knobs (real upstream env vars the `claude`
# binary reads directly, see .env.example). Nothing to translate here, just
# surface non-default values in the boot log for operator visibility; a
# default fleet (all unset) stays quiet.
for _v in CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION BASH_DEFAULT_TIMEOUT_MS BASH_MAX_TIMEOUT_MS API_TIMEOUT_MS; do
    if [[ -n "${!_v:-}" ]]; then log "CLI tuning           : ${_v}=${!_v}"; fi
done
unset _v
