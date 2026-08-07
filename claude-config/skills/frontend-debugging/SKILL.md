---
name: frontend-debugging
description: Debug a web frontend from inside this container using the chrome-devtools MCP, navigate a page, read the DOM/console/network, screenshot, evaluate JS, drive user flows, and profile performance. Use when investigating a UI bug, a blank/broken page, console or network errors, layout/styling problems, or frontend performance. Needs the `chrome-devtools` MCP (the browser image variant).
---

# Frontend debugging with the chrome-devtools MCP

This container can drive a real Chrome to debug a web frontend. Use this skill
whenever you're chasing a UI bug, a broken page, console/network errors, a
layout problem, or a slow page, instead of guessing from source alone.

## First: confirm you have the tools

This works only in a **browser image variant** (built `WITH_BROWSER=1`, e.g.
`make build-browser`). On that image the `chrome-devtools` MCP is registered
**automatically**: no `--browser` flag needed (the entrypoint auto-detects the
baked Chromium; `--browser` / `CLAUDE_BROWSER=1` only *forces* it, and
`--no-browser` / `CLAUDE_BROWSER=0` opts out). If no `chrome-devtools` / browser
tools are available, this is the lean image or someone opted out: say so plainly
instead of guessing: the session needs relaunching on a `make build-browser`
image.

## Mental model

- **Chromium is headless**: there is no visible window. You "see" the page two
  ways: `take_snapshot` (a structured text/accessibility tree, cheap, gives
  element references you can act on) and `take_screenshot` (a PNG: for
  anything visual). Reach for the snapshot first; screenshot when the bug is
  about layout, styling, or rendering.
- **The browser runs inside this container**, so it reaches a dev server at
  `http://localhost:<port>` directly. The profile is isolated and fresh every
  session: no saved logins or cookies.
- The MCP exposes the full Chrome DevTools surface (50+ tools). The tool names
  below are the common ones; discover the exact set from the MCP itself.

## The debugging loop

1. **Get the app running.** Start the dev server in `/workspace`, bound to
   `0.0.0.0` (e.g. `pnpm dev --host 0.0.0.0 --port 4321`). If a tmux `dev`
   window already auto-started it (`CLAUDE_DEV_CMD`), reuse that. Confirm it
   responds before navigating.
2. **Navigate** to the page under test (`navigate_page` →
   `http://localhost:<port>/...`).
3. **See the page.** `take_snapshot` to read structure, text, and state and to
   get element refs; `take_screenshot` when the problem is visual.
4. **Read the evidence: don't hypothesize first:**
   - console messages: JS errors, warnings, app logs;
   - network requests: failed calls (4xx/5xx), wrong payloads, slow or missing
     assets; drill into a specific request for headers/body;
   - `evaluate_script`: inspect DOM, computed styles, and app/framework state.
5. **Reproduce the flow** with `click` / `fill` / `hover` / form fills, waiting
   for async UI to settle, then re-snapshot to see the result.
6. **Fix in `/workspace`**, let the dev server hot-reload (or restart it),
   re-navigate, and confirm: clean console, expected network, correct snapshot.
7. **Performance work:** capture a performance trace (or Lighthouse) for slow
   pages and Core Web Vitals; emulate slow CPU / slow network to reproduce
   real-device conditions; set the viewport to match the affected device.

## Discipline

- Change one thing at a time; re-verify against the **page**, not assumptions.
- Prefer the snapshot's element references over brittle hand-written CSS
  selectors.
- Quote the actual console/network evidence in your reasoning.
- Match the viewport to the report (`resize_page`): some bugs are
  device/size-specific.

## Gotchas

- The dev server must bind `0.0.0.0` (or at least be reachable on `localhost`
  inside the container) or navigation just hangs.
- Chromium runs with `--no-sandbox` here: that's required in an unprivileged
  container; sandbox-related warnings are expected, not the bug.
- Fresh profile each session: if a page needs auth, log in as part of the flow;
  nothing is remembered between sessions.
