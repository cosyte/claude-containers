# Global operating notes (baked-in)

This file is copied to `~/.claude/CLAUDE.md` inside every container on first
start. It is the global memory for every Claude Code session here. Override it
by mounting your own file onto `/home/claude/.claude/CLAUDE.md`, or just edit
this file and rebuild.

Keep this short. Project-specific guidance belongs in the repo's own
`CLAUDE.md`, not here.

## Environment

- You are running in a disposable Docker container. The host is isolated from
  you; the repo under `/workspace` is the thing that matters and is persisted.
- `git`, `gh`, `rg`, `fzf`, `jq`, `python3`, `uv`, and `node` are available.
- Permissions are bypassed (`--dangerously-skip-permissions`). There is no
  human to approve tool calls in real time — be deliberate with destructive
  commands, and never run anything that targets paths outside `/workspace`.

## Working style

- Prefer small, reviewable commits with clear messages.
- When a task is ambiguous and no human is reachable, state your assumption in
  the commit/PR description rather than stalling.
