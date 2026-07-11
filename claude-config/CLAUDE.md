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
- Need a different toolchain version or a CLI that isn't baked in? Use `mise`,
  rootless, no `sudo`: `mise use node@22` / `python@3.12` / `go@1.23` / `rust`
  for languages, or `mise use aqua:owner/tool` / `github:owner/tool` for prebuilt
  CLIs. With the default (no egress lockdown) it all just works. Under
  `CLAUDE_EGRESS_LOCKDOWN=1`: `github:`/`aqua:`/`python@` work as-is; `pip`/`cargo`/`go`
  registry backends need `CLAUDE_EGRESS_PACKAGES=1`; and `node@`/`go@`/`rust`
  toolchains need their vendor hosts added via `CLAUDE_EGRESS_EXTRA_HOSTS`. System
  libraries (`apt`) are not available here — this is a rootless container by design.
- Installs are supply-chain-hardened: `npm`/`pnpm` run with `ignore-scripts=true`
  by default, so a dependency's post-install scripts do NOT execute. If a repo
  legitimately needs them (e.g. a native build), commit a `/workspace/.npmrc` with
  `ignore-scripts=false` to opt that repo back in. Prefer pinned, lockfiled manifests
  (`mise.lock` is honored); `claude-deps-check` flags `latest`/unpinned specs.
- Permissions are bypassed (`--dangerously-skip-permissions`). There is no
  human to approve tool calls in real time — be deliberate with destructive
  commands, and never run anything that targets paths outside `/workspace`.

## Working style

- Prefer small, reviewable commits with clear messages.
- When a task is ambiguous and no human is reachable, state your assumption in
  the commit/PR description rather than stalling.
