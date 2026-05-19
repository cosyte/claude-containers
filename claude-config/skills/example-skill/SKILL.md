---
name: example-skill
description: Baked-in example skill. Proves skills load in the container. Replace or delete it under claude-config/skills/.
---

# Example skill

This skill exists only to demonstrate that skills baked into the image are
copied to `~/.claude/skills/<name>/` and discovered by Claude Code in the
container.

When invoked, do exactly this:

1. Print: `example-skill loaded OK from the baked-in image`.
2. Show `claude --version` and the current `/workspace` git branch.
3. Stop. Do nothing else.

To add your own skills, drop one directory per skill under
`claude-config/skills/`, each containing its own `SKILL.md`, and rebuild.
