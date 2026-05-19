# Baked-in MCP servers

Every `*.json` file in this directory is registered at **user scope** on
container start via `claude mcp add-json`, so it's available to every session
in the container. The filename (without `.json`) is the server name.

Files ending in `.json.example` are **inactive** — copy/rename to `.json` to
enable. The two examples here ship inactive on purpose.

## Secrets

Never bake secrets into these files. Use `${VAR}` placeholders — the entrypoint
expands them from the container's runtime environment (`envsubst`) before
registering. Supply the values at launch time via `.env` (passed through with
`--env-file`), e.g.:

```
ROVO_MCP_TOKEN=xxxxxxxx
```

The JSON shapes accepted by `claude mcp add-json` (current Claude Code):

- stdio: `{"command": "...", "args": [...], "env": {...}}`
- http:  `{"type": "http", "url": "...", "headers": {...}}`
- sse:   `{"type": "sse",  "url": "...", "headers": {...}}`

## Selecting which to load

`claude-launch ... --mcp atlassian-rovo --mcp foo` loads only the named
servers. With no `--mcp` flags, every `.json` here is loaded.

## Atlassian Rovo

`atlassian-rovo.json.example` is a representative remote (SSE) config. Confirm
the current Rovo MCP endpoint/auth in Atlassian's docs before enabling — the
URL here is illustrative. Rename to `atlassian-rovo.json` and set
`ROVO_MCP_TOKEN` in `.env` to activate.
