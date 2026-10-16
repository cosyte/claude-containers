# shellcheck shell=bash
# --- 10b. Register chrome-devtools-mcp (frontend debugging) ------------------
# Registers the Chrome DevTools MCP server so Claude can navigate, evaluate,
# inspect console/network, take screenshots, run Lighthouse, etc. against any
# frontend the agent spins up in /workspace.
#
# CLAUDE_BROWSER is TRI-STATE: the browser image is meant to "just work", so a
# baked variant auto-enables the MCP with no second flag:
#   • unset / empty / other  → AUTO: register iff the browser variant is baked
#     (both chrome-devtools-mcp AND chromium on PATH, the functional signal a
#     registration actually needs; the image also carries a `claude.browser`
#     LABEL the launcher pre-flight reads). A lean image stays silent.
#   • 1|true|yes|on          → FORCE ON: register; if the binaries are NOT baked,
#     fail LOUD + actionable (rebuild hint), never a silent no-op.
#   • 0|false|no|off         → OPT OUT: skip even on a browser image.
# Registration is idempotent (the `claude mcp get` guard below), so re-runs and
# a resumed session never double-register. Headless, isolated profile (clean per
# session); --no-sandbox is required in unprivileged Docker.
#
# The --chromeArg flags below need chrome-devtools-mcp >=1.0 (the Dockerfile pin
# asserts this at build time). On 0.x they were silently dropped by yargs, Chrome
# exited with "No usable sandbox!", and every tool call failed "Target closed".
# --no-usage-statistics opts out of the telemetry 1.x sends to Google by default.
# _browser_baked, _cb and BROWSER_MCP are set in §7b.
_register_chrome_devtools_mcp() {
    if asclaude claude mcp get chrome-devtools >/dev/null 2>&1; then
        log "MCP 'chrome-devtools' already configured, skipping"
        return 0
    fi
    # Resolve the SAME chromium the detection probe found, rather than hardcoding
    # /usr/bin/chromium, so a variant that installs chromium elsewhere (or as a
    # differently-named binary on PATH) can't auto-register a config that then
    # points at a missing executable. Fall back to /usr/bin/chromium if unresolved.
    local chromium_path cdt_json
    chromium_path="$(command -v chromium 2>/dev/null || echo /usr/bin/chromium)"
    cdt_json="$(jq -n --arg exe "$chromium_path" '{
        type: "stdio",
        command: "chrome-devtools-mcp",
        args: [
            "--executablePath", $exe,
            "--headless",
            "--isolated",
            "--chromeArg=--no-sandbox",
            "--chromeArg=--disable-dev-shm-usage",
            "--chromeArg=--disable-gpu",
            "--no-usage-statistics"
        ],
        env: { CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS: "1" }
    }')"
    if asclaude claude mcp add-json --scope user chrome-devtools "$cdt_json" >/dev/null 2>&1; then
        log "Registered MCP server 'chrome-devtools' (headless Chromium)"
    else
        log "WARNING: failed to register chrome-devtools MCP"
        _browser_mcp_failed
    fi
}
# §7c and §8e acted on BROWSER_MCP=on; a registration that failed makes both untrue, so
# correct the session's facts line and take back an unmodified frontend-debugging skill.
_browser_mcp_failed() {
    # shellcheck disable=SC2034  # the decision §7b made, kept true for whatever reads it next
    BROWSER_MCP=off
    if grep -qF "$FACTS_MARK" "$SESSION_MD" 2>/dev/null; then
        sed -i 's/^- chrome-devtools MCP: on$/- chrome-devtools MCP: off (its registration failed at start)/' "$SESSION_MD" || true
    fi
    local t="$CLAUDE_CONFIG_DIR/skills/frontend-debugging"
    if [[ -d "$t" ]] && diff -rq "$BAKE_DIR/skills/frontend-debugging" "$t" >/dev/null 2>&1; then
        rm -rf "$t"
        log "Skill frontend-debugging: removed, the chrome-devtools MCP is not registered"
    fi
}
# shellcheck disable=SC2154  # _cb is set in §7b
case "$_cb" in
    1|true|yes|on)
        # Explicit request: must be satisfiable, else fail loud (never silent).
        if _browser_baked; then
            _register_chrome_devtools_mcp
        else
            log "ERROR: CLAUDE_BROWSER=1 (or --browser) requested, but this image has no"
            log "       chrome-devtools-mcp / chromium baked in: the MCP cannot be enabled."
            log "       Rebuild the browser variant:  make build-browser"
            log "       (or:  make build WITH_BROWSER=1 CLAUDE_IMAGE=<tag>)."
            log "       Frontend debugging is UNAVAILABLE in this container until you do."
        fi
        ;;
    0|false|no|off)
        # Explicit opt-out: honored even on a browser image.
        # A registration a past start made lives on in the config volume: drop it, or the
        # session would have the tools while its facts say off.
        if asclaude claude mcp get chrome-devtools >/dev/null 2>&1; then
            if asclaude claude mcp remove --scope user chrome-devtools >/dev/null 2>&1; then
                log "chrome-devtools MCP disabled (CLAUDE_BROWSER=off): removed the registration a past start made"
            else
                log "WARNING: CLAUDE_BROWSER=off, but the chrome-devtools MCP a past start registered could not be removed"
            fi
        elif _browser_baked; then
            log "chrome-devtools MCP disabled (CLAUDE_BROWSER=off); skipping"
        fi
        ;;
    *)
        # Auto: a browser image enables the MCP by itself; a lean image is silent.
        if _browser_baked; then
            log "Browser image detected (chromium + chrome-devtools-mcp present): auto-registering chrome-devtools MCP"
            _register_chrome_devtools_mcp
        fi
        ;;
esac
