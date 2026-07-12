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
  libraries (`apt`) are not available — you have no `sudo` and no `apt`, by design.
  A system library needs a base-image rebuild.
- Installs are supply-chain-hardened: `npm`/`pnpm` run with `ignore-scripts=true`
  by default, so a dependency's post-install scripts do NOT execute. If a repo
  legitimately needs them (e.g. a native build), commit a `/workspace/.npmrc` with
  `ignore-scripts=false` to opt that repo back in. Prefer pinned, lockfiled manifests
  (`mise.lock` is honored); `claude-deps-check` flags `latest`/unpinned specs.
- Permissions are bypassed (`--dangerously-skip-permissions`). There is no
  human to approve tool calls in real time — be deliberate with destructive
  commands, and never run anything that targets paths outside `/workspace`.

## Installing packages

`mise` provisions **interpreters/toolchains**, not language packages. The chain is
always **mise first, then the language's own package manager** — pick the right first
invocation per ecosystem below and you get a rootless install that lands in the shared
`/cache` volume for the next launch and every parallel worker. The system Python 3.11
in the image is a Debian **PEP 668 externally-managed** interpreter and installing into
it will refuse; the fixes below never touch it.

- **Python.** `mise use python@3.12` first, then `pip install <pkg>` against that
  interpreter — `pip install` against system `python3` is a dead-end (`--user`,
  `--break-system-packages`, and `uv pip install --system` all target the same
  externally-managed interpreter and are refused too). A one-off script that only
  needs a package for a single invocation: `uv run --with <pkg> python -c '…'`
  (ephemeral, no `mise use` required).
- **Node.** `mise use node@22` first, then `pnpm add <pkg>` or `npm install <pkg>`
  in a repo that has a manifest. The agent-user `~/.npmrc` sets
  `ignore-scripts=true` (PKG-5); if a repo legitimately needs lifecycle scripts,
  commit a per-repo `/workspace/.npmrc` with `ignore-scripts=false` to opt it back
  in.
- **Rust.** `mise use rust` first, then `cargo add <crate>` in a Cargo project (or
  `cargo install <bin>` for a binary tool).
- **Go.** `mise use go@1.23` first, then `go install <pkg>@<ver>` (module-aware
  install; the binary lands in `/cache/go/bin`, already on `PATH`).
- **System libraries (`apt`).** You have **no `sudo`** and no `apt` — rootless by
  design, and there is currently no self-service path to install one. Needing a
  new syslib means asking the operator for a base-image rebuild, not running
  `apt` yourself.
- **Shared cache (`/cache`).** `mise`, `pip`, `cargo`, `go`, `npm`/`pnpm`, and
  `uv` are all pointed at `/cache` (PKG-3), so a package fetched by one container
  is a cache hit for the next launch and for parallel workers on the same host.
  Nothing to configure — it is where every install above lands.

**Refuse the dead-ends.** Never `sudo` anything (there is no `sudo` in a leaf
container by design), never `pip install --break-system-packages`, and never edit
`/etc`, `/opt`, or `/usr` — those paths are baked, owned by root, and mutating
them from an agent session is either impossible or a supply-chain foot-gun. If a
tool insists it needs one of those, the answer is `mise use` (rootless, per-user)
or a manifest change, never an escalation.

## Working style

- Prefer small, reviewable commits with clear messages.
- When a task is ambiguous and no human is reachable, state your assumption in
  the commit/PR description rather than stalling.
