# shellcheck shell=bash
# --- 7b. Browser decision (§10b acts on it) ----------------------------------
# Made here, before the session memory (§7c), so the facts can say whether this session
# has the chrome-devtools MCP and §8e can install the frontend-debugging skill only when
# it does. CLAUDE_BROWSER is TRI-STATE (the whole contract is at §10b):
#   unset / empty / other -> auto (on iff the browser variant is baked),
#   1|true|yes|on -> on (fails loud in §10b when nothing is baked), 0|false|no|off -> off.
# Normalize: strip surrounding whitespace / a trailing CR (a CRLF-authored .env
# yields `1\r`, which must still match "1", not silently fall through to auto)
# and lowercase, so the tri-state match is robust to how the value was set.
_browser_baked() {
    command -v chrome-devtools-mcp >/dev/null 2>&1 && command -v chromium >/dev/null 2>&1
}
_cb="$(printf '%s' "${CLAUDE_BROWSER:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
BROWSER_MCP=off
# shellcheck disable=SC2034  # read by §7c, §8e and §10b
case "$_cb" in
    0|false|no|off) ;;
    *) if _browser_baked; then BROWSER_MCP=on; fi ;;
esac
