# Global operating notes (baked-in)

This file is copied to `~/.claude/CLAUDE.md` inside every container at every
start, so an edit made there is replaced at the next one. It is the global memory
for every Claude Code session here. Override it by mounting your own file onto
`/home/claude/.claude/CLAUDE.md` (a mounted file is left alone), or edit this file
and rebuild. What this particular container has (browser, GPU, toolchains, space)
is in the "This container" section of the managed memory, probed at each start.

Keep this short. Project-specific guidance belongs in the repo's own
`CLAUDE.md`, not here.

## Environment

- You are running in a disposable Docker container. The host is isolated from
  you; the repo under `/workspace` is the thing that matters and is persisted.
- `git`, `gh`, `rg`, `fzf`, `jq`, `yq`, `python3`, `uv`, and `node` are available, and so are
  `file`, `bc`, `zip`/`unzip`, `xxd`, `pdftotext`, `column`, `sqlite3`, `rsync`, `ss`/`ip`,
  `dig` and `fuser`.
- The system Python (`/usr/bin/python3`) is 3.13 with `yaml`, `PIL` and `pypdf`;
  anything else via `uv run --with <pkg>`.
- Kill a process by its PID, never `pkill -f <pattern>`: the pattern is in your own
  command line, so it kills your own shell.
- Never `find /` (or `bfs`, `du`, `rg` over `/` or all of `/cache`): search a named
  directory. A walk of the whole disk outlives a timed-out tool call and keeps the host's
  disk busy for hours; the orphan reaper ends such leftovers after 2 h.
- Build outputs go to `/scratch` (`$TMPDIR`): a disk volume, cleared at every boot.
  On a GPU or browser service `/scratch` is a RAM tmpfs of a few GiB instead, charged to
  memory: there, put a big build tree in `/state/tmp` and delete it when done, since
  nothing trims `/state`. `/cache` is shared with every container: tool caches only.
- A tool with no version set in this container reads "command not found": install it
  with `mise use` (or `pip install` / `npm i -g` a CLI into a mise toolchain), then run
  `mise reshim && claude-mise-shims` so it is on `PATH`. A version a repo pins that is
  not installed yet installs on first use; if a tool still reports the image's version
  instead of the pinned one, run `mise install` in that repo, then `claude-mise-shims`.
- Gradle builds are capped at N workers (the "Gradle" line of this container's facts), and
  daemons stop after 30 min idle. Both are in `GRADLE_OPTS`, which beats a repo's
  `gradle.properties`; `--max-workers=N` on the command line beats it.
- Wrap a heavy build (a Gradle gate, R8, a check-all) in `claude-build-slot -- <cmd>`: sibling
  sessions' builds then take turns instead of all timing out together; `claude-build-slot status`.
- Need a different toolchain version or a CLI that isn't baked in? Use `mise`,
  rootless, no `sudo`: `mise use node@22` / `python@3.12` / `go@1.23` / `rust`
  for languages, or `mise use aqua:owner/tool` / `github:owner/tool` for prebuilt
  CLIs. With the default (no egress lockdown) it all just works. Under
  `CLAUDE_EGRESS_LOCKDOWN=1`: `github:`/`aqua:`/`python@` work as-is; `pip`/`cargo`/`go`
  registry backends need `CLAUDE_EGRESS_PACKAGES=1`; and `node@`/`go@`/`rust`
  toolchains need their vendor hosts added via `CLAUDE_EGRESS_EXTRA_HOSTS`. System
  libraries (`apt`) are not available: you have no `sudo` and no `apt`, by design.
  A system library needs a base-image rebuild.
- Installs are supply-chain-hardened: `npm`/`pnpm` run with `ignore-scripts=true`
  by default, so a dependency's post-install scripts do NOT execute. If a repo
  legitimately needs them (e.g. a native build), commit a `/workspace/.npmrc` with
  `ignore-scripts=false` to opt that repo back in. Prefer pinned, lockfiled manifests
  (`mise.lock` is honored); `claude-deps-check` flags `latest`/unpinned specs.
- `/cache` is ONE volume shared by every container on this host, all as the same
  user, so anything kept there is readable from every other container: tool caches
  only. Keep a database, a key or a token in `/state/<app>` (`$CLAUDE_STATE_DIR`),
  this container's own volume, which no other container mounts. A worktree or clone
  of a repo, a planning folder or a test key is private too: `/state/wt/<repo>/<branch>`
  or `/state/tmp` if it must last, `/scratch` (`$TMPDIR`, cleared at boot) if not.
- Permissions are bypassed (`--dangerously-skip-permissions`). There is no
  human to approve tool calls in real time: be deliberate with destructive
  commands, and never run anything that targets paths outside `/workspace`.

## Installing packages

`mise` provisions **interpreters/toolchains**, not language packages. The chain is
always **mise first, then the language's own package manager**: pick the right first
invocation per ecosystem below and you get a rootless install that lands in the shared
`/cache` volume for the next launch and every parallel worker. The system Python 3.13
in the image is a Debian **PEP 668 externally-managed** interpreter and installing into
it will refuse; the fixes below never touch it.

- **Python.** `mise use python@3.12` first, then `pip install <pkg>` against that
  interpreter: `pip install` against system `python3` is a dead-end (`--user`,
  `--break-system-packages`, and `uv pip install --system` all target the same
  externally-managed interpreter and are refused too). A one-off script that only
  needs a package for a single invocation: `uv run --with <pkg> python -c '…'`
  (ephemeral, no `mise use` required).
- **Node.** `mise use node@22` first, then `pnpm add <pkg>` or `npm install <pkg>`
  in a repo that has a manifest. The agent-user `~/.npmrc` sets
  `ignore-scripts=true`; if a repo legitimately needs lifecycle scripts,
  commit a per-repo `/workspace/.npmrc` with `ignore-scripts=false` to opt it back
  in.
- **Rust.** `mise use rust` first, then `cargo add <crate>` in a Cargo project (or
  `cargo install <bin>` for a binary tool).
- **Go.** `mise use go@1.23` first, then `go install <pkg>@<ver>` (module-aware
  install; the binary lands in `/cache/go/bin`, already on `PATH`).
- **System libraries (`apt`).** You have **no `sudo`** and no `apt`: rootless by
  design, and there is currently no self-service path to install one. Needing a
  new syslib means asking the operator for a base-image rebuild, not running
  `apt` yourself.
- **Shared cache (`/cache`).** `mise`, `pip`, `cargo`, `go`, `npm`/`pnpm`, and
  `uv` are all pointed at `/cache`, so a package fetched by one container
  is a cache hit for the next launch and for parallel workers on the same host.
  Nothing to configure: it is where every install above lands.

**Refuse the dead-ends.** Never `sudo` anything (there is no `sudo` in a leaf
container by design), never `pip install --break-system-packages`, and never edit
`/etc`, `/opt`, or `/usr`: those paths are baked, owned by root, and mutating
them from an agent session is either impossible or a supply-chain foot-gun. If a
tool insists it needs one of those, the answer is `mise use` (rootless, per-user)
or a manifest change, never an escalation.

## Other sessions in this container

You may not be the only Claude session here: `claude-sessions ls` lists them (each is a
tmux window with its own Remote Control link and directory). Sessions in the same
directory share one git working tree, so before committing there, check that no sibling
is mid-change (`git status`, `claude-sessions ls` for a busy one), and never force-push or
reset a branch another session may be on. `claude-sessions new NAME --dir D --prompt TEXT`
starts a sibling for independent work when the operator asks for one.

## Working style

- Prefer small, reviewable commits with clear messages.
- When a task is ambiguous and no human is reachable, state your assumption in
  the commit/PR description rather than stalling.
