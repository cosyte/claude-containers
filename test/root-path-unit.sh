#!/usr/bin/env bash
# root-path-unit.sh: root and the agent resolve commands through different PATHs.
# Static plus a sandboxed run of the entrypoint's own PATH block: no docker, no root.
#   - the image's PATH (what root, the HEALTHCHECK and a plain `docker exec` get) is system
#     directories only; the agent's PATH is CLAUDE_AGENT_PATH;
#   - the entrypoint sets root's PATH before it runs anything, and every drop to the agent
#     (asclaude, the direct gosu calls) hands over CLAUDE_AGENT_PATH;
#   - every script root runs pins the system PATH when it is root, with an absolute shebang;
#   - `claude` run as root is handed to the agent user before the CLI in its prefix runs.
# The live half (a root process and an agent window in the built image) is in test/smoke.sh.
# shellcheck source=test/lib/prelude.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/prelude.sh"
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

SYS=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# system_only <path>: every entry is a system directory, none the agent can write.
system_only() {
    local e
    IFS=: read -ra _es <<<"$1"
    (( ${#_es[@]} )) || return 1
    for e in "${_es[@]}"; do
        [[ ":$SYS:" == *":$e:"* ]] || return 1
    done
}
# Scripts the entrypoint (or Docker) runs as root. A new one belongs here.
ROOT_RUN=(claude-healthcheck claude-egress-firewall claude-gpu claude-kit claude-container-facts)

echo "== the image: root's PATH and the agent's =="
DF="$REPO_ROOT/Dockerfile"
# The image's final PATH: the last instruction that sets it (ENV PATH=..., or an ENV block line).
img_path="$(grep -E '^(ENV)? +PATH=' "$DF" | tail -n 1 | sed -E 's/^(ENV)? +PATH=//; s/ *\\$//')"
system_only "$img_path" \
    && ok "the image's PATH is system directories only ($img_path)" \
    || bad "the image's PATH must be system directories only, root and the HEALTHCHECK run with it (got '$img_path')"
agent_path="$(grep -E '^ +CLAUDE_AGENT_PATH=' "$DF" | head -n 1 | sed -E 's/^ +CLAUDE_AGENT_PATH=//; s/ *\\$//')"
[[ "$agent_path" == /state/mise-shims:*':${PATH}:/opt/claude-code/bin:/home/${CLAUDE_USER}/.local/bin' && "$agent_path" == *:/cache/cargo/bin:* ]] \
    && ok "CLAUDE_AGENT_PATH keeps the agent's PATH: the shims views, cargo/go bin, the system dirs, /opt/claude-code/bin, ~/.local/bin" \
    || bad "CLAUDE_AGENT_PATH is not the agent's full PATH (got '$agent_path')"

echo "== the entrypoint sets root's PATH first, and hands the agent its own =="
EP="$REPO_ROOT/entrypoint.sh"
[[ "$(head -n 1 "$EP")" == '#!/bin/bash' ]] && ok "entrypoint.sh: #!/bin/bash" || bad "entrypoint.sh must start #!/bin/bash"
ep_root="$(sed -n 's/^ROOT_PATH=//p' "$EP")"
system_only "$ep_root" && ok "ROOT_PATH is system directories only" || bad "ROOT_PATH is not system-only (got '$ep_root')"
first_cmd="$(grep -nE '\$\((getent|id) ' "$EP" | head -n 1 | cut -d: -f1)"
export_at="$(grep -nE '^export PATH="\$ROOT_PATH"( |$)' "$EP" | head -n 1 | cut -d: -f1)"
[[ -n "$export_at" && -n "$first_cmd" ]] && (( export_at < first_cmd )) \
    && ok "root's PATH is exported before the entrypoint runs its first command" \
    || bad "export PATH=\"\$ROOT_PATH\" must come before the first command (getent/id) in entrypoint.sh"
grep -qE '^asclaude\(\) \{ gosu "\$CLAUDE_USER" env PATH="\$CLAUDE_AGENT_PATH" ' "$EP" \
    && ok "asclaude hands the agent CLAUDE_AGENT_PATH" || bad "asclaude must pass PATH=\"\$CLAUDE_AGENT_PATH\" to the agent"
missing="$(cat "$EP" "$REPO_ROOT"/entrypoint.d/*.sh | grep -E 'gosu "\$CLAUDE_USER" env ' | grep -vF 'env PATH="$CLAUDE_AGENT_PATH"' || true)"
[[ -z "$missing" ]] && ok "every direct gosu to the agent with env hands over CLAUDE_AGENT_PATH" \
    || bad "a gosu to the agent without PATH=\"\$CLAUDE_AGENT_PATH\": $missing"

# Run the entrypoint's own PATH block and asclaude in a sandbox: a PATH full of other
# directories comes in, the system PATH is what root has after it, and the agent gets
# CLAUDE_AGENT_PATH. gosu is a function here (no root needed): it drops its user argument.
block="$(sed -n '/^set -euo pipefail$/,/^CLAUDE_USER=/p' "$EP" | sed '$d')"
asdef="$(grep -E '^asclaude\(\) \{' "$EP")"
out="$(PATH="/tmp/agent-bin:$PATH" CLAUDE_AGENT_PATH="/tmp/agent-bin:$SYS" bash -c "
    $block
    gosu() { shift; \"\$@\"; }
    CLAUDE_USER=claude CLAUDE_CONFIG_DIR=/c CLAUDE_HOME=/h
    $asdef
    echo \"root=\$PATH\"
    asclaude sh -c 'echo \"agent=\$PATH\"'
" 2>&1)"
grep -qxF "root=$SYS" <<<"$out" && ok "after the block root's PATH is the system PATH, whatever came in" \
    || bad "root's PATH after the entrypoint block: $out"
grep -qxF "agent=/tmp/agent-bin:$SYS" <<<"$out" && ok "a process started through asclaude gets CLAUDE_AGENT_PATH" \
    || bad "the agent's PATH through asclaude: $out"
out="$(env -u CLAUDE_AGENT_PATH PATH="/tmp/agent-bin:$PATH" bash -c "
    $block
    echo \"agent=\$CLAUDE_AGENT_PATH\"
" 2>&1)"
grep -qxF "agent=$SYS" <<<"$out" && ok "with no CLAUDE_AGENT_PATH the agent falls back to the system PATH" \
    || bad "fallback when CLAUDE_AGENT_PATH is unset: $out"
grep -qE '^ *if ! asclaude env .*CLAUDE_FACTS_' "$REPO_ROOT/entrypoint.d/07c-session-memory.sh" \
    && ok "the container-facts probe runs as the agent (it resolves toolchains the agent installs)" \
    || bad "§7c must run claude-container-facts through asclaude"

echo "== the scripts root runs pin the system PATH =="
for s in "${ROOT_RUN[@]}"; do
    f="$REPO_ROOT/bin/$s"
    [[ "$(head -n 1 "$f")" == '#!/bin/bash' ]] && ok "$s: #!/bin/bash" || bad "$s must start #!/bin/bash (root runs it)"
    pin="$(grep -E '^if \(\( EUID == 0 \)\); then export PATH=[^;]+; fi$' "$f" | head -n 1 | sed -E 's/.*export PATH=([^;]+);.*/\1/')"
    system_only "$pin" && ok "$s pins the system PATH when root" || bad "$s does not pin a system-only PATH when root (got '${pin:-none}')"
    # The pin precedes the first external command: only comments, `set`, and blank lines before it.
    pre="$(sed -n '2,/^if (( EUID == 0 )); then export PATH=/p' "$f" | sed '$d' | grep -vE '^\s*(#|$|set )' || true)"
    [[ -z "$pre" ]] && ok "$s: nothing runs before the pin" || bad "$s runs something before its PATH pin: $pre"
done
grep -qE '^PGREP="\$\{CLAUDE_HEALTHCHECK_PGREP:-pgrep\}"$' "$REPO_ROOT/bin/claude-healthcheck" \
    && ! grep -qE '^pgrep ' "$REPO_ROOT/bin/claude-healthcheck" \
    && ok "the healthcheck's liveness probe goes through \$PGREP (a stub only its caller can set)" \
    || bad "the healthcheck must call its process finder through \$PGREP"

echo "== claude as root is handed to the agent =="
L="$REPO_ROOT/bin/claude-launcher"
drop_at="$(grep -nE '^    exec gosu "\$\{CLAUDE_USER:-claude\}" env PATH="\$\{CLAUDE_AGENT_PATH:-\$PATH\}" "\$0" "\$@"$' "$L" | cut -d: -f1)"
run_at="$(grep -nF 'exec "$PREFIX/bin/claude" "$@"' "$L" | cut -d: -f1)"
fix_at="$(grep -nF 'node install.cjs' "$L" | head -n 1 | cut -d: -f1)"
[[ -n "$drop_at" && -n "$run_at" && -n "$fix_at" ]] && (( drop_at < fix_at && drop_at < run_at )) \
    && grep -qE '^if \(\( EUID == 0 \)\); then$' "$L" \
    && ok "the launcher re-runs itself as the agent before it repairs or runs the CLI in the agent's prefix" \
    || bad "the launcher must hand a root caller to the agent before touching /opt/claude-code"

echo
echo "== $PASS passed, $FAIL failed =="
exit $(( FAIL > 0 ? 1 : 0 ))
