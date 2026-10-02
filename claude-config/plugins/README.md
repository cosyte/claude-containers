# Baked-in plugins

`plugins.json` declares plugin **marketplaces** and which **plugins** are
enabled. On container start the entrypoint unions:

- `extraKnownMarketplaces` → settings.json
- `enabledPlugins`         → settings.json

Claude Code reads these from `~/.claude/settings.json` and registers the
marketplaces on startup. A plugin from a git source may still need installing
once (`claude plugin install <plugin>@<marketplace>`): enabling it in settings
does not by itself install it. Plugins declared for one container at creation
time (`--marketplace` / `--plugin`) are installed at boot by `claude-kit`.

`enabledPlugins` keys are `"<plugin>@<marketplace>"`. The marketplace name is
the key under `extraKnownMarketplaces`.

The shipped example points at a public git marketplace and enables one plugin
so `/plugin` has something to show out of the box. Replace it with your own
marketplaces/plugins, then rebuild (or mount your own `plugins.json` /
`settings.json` at runtime to override).

Verify or list inside a running session with the `/plugin` slash command.
