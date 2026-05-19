# Baked-in plugins

`plugins.json` declares plugin **marketplaces** and which **plugins** are
enabled. On container start the entrypoint unions:

- `extraKnownMarketplaces` → settings.json
- `enabledPlugins`         → settings.json

Claude Code reads these from `~/.claude/settings.json` and installs/syncs the
marketplaces and enabled plugins automatically on startup. This is idempotent —
already-installed plugins are skipped.

`enabledPlugins` keys are `"<plugin>@<marketplace>"`. The marketplace name is
the key under `extraKnownMarketplaces`.

The shipped example points at a public git marketplace and enables one plugin
so `/plugin` has something to show out of the box. Replace it with your own
marketplaces/plugins, then rebuild (or mount your own `plugins.json` /
`settings.json` at runtime to override).

Verify or list inside a running session with the `/plugin` slash command.
