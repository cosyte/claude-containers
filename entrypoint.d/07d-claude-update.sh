# shellcheck shell=bash
# --- 7d. Claude Code at npm's latest, at every start ------------------------------
# The image bakes CLAUDE_CODE_VERSION (the Dockerfile's pin, checked at build). Every start
# then brings the agent-owned prefix up to npm's latest @anthropic-ai/claude-code, before any
# session or §10's `claude mcp` runs, so a container starts on the newest Claude Code without
# a rebuild, and the auto-updater keeps it there while the sessions run. It is the install
# the auto-updater itself makes (`npm install -g` into the same prefix, as the agent user,
# install scripts off), so the launcher finishes it the same way: the native binary is linked
# on the CLI's first run, which here is the --version that verifies it.
#
# DISABLE_AUTOUPDATER=1, the lever that keeps a container on the baked version, skips it: in
# the container's environment, or in the env of an operator's own managed settings file.
# NEVER FATAL: offline, a registry error or a timeout is a WARNING and the sessions start on
# the version already installed. Whatever is installed, §7a's managed requiredMinimumVersion
# keeps a session from starting below that floor.
CC_PREFIX="/opt/claude-code"                                 # the agent-owned npm prefix
CC_LAUNCHER="/usr/local/bin/claude"                          # bin/claude-launcher
CC_MANAGED_FILE="/etc/claude-code/managed-settings.json"     # §7a's vendor path
CC_PKG="@anthropic-ai/claude-code"
CC_VIEW_TIMEOUT=60
CC_INSTALL_TIMEOUT=600
cc_version() {  # the version in the prefix, from its package.json; empty when there is none
    jq -r '.version // empty' "$CC_PREFIX/lib/node_modules/$CC_PKG/package.json" 2>/dev/null || true
}
cc_from="$(cc_version)"
cc_off="${DISABLE_AUTOUPDATER:-}"
[[ -n "$cc_off" ]] || cc_off="$(jq -r '.env.DISABLE_AUTOUPDATER // empty' "$CC_MANAGED_FILE" 2>/dev/null || true)"
cc_latest="" cc_now=""
if [[ "${cc_off,,}" =~ ^(1|true|yes|on)$ ]]; then
    log "Claude Code         : ${cc_from:-unknown}, kept (DISABLE_AUTOUPDATER=$cc_off: no update at start)"
elif ! cc_latest="$(asclaude timeout "$CC_VIEW_TIMEOUT" npm view "$CC_PKG@latest" version 2>/dev/null)" \
     || [[ ! "$cc_latest" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
    log "WARNING: Claude Code ${cc_from:-unknown} kept: npm's latest version could not be read (offline, or the registry did not answer in ${CC_VIEW_TIMEOUT}s)"
elif [[ "$cc_latest" == "$cc_from" ]]; then
    log "Claude Code         : $cc_from, npm's latest"
elif [[ -n "$cc_from" && "$(printf '%s\n%s\n' "$cc_latest" "$cc_from" | sort -V | tail -n 1)" == "$cc_from" ]]; then
    log "Claude Code         : $cc_from, newer than npm's latest ($cc_latest): kept"
else
    log "Claude Code         : updating ${cc_from:-no version} to npm's latest, $cc_latest"
    if asclaude timeout "$CC_INSTALL_TIMEOUT" npm install -g --prefix "$CC_PREFIX" --no-audit --no-fund \
           "$CC_PKG@$cc_latest" >/dev/null 2>&1; then
        cc_now="$(asclaude "$CC_LAUNCHER" --version 2>/dev/null | awk 'NR == 1 {print $1}')" || cc_now=""
        if [[ "$cc_now" == "$cc_latest" ]]; then
            log "Claude Code         : $cc_latest (updated from ${cc_from:-no version})"
        else
            log "WARNING: Claude Code $cc_latest was installed, but the CLI reports '${cc_now:-nothing}': a session may not start (docs/troubleshooting.md)"
        fi
    else
        cc_now="$(cc_version)"
        log "WARNING: the update to Claude Code $cc_latest failed or took over ${CC_INSTALL_TIMEOUT}s: the sessions start on ${cc_now:-whatever is left in $CC_PREFIX} (docs/troubleshooting.md)"
    fi
fi
unset cc_from cc_off cc_latest cc_now
unset -f cc_version
