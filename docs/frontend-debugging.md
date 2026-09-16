## Frontend debugging (optional)

Off by default. When you want Claude to *see and drive* a frontend the agent
is building, build the browser variant: **launching on it is enough**, the
`chrome-devtools` MCP auto-enables itself with no second flag:

```bash
make build-browser                            # tags claude-code-box:browser
CLAUDE_IMAGE=claude-code-box:browser \
  ./bin/claude-launch site --workspace ./site
```

The entrypoint detects the baked Chromium + `chrome-devtools-mcp` on startup and
registers the MCP automatically. `--browser` (or `CLAUDE_BROWSER=1`) still works
and now *forces* it: on a non-browser image it **fails loud** with a rebuild
hint instead of silently doing nothing. To run the browser image but keep the
MCP off, pass `--no-browser` (or `CLAUDE_BROWSER=0`).

Either way you get the official
[chrome-devtools-mcp](https://github.com/ChromeDevTools/chrome-devtools-mcp)
inside the container: headless Chromium driven via the Chrome DevTools
Protocol. The agent now has tools to:

- **navigate / click / type / select / wait_for**: drive the page
- **evaluate_script**: run JS, read state, query the DOM
- **take_screenshot / take_snapshot**: see what's rendered
- **list_console_messages / list_network_requests / get_network_request**: read logs and requests
- **lighthouse_audit / performance_start_trace**: full perf + a11y audits
- **take_heapsnapshot** + retainer queries: chase memory leaks

Pair the browser variant with `--dev-cmd` and `--expose` from the compose
generator so Claude both starts the dev server and debugs against it (the
generator's `--browser` selects the browser image and enables the MCP):

```bash
./bin/claude-compose-gen --org ORG --out FILE \
  --active site \
  --expose site:4321:4321 \
  --dev-cmd 'site=…--host 0.0.0.0 --port 4321' \
  --browser site
```

Cost: ~200 MB image-size delta for the baked Chromium when WITH_BROWSER=1; the
lean default image is unchanged. Headless-only inside the container; the agent
reads pages back via screenshots and DOM queries. Full design rationale:
[docs/architecture.md](architecture.md#decision-frontend-debugging-is-an-opt-in-image-variant);
runbook: [docs/troubleshooting.md](troubleshooting.md#frontend-debugging---browser--claude_browser).
