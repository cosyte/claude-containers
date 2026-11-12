---
id: install-a-kit
title: Install a kit at session start
sidebar_label: Install a kit
description: "Install a plugin marketplace of your own, its plugins and a start command when a container starts, with no image rebuild."
---

# Install a kit at session start

A **kit** is a git repository of your own that is a Claude Code plugin marketplace: skills,
commands, hooks and agents packaged as plugins, and optionally a tool it ships. The image
installs one when the container starts, from a git URL, with no rebuild. The repository can
be private: it is cloned with the container's own git credentials (the `gh` credential
helper over https when `GH_TOKEN` is set, or the SSH deploy key). Three values declare it,
all optional:

| Value | Flag (`claude-launch` / `claude-compose-gen`) | What it does |
|---|---|---|
| `CLAUDE_EXTRA_MARKETPLACES` | `--marketplace NAME=URL[#REF]` / `--marketplace SVC=NAME=URL[#REF]` | registers the marketplace in `settings.json` (`extraKnownMarketplaces`, git source). `NAME` is the name the marketplace gives itself in `.claude-plugin/marketplace.json`. |
| `CLAUDE_EXTRA_PLUGINS` | `--plugin PLUGIN@NAME` / `--plugin SVC=PLUGIN@NAME[,…]` | enables each plugin (`enabledPlugins`) and installs it at user scope if it is not installed yet. |
| `CLAUDE_EXTRA_START_CMD` | `--start-cmd COMMAND` / `--start-cmd SVC=COMMAND` | one command, run once per container start as the agent user, in the background, after the sessions are up. Output: `~/.claude/kit-start.log`. |

```
# one container
claude-launch site --repo https://github.com/you/site.git \
    --marketplace 'team-kit=https://git.example.com/you/team-kit.git#v1.2.0' \
    --plugin helper@team-kit \
    --start-cmd 'uv tool install git+https://git.example.com/you/team-kit.git@v1.2.0 && team-kit serve --ensure'

# a stack service (scenario .conf lines, or the generator's command line)
--marketplace site=team-kit=https://git.example.com/you/team-kit.git#v1.2.0
--plugin site=helper@team-kit
--start-cmd site=uv tool install git+https://git.example.com/you/team-kit.git@v1.2.0 && team-kit serve --ensure
```

What happens at boot, in order (`bin/claude-kit`, each step a warning in the boot log if it
fails, never a failed boot):

1. **settings**: the marketplaces and plugins are merged into `~/.claude/settings.json`.
2. **install**: before any Claude session exists, each declared marketplace the CLI does not
   know is added (`claude plugin marketplace add URL#REF`) and each declared plugin it does
   not have is installed (`claude plugin install PLUGIN@NAME --scope user`), each call bounded
   by `CLAUDE_KIT_TIMEOUT` (default 120 s). Enabling a plugin from a git source in
   `settings.json` does not install it by itself, which is why this step exists. A plugin's
   own `SessionStart` hook therefore runs from every session's first start. Sessions start
   after this step, so a kit host that cannot be reached delays them by up to one timeout
   (its plugins are then skipped); under `CLAUDE_EGRESS_LOCKDOWN` a kit on a host other than
   GitHub needs that host in `CLAUDE_EGRESS_EXTRA_HOSTS`.
3. **warm** (umbrella mode only): the workspace's own marketplaces are registered before the
   first session, so it loads their plugins whole (below).
4. **start**: after the sessions are up, the start command runs once, detached.

`claude-kit status` (inside the container) prints what is declared, registered and installed.

**An umbrella's own marketplaces.** In umbrella mode (`GIT_UMBRELLA`,
[Run several repos in one container](./run-several-repos.md)) the workspace's project settings
(`/workspace/.claude/settings.json`) can declare marketplaces of their own in
`extraKnownMarketplaces`, such as a plugin kept in the umbrella and declared as a `directory`
source. Claude Code registers such a marketplace in the config
(`~/.claude/plugins/known_marketplaces.json`) at the first start in the workspace, and on a
fresh config that first session lists the plugin without loading its agents, skills or hooks;
the next start, or `/reload-plugins`, loads them. So after the install step,
`claude-kit warm /workspace` makes one throwaway start there whenever the config has not
registered each declared marketplace yet: print mode with nothing on stdin, so no prompt and
no model call, with every hook off, no MCP server and no transcript, bounded by
`CLAUDE_KIT_TIMEOUT`. It runs after the egress lockdown, as the sessions do. Once each
marketplace is registered, later boots skip it. A start that fails or registers nothing is a
warning naming the marketplaces, and the first session then needs `/reload-plugins` once.

**Pin or auto-update, not both.** Without `#REF` a marketplace follows its repository's
default branch and is registered with `"autoUpdate": true`: Claude Code refreshes it and
updates its installed plugins in the background after startup. With `#REF` (a branch or a
tag) the marketplace is pinned and registered with `"autoUpdate": false`. The two contradict
each other: an auto-updating marketplace moves its plugins whenever the catalog moves, which
is exactly what a pin is there to prevent, and a plugin entry that pins its own source (`ref`
or `sha` in `marketplace.json`) would be moved by the next catalog refresh. Pin when the kit
and something outside it (a tool the start command installs, a running service) must stay at
the same version.

**Moving a pin.** The declaration is the operator's last word: change `#REF` (or add or drop
it) and recreate the container. At the next start the marketplace is registered again at the
declared ref and each declared plugin from it is updated to what that ref offers (an older
ref moves it back), so the plugins and whatever the start command installs move together.
Nothing is removed along the way: plugins you installed from that marketplace by hand stay
installed and are not updated by the hook.

The start command runs with the agent user's privileges and environment, like `--dev-cmd`:
it is part of the container's declaration, not something a session can set. It runs in a login
shell on the sessions' PATH (with the mise shims, `claude` and `~/.local/bin`, where `uv tool
install` puts a CLI), set again after the shell's
profile, which would reset it to the system default. Keep it
idempotent (it runs on every start) and quick to return (start a long-lived service in the
background or in a tmux window of its own). References: Claude Code's
[`extraKnownMarketplaces`](https://code.claude.com/docs/en/settings-reference#extraknownmarketplaces)
and [plugin installation](https://code.claude.com/docs/en/plugins/install) (read 2026-10-02).

## Reference

- [Launcher commands](./launcher-commands.md)
- [Environment variables](./environment-variables.md)
