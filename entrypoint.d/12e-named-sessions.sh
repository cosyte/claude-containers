# shellcheck shell=bash
# --- 12e. Named sessions ------------------------------------------------------
# CLAUDE_SESSIONS (claude-launch --session, claude-compose-gen --session) declares more
# Claude sessions beside main, each in its own tmux window with its own Remote Control
# link, directory, model and optional first prompt / goal; `claude-sessions new` adds more
# at runtime and those persist on the config volume. `prepare` (§12b, before main started)
# reconciled the declaration; `boot` starts every registered session that was not stopped
# by hand, resuming its last conversation. It never fails the boot: a bad entry is skipped
# with a log line.
#
# The supervisor always runs (it is cheap): it records which conversation each window is
# running, so a restart or an RC recovery resumes exactly that one, and keeps a Remote
# Control watchdog beside every named session.
asclaude /usr/local/bin/claude-sessions boot --no-reconcile \
    || log "WARNING: claude-sessions boot failed; named sessions may be missing (claude-sessions ls)"
asclaude /usr/local/bin/claude-sessions supervise &
# shellcheck disable=SC2034  # stopped by shutdown() (§13)
SESSIONS_PID=$!
# The kit's optional start command (CLAUDE_EXTRA_START_CMD), once per container start, in the
# background, after the sessions are up. Never fatal. Run even with no command set: start first
# clears the last boot's kit-start.pid (on the config volume), which claude-orphan-reaper reads.
# Left behind after an operator drops the command, its session id could name a session this boot
# gave to something else, whose orphans the reaper would then never end.
asclaude /usr/local/bin/claude-kit start \
    || log "WARNING: claude-kit start failed; CLAUDE_EXTRA_START_CMD did not run (claude-kit status)"
