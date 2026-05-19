---
description: Print container/workspace facts (proves baked-in commands load)
---

Report the following about this container, concisely:

1. `whoami`, `pwd`, and the current git remote + branch in `/workspace`.
2. Output of `claude --version`.
3. Configured MCP servers (`claude mcp list`).
4. Confirm Remote Control is active by checking the running `claude` process
   args (`ps -ef | grep -- --remote-control`).

This is a baked-in example slash command. Replace or delete it in
`claude-config/commands/`.
