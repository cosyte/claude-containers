# shellcheck shell=bash
# --- 12b. Launch Claude Code in a persistent tmux session ------------------------
# Named sessions, step 1 of 2 (§12e is step 2): bring the registry in line with
# CLAUDE_SESSIONS and pre-accept workspace trust for every session directory NOW, while no
# Claude process is running to rewrite .claude.json under us. The trust seeded for
# /workspace in §7 does not cover /workspace/<repo>: without this a named session would sit
# on the trust dialog. Never fatal.
# The kit's plugins (CLAUDE_EXTRA_MARKETPLACES / CLAUDE_EXTRA_PLUGINS, §8c) are installed
# here, before any Claude session exists, so every session loads them from its first start
# (a plugin's SessionStart hook included). Bounded per CLI call, and never fatal: a kit that
# cannot be fetched is a warning in this log, and the container boots without it.
if kit_declared; then
    asclaude /usr/local/bin/claude-kit install \
        || log "WARNING: claude-kit install failed; declared plugins may be missing (claude-kit status)"
fi

asclaude /usr/local/bin/claude-sessions prepare \
    || log "WARNING: claude-sessions prepare failed; named sessions may be missing (claude-sessions ls)"

# tmux server runs as the claude user; the main pane command falls back to an
# interactive shell if it exits, so SSH stays usable. The pane lives in window
# 'main' (the RC watchdog respawns it by name in interactive mode).
asclaude tmux new-session -d -s claude -n main -x 220 -y 50 "$MAIN_PANE_CMD"
# A degraded GPU (§2b) stays visible to anyone attached, not only in the boot log.
if [[ -n "$GPU_DEGRADED_REASON" ]]; then
    asclaude tmux set-option -t claude status-right-length 120 >/dev/null 2>&1 || true
    asclaude tmux set-option -t claude status-right \
        "#[bg=red,fg=white,bold] GPU DEGRADED: ${GPU_DEGRADED_REASON//#/##} (claude-gpu status) " >/dev/null 2>&1 || true
fi
log "Claude Code session 'claude' started in tmux (mode: $CLAUDE_MODE)"

# Optional dev server: runs $CLAUDE_DEV_CMD in its own 'dev' tmux window so it
# auto-starts on boot, is observable (tmux select-window -t claude:dev), and
# survives independently of the Claude pane.
if [[ -n "${CLAUDE_DEV_CMD:-}" ]]; then
    asclaude tmux new-window -t claude -n dev /usr/local/bin/claude-dev
    log "Dev server started in tmux window 'dev': $CLAUDE_DEV_CMD"
fi

# Optional SCM observer: polls the workspace repo's PRs and routes CI failures /
# change requests / merge conflicts into the autopilot task queue. Runs in its
# own 'scm' tmux window. Pair with CLAUDE_AUTOPILOT=1 + CLAUDE_AUTOPILOT_QUEUE=1
# so the same container consumes what it observes.
if [[ "${CLAUDE_SCM_OBSERVER:-0}" =~ ^(1|true|yes|on)$ ]]; then
    asclaude tmux new-window -t claude -n scm /usr/local/bin/claude-scm-observer
    log "SCM observer         : routing repo events into the queue (tmux window 'scm')"
    [[ "${CLAUDE_AUTOPILOT_QUEUE:-0}" =~ ^(1|true|yes|on)$ ]] || \
        log "SCM observer         : NOTE, enqueues tasks, but nothing consumes them without CLAUDE_AUTOPILOT=1 + CLAUDE_AUTOPILOT_QUEUE=1"
fi
