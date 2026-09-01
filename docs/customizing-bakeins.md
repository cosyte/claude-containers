# Customizing the baked-in config

`claude-config/` is copied into the image at build time and merged into
`~/.claude` on container start. The merge **only fills what's absent**, so a
container's own evolving state (sessions, history, settings you change inside)
is never clobbered by a restart. Change a bake-in → `make build` → relaunch.

Everything baked in is also overridable at runtime by mounting onto the target
path inside the container (add a `-v` in a wrapper, or use the compose file).

```
claude-config/
├── CLAUDE.md            → ~/.claude/CLAUDE.md          (copied if absent)
├── settings.json        → merged into ~/.claude/settings.json  (optional)
├── mcp/*.json           → registered via `claude mcp add-json --scope user`
├── plugins/plugins.json → unioned into settings.json (Claude auto-syncs)
├── commands/*.md        → ~/.claude/commands/          (copied if absent)
└── skills/<name>/SKILL.md → ~/.claude/skills/<name>/   (copied if absent)
```

## CLAUDE.md

Global memory for every session in the container. Keep it short; per-repo
guidance belongs in the repo's own `CLAUDE.md`. Override at runtime by mounting
a file onto `/home/claude/.claude/CLAUDE.md`.

## settings.json

The entrypoint generates a base (`permissions.defaultMode`,
`skipDangerousModePermissionPrompt`, telemetry-off env) and recursively merges,
in order: base → optional `claude-config/settings.json` → existing
per-container settings (existing wins). Drop a `claude-config/settings.json` to
add hooks, status line, etc. to every container.

Anything customized here is a **default**, not policy: this file is owned by the
agent user and a session can change it. The settings the image asserts as policy
are ALSO delivered to the root-owned `/etc/claude-code/managed-settings.json`,
which Claude Code reads above every other settings level and which a session
cannot write, so changing them here does not change them for real. See
[managed-settings.md](managed-settings.md) for what is policy and how to change
it from the host.

## MCP servers

One `*.json` per server in `claude-config/mcp/`; filename (sans `.json`) is the
server name. Registered at **user scope** on start. `.json.example` files are
inactive: rename to `.json` to enable.

- Shapes: `{"command","args","env"}` (stdio), `{"type":"http","url","headers"}`,
  `{"type":"sse","url","headers"}`.
- **Never bake secrets.** Use `${VAR}`; the entrypoint runs `envsubst` against
  the container env before registering. Provide values via `.env`
  (`claude-launch` passes the whole `.env` with `--env-file`).
- Load a subset: `claude-launch … --mcp atlassian-rovo` (repeatable), or
  `CLAUDE_MCP_ENABLED=atlassian-rovo,foo`.

Verify in a session with `/mcp`.

## Plugins

`claude-config/plugins/plugins.json` declares `extraKnownMarketplaces` and
`enabledPlugins` (`"<plugin>@<marketplace>"`). The entrypoint unions these into
`settings.json`; Claude Code installs/syncs them on startup, idempotently.
Replace the shipped example marketplace with your own. Verify with `/plugin`.

## Slash commands

Markdown files in `claude-config/commands/`, optional YAML frontmatter
(`description:`). `container-info.md` ships as a working example. Invoke as
`/container-info`. Add your own `*.md` and rebuild.

## Skills

One directory per skill under `claude-config/skills/`, each with a `SKILL.md`
(frontmatter `name:` + `description:`). `example-skill/` ships as a sanity
check. Add directories and rebuild. A baked skill directory is copied only if
that skill doesn't already exist in the container, so in-container edits
survive restarts.

## Quick proof everything loaded

SSH into a launched container (you land in the Claude tmux session) and run:

```
/mcp                # baked MCP servers (after enabling one)
/plugin             # marketplaces + enabled plugins
/container-info     # baked slash command: prints repo/version/MCP/RC facts
```

Ask Claude to "use the example-skill" to confirm skills resolve.
