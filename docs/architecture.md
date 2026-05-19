# Architecture & design decisions

## Component map

- **Dockerfile** — `node:24-bookworm-slim`, system packages, `gh`, `uv`,
  Claude Code via npm (pinned), non-root `claude` user, hardened sshd config,
  baked-in `claude-config/`.
- **entrypoint.sh** — runs as root: refuses API-key auth, sets up sshd, fixes
  volume ownership, reconciles credentials, pre-accepts trust, merges baked-in
  config, prepares `/workspace`, then `gosu`-drops to `claude` and launches
  Claude Code inside a detached tmux session. Stays PID 1 for clean signals.
- **claude-session** — the tmux pane command: `cd /workspace`, exec
  `claude --dangerously-skip-permissions --remote-control "<project>"`, and
  fall back to a shell if Claude exits so SSH stays usable.
- **bash_profile** — interactive SSH logins `exec tmux attach` to the live
  `claude` session; non-interactive SSH (scp/rsync) is untouched.
- **bin/** — `claude-launch/list/stop/rm/logs` over a shared `_common.sh`.
- **.claude/skills/claude-containers/** — project skill: when this repo is
  opened in Claude Code, it teaches the model the architecture, invariants,
  and operational playbook so it can drive build/login/launch/customize/debug.

## Verified facts (Claude Code 2.1.144)

Everything below was checked against the installed binary, not just docs:

- `--remote-control [name]` is a real top-level flag; `-n/--name` is a separate
  display-name flag. `claude remote-control --permission-mode` explicitly
  accepts `bypassPermissions` in 2.1.144.
- `--dangerously-skip-permissions` ≡ `--permission-mode bypassPermissions`.
- Setting `CLAUDE_CONFIG_DIR` relocates **everything**, including the otherwise
  HOME-level `.claude.json`, into that directory. Verified empirically — this
  is what lets one per-container volume capture all session state.
- Workspace trust + onboarding live in `<config>/.claude.json` as
  `hasCompletedOnboarding` and `projects["<path>"].hasTrustDialogAccepted`.
- Plugins are declarative: `settings.json` `extraKnownMarketplaces` +
  `enabledPlugins` are synced by Claude Code on startup.
- `--bare` forces API-key-only auth and disables plugins/CLAUDE.md, so it is
  **not** used here.

## Decision: split credentials from per-container config (deviation)

The spec describes one shared `claude-auth` volume mounted at
`/home/claude/.claude` across all containers. Implemented differently, on
purpose:

- `claude-auth` (shared) → `/auth`, credentials only.
- `claude-config-<project>` (per container) → `/home/claude/.claude`
  (`CLAUDE_CONFIG_DIR`), all session/history/state.

Reason: Claude rewrites `.claude.json`, `history.jsonl` and `sessions/`
constantly. With one shared config dir, parallel containers race those files,
and every container's workspace is `/workspace` so they collide on the same
`projects["/workspace"]` key — one session could resume another's. That breaks
spec acceptance criteria 6 (resume preserved) and 7 (independent parallel
containers). The split preserves the spec's actual goal — *one login, every
container reuses it* — via a shared credentials volume, while keeping sessions
isolated.

**Credential convergence.** Claude refreshes the OAuth token and rewrites
`.credentials.json` in its config dir. A background loop in the entrypoint keeps
`/auth/.credentials.json` and the per-container copy converged (newest mtime
wins, atomic replace, ~30s). Net effect: one login propagates to all
containers, and refreshed tokens propagate back through the shared volume.
Limitation: if two containers refresh within the same ~30s window the later
write wins; refreshes are infrequent (hours apart) so this is acceptable for a
homelab. A token-rotation regression would surface as a re-login prompt, not
data loss.

## Decision: per-container workspace defaults to a named volume

`claude-ws-<project>` (named volume) is the default — consistent with the other
volumes, cleanly removed by `claude-rm --purge`, and matches the spec's
"per-container workspace volume" wording. `--workspace <path>` bind-mounts a
host checkout instead (use that when you want the repo directly on the host
filesystem for backups/inspection). Back up a named volume with
`docker run --rm -v claude-ws-<p>:/w -v "$PWD":/b alpine tar czf /b/<p>.tgz -C /w .`

## Decision: MCP secrets are runtime-only

Baked `mcp/*.json` use `${VAR}` placeholders, expanded by `envsubst` from the
container environment at registration time. Secrets come from `.env`
(`--env-file`), never the image. Confirms the spec's stated preference.

## Decision: one substantive build stage

A heavy builder stage was considered and rejected: the image weight is the
required system packages (`build-essential`, Python, gh) which must be in the
final image per spec. Claude Code is pure JS via npm with the cache cleaned. A
multi-stage split wouldn't meaningfully shrink the result, so the final stage
stays single with aggressive apt/npm cleanup. (There is one trivial throwaway
stage that only re-exports the `uv` binaries — BuildKit forbids variable
expansion directly in `COPY --from=`, so it must go through a named stage.)
Multi-arch
(`linux/amd64,linux/arm64`) is handled by `docker buildx` (`make build-all` /
`make push`); `make build` loads the host arch locally because Docker can't
`--load` a multi-arch manifest into the local engine.

## Decision: workspace trust pre-acceptance

The cleanest non-interactive method is seeding `<config>/.claude.json` with
`hasCompletedOnboarding: true` and `projects["/workspace"]
.hasTrustDialogAccepted: true` (the exact shape Claude Code uses). Done with a
`jq` merge that only fills missing keys. No `--bare`, no piping `/dev/null`,
no `-p` — those each disable features we need.

## Permission mode & Remote Control

Launch is `claude --dangerously-skip-permissions --remote-control "<project>"`.
On 2.1.144 these compose correctly. Belt-and-suspenders: `settings.json` also
sets `permissions.defaultMode = bypassPermissions` and
`skipDangerousModePermissionPrompt: true` (a real settings key). If a future
Claude Code regresses the interaction, set `CLAUDE_PERMISSION_MODE=acceptEdits`
— see troubleshooting for the end-to-end verification.

## Acceptance

| # | Criterion | How it's met / verify |
|---|---|---|
| 1 | `make build` works (amd64+arm64) | `make build` (host arch, loaded); `make build-all`/`make push` for both arches via buildx |
| 2 | `make login` persists creds | Login-mode entrypoint runs `claude auth login --claudeai` with `CLAUDE_CONFIG_DIR=/auth`; creds land in `claude-auth` |
| 3 | launch clones + starts + prints | `claude-launch myproj --repo …`; entrypoint clones, launches with flags; connect info printed |
| 4 | SSH → live tmux | `bash_profile` `exec tmux attach -t claude`; session started by entrypoint before sshd accepts logins |
| 5 | Appears in app, named, green | `--remote-control "<project>"`, outbound HTTPS; name = project name |
| 6 | stop→launch resumes | Per-container `claude-config`/`claude-ws` volumes survive `docker stop`; `claude-launch` does `docker start` |
| 7 | Two parallel, independent | Distinct container names, ports (`alloc_port`), per-container volumes, separate app sessions |
| 8 | Baked MCP/plugins/commands/skills usable | In a session: `/mcp`, `/plugin`, `/container-info`, the `example-skill`; see customizing-bakeins.md |
