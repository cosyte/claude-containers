#!/usr/bin/env bash
# shellcheck disable=SC2088  # "~" here is message text or a literal pattern, not a path
# mise-unit.sh: pure-static tests for the baked `mise` toolchain provisioner.
# NO docker, NO network, NO image build: safe for CI / scripts/verify.sh.
#
# The provisioner bakes mise into the image and wires it for the `claude` user. The live proof
# ("mise use node@22 / aqua:owner/tool succeed as UID 1000 with no sudo; an untrusted
# out-of-workspace mise.toml does not auto-apply") needs a full image build and is the
# on-host smoke gate (docs/toolchain-provisioning.md). Here we prove the security-
# relevant WIRING is present and correctly scoped: chiefly that the install is
# version-pinned AND SHA256-verified in-repo (no `curl | sh` of a remote script), that
# config trust is scoped to /workspace and NOT a blanket "/", and that non-interactive
# agent shells resolve tools via shims on PATH. A regression in any of these is a
# supply-chain or usability break, so it gates in CI rather than waiting for a build.
# shellcheck source=test/lib/prelude.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/prelude.sh"
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERFILE="$REPO_ROOT/Dockerfile"
PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

echo "baked mise toolchain provisioner"

# ---- install is version-PINNED and SHA256-VERIFIED IN-REPO (not `curl | sh`) -----------------------
MISE_ARG="$(grep -E '^ARG MISE_VERSION=' "$DOCKERFILE" | head -1 | cut -d= -f2-)"
if [[ "$MISE_ARG" =~ ^v[0-9]{4}\.[0-9]+\.[0-9]+$ ]]; then
  ok "MISE_VERSION is pinned to a real release ($MISE_ARG): reproducible, not 'latest'"
else
  bad "MISE_VERSION is not a pinned vYYYY.M.P release (got '${MISE_ARG:-<unset>}'), build would drift"
fi

# the supply-chain-critical property: NO piping a remotely-served installer into a shell.
# Inspect EXECUTABLE lines only (strip `#` comments): an explanatory comment may name mise.run.
NONCOMMENT="$(grep -vE '^\s*#' "$DOCKERFILE")"
if grep -Eq 'mise\.run|curl[^|]*\|[^|]*\bsh\b' <<<"$NONCOMMENT"; then
  bad "mise is installed via a piped remote script (mise.run / 'curl … | sh'): unverified supply chain"
else
  ok "no 'curl … | sh' / mise.run remote-installer pipe (install is a verified binary download)"
fi

# both arch digests are pinned as ARGs, and the release binary is fetched from GitHub with -fsSL
grep -Eq '^ARG MISE_SHA256_AMD64=[0-9a-f]{64}$' "$DOCKERFILE" \
  && grep -Eq '^ARG MISE_SHA256_ARM64=[0-9a-f]{64}$' "$DOCKERFILE" \
  && ok "both arch SHA256 digests are hardcoded as 64-hex ARGs (amd64 + arm64)" \
  || bad "a hardcoded MISE_SHA256_AMD64/ARM64 64-hex digest is missing"
grep -Eq 'curl -fsSL' "$DOCKERFILE" \
  && ok "the release binary is fetched with 'curl -fsSL' (fail-on-error, follow-redirect, matches repo convention)" \
  || bad "the mise download does not use 'curl -fsSL': an HTTP error body could be installed"
grep -Eq 'github\.com/jdx/mise/releases/download' "$DOCKERFILE" \
  && ok "binary is downloaded from github.com releases (host already on the egress allowlist)" \
  || bad "mise binary is not fetched from github.com/jdx/mise/releases"
# the digest is actually CHECKED before install (sha256sum -c), not just declared
grep -Eq 'sha256sum -c' "$DOCKERFILE" \
  && ok "the downloaded binary's SHA256 is verified (sha256sum -c) before install" \
  || bad "no 'sha256sum -c': the hardcoded digest is declared but never enforced"

# ---- non-interactive / agent shells resolve tools via THIS container's view of the shims ----------
# The Claude Code process + its `bash -c "…"` tool calls never source ~/.bashrc, so tool resolution
# for the AGENT depends entirely on PATH. The shared /cache/mise/shims holds a shim for every tool
# any container installed, so PATH leads with the per-container view claude-mise-shims builds, then
# the system dirs, and leaves the shared dir off: a tool with no version reads "command not found".
# The agent's PATH is CLAUDE_AGENT_PATH (root's own PATH is system dirs only: root-path-unit.sh).
ENV_PATH="$(grep -E '^ +CLAUDE_AGENT_PATH=' "$DOCKERFILE" | head -1 | sed -E 's/^ +CLAUDE_AGENT_PATH=//; s/ *\\$//')"
IFS=: read -ra PE <<<"$ENV_PATH"
sys_i=-1
for i in "${!PE[@]}"; do [[ "${PE[$i]}" == '${PATH}' ]] && sys_i=$i; done
if [[ "${PE[0]:-}" == /state/mise-shims && "${PE[1]:-}" == '/home/${CLAUDE_USER}/.local/share/claude-mise-shims' ]] \
    && (( sys_i > 1 )); then
  ok "PATH leads with the per-container shims view (/state/mise-shims, then the no-state fallback), then the system dirs"
else
  bad "PATH must start /state/mise-shims:/home/\${CLAUDE_USER}/.local/share/claude-mise-shims:… before \${PATH} (got $ENV_PATH)"
fi
if [[ ":$ENV_PATH:" == *:/cache/mise/shims:* ]]; then
  bad "the shared /cache/mise/shims is on PATH: a versionless tool's shim would pass command -v"
else
  ok "the shared /cache/mise/shims is not on PATH (a versionless tool reads 'command not found')"
fi
grep -Fq 'COPY bin/claude-mise-shims /usr/local/bin/claude-mise-shims' "$DOCKERFILE" \
  && ok "claude-mise-shims is baked into the image" || bad "claude-mise-shims is not COPYed into the image"
grep -Eq 'asclaude .*"\$MISE_SHIMS_CMD"' "$REPO_ROOT/entrypoint.d/09b-mise-shims.sh" \
  && grep -Fq 'MISE_SHIMS_CMD=/usr/local/bin/claude-mise-shims' "$REPO_ROOT/entrypoint.d/09b-mise-shims.sh" \
  && ok "the entrypoint rebuilds the view at every start, as the claude user" \
  || bad "the entrypoint does not run claude-mise-shims as the claude user"

# ---- config trust is scoped to /workspace ONLY: the load-bearing supply-chain guard ---------------
grep -Eq '^\s*MISE_TRUSTED_CONFIG_PATHS=/workspace(\s|\\|$)' "$DOCKERFILE" \
  && ok "trusted_config_paths is set to /workspace (repo the agent works on auto-applies)" \
  || bad "MISE_TRUSTED_CONFIG_PATHS is not exactly /workspace"

# it must NOT be a blanket root/home trust: assert the dangerous values never appear
TRUST_VALS="$(grep -Eo 'MISE_TRUSTED_CONFIG_PATHS=[^ \\]+' "$DOCKERFILE" | cut -d= -f2- | tr ':' '\n')"
BLANKET=0
while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  case "$p" in
    /|"~"|'~/'|/home|/home/|'${HOME}'|'$HOME') BLANKET=1 ;;
  esac
done <<<"$TRUST_VALS"
[[ "$BLANKET" -eq 0 ]] \
  && ok "trusted_config_paths is NOT a blanket / or ~ (untrusted configs outside /workspace stay refused)" \
  || bad "trusted_config_paths includes a blanket / or ~: would auto-trust configs anywhere the agent reaches"

# ---- interactive activation is APPENDED to the stock ~/.bashrc and interactive-guarded -------------
# Appending (>>) rather than overwriting preserves Debian's stock ~/.bashrc (aliases/history/prompt)
# for humans who SSH in to debug. The activation must be guarded so a non-interactive source is a no-op.
grep -Eq '>>\s*/home/\$\{CLAUDE_USER\}/\.bashrc' "$DOCKERFILE" \
  && ok "mise activation is APPENDED (>>) to ~/.bashrc, preserving the stock skeleton (no overwrite)" \
  || bad "~/.bashrc is not appended to with '>>': a COPY/overwrite would drop the stock bashrc"
if grep -Fq 'COPY bashrc ' "$DOCKERFILE"; then
  bad "a 'COPY bashrc …' overwrite is still present: it would clobber the stock ~/.bashrc"
else
  ok "no 'COPY bashrc' overwrite line (the stock ~/.bashrc is not clobbered)"
fi
grep -Eq 'eval "\$\(mise activate bash\)"' "$DOCKERFILE" \
  && ok "the appended snippet runs 'eval \"\$(mise activate bash)\"' for interactive shells" \
  || bad "the appended bashrc snippet does not activate mise"
grep -Eq '\[\[ \$- == \*i\* \]\] \|\| return' "$DOCKERFILE" \
  && ok "the appended activation is interactive-guarded ([[ \$- == *i* ]] || return)" \
  || bad "the appended activation is not interactive-guarded: non-interactive source not a no-op"

# ---- ~/.bashrc is chowned to the claude user: robust (not a fixed -A3 window) ----------------------
grep -Eq 'chown[^\n]*/home/\$\{CLAUDE_USER\}/\.bashrc' "$DOCKERFILE" \
  && ok "~/.bashrc is chowned to the claude user" \
  || bad "no chown of ~/.bashrc to the claude user (would stay root-owned)"

# ---- claude-mise-shims against a fake mise ------------------------------------------------------
echo
echo "claude-mise-shims (fake mise)"
SHIMS="$REPO_ROOT/bin/claude-mise-shims"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home" "$T/ws/repo" "$T/data/shims" "$T/inst/node/bin" "$T/inst/sc"
# The fake answers `mise bin-paths` from the dir it is asked in: $PWD/.fake-bins, one dir per line;
# and `mise ls --missing --json` from $PWD/.fake-missing, but only offline (MISE_OFFLINE=1): the
# view must never make mise ask a registry at boot.
cat > "$T/bin/mise" <<'FAKE'
#!/bin/sh
case "$1" in
    bin-paths) [ -f .fake-bins ] && cat .fake-bins; exit 0 ;;
    ls) [ "$2 $3" = "--missing --json" ] || exit 1
        [ "${MISE_OFFLINE:-}" = 1 ] || { echo "fake mise: ls without MISE_OFFLINE=1" >&2; exit 3; }
        if [ -f .fake-missing ]; then cat .fake-missing; else echo '{}'; fi; exit 0 ;;
esac
exit 1
FAKE
chmod +x "$T/bin/mise"
for t in node pytest shellcheck; do ln -s "$T/bin/mise" "$T/data/shims/$t"; done
for x in "$T/inst/node/bin/node" "$T/inst/sc/shellcheck"; do printf '#!/bin/sh\necho real\n' > "$x"; chmod +x "$x"; done
echo "$T/inst/node/bin" > "$T/home/.fake-bins"
: > "$T/ws/repo/mise.toml"
run_shims() {
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" MISE_DATA_DIR="$T/data" \
      CLAUDE_MISE_WORKSPACE="$T/ws" "$@" "$SHIMS"
}
shared_state() { (cd "$T/data/shims" && find . -printf '%p %y %l %T@\n' | sort); }
BEFORE="$(shared_state)"
out="$(run_shims CLAUDE_STATE_DIR="$T/state")"
V="$T/state/mise-shims"
[[ "$(readlink "$V/node" 2>/dev/null)" == "$T/data/shims/node" ]] \
  && ok "a tool with a version (node, global config) is linked to its shared shim" \
  || bad "node was not linked into $V (out: $out)"
[[ ! -e "$V/pytest" && ! -L "$V/pytest" ]] \
  && ok "a versionless tool (pytest) is not linked" || bad "pytest was linked although no config sets a version"
[[ "$out" == "claude-mise-shims: 1 of 3 shared shims linked into $V" ]] \
  && ok "it logs the count linked" || bad "unexpected summary: $out"
# a fake `mise use` in a workspace repo: the rerun links the new tool
echo "$T/inst/sc" > "$T/ws/repo/.fake-bins"
run_shims CLAUDE_STATE_DIR="$T/state" >/dev/null
[[ -L "$V/shellcheck" && -L "$V/node" ]] \
  && ok "a rerun after a 'mise use' in a /workspace repo links the new tool" \
  || bad "the rerun did not link shellcheck from the workspace config"
# a tool whose version went away is unlinked
: > "$T/home/.fake-bins"
run_shims CLAUDE_STATE_DIR="$T/state" >/dev/null
[[ ! -e "$V/node" && ! -L "$V/node" && -L "$V/shellcheck" ]] \
  && ok "a rerun unlinks a tool that no longer has a version" || bad "node stayed linked after its version went away"
[[ "$(shared_state)" == "$BEFORE" ]] \
  && ok "the shared shims dir's file list and mtimes are unchanged after the runs" \
  || bad "the shared shims dir changed: $(diff <(echo "$BEFORE") <(shared_state))"
# with a PATH of view, then system dirs (and no shared dir), the versionless tool is not found
PATH="$V:/usr/bin:/bin" command -v shellcheck >/dev/null \
  && ! PATH="$V:/usr/bin:/bin" command -v pytest >/dev/null 2>&1 \
  && ok "on that PATH a linked tool is found and a versionless one reads 'command not found'" \
  || bad "PATH resolution through the view is wrong"
# without CLAUDE_STATE_DIR the view falls back under HOME
run_shims >/dev/null
[[ -L "$T/home/.local/share/claude-mise-shims/shellcheck" ]] \
  && ok "without CLAUDE_STATE_DIR the view is ~/.local/share/claude-mise-shims" \
  || bad "no fallback view under HOME"

# A version a config pins that /cache does not hold yet (a repo's node 20 while only node 22 is
# installed) is linked by the commands its installed sibling provides, so the shared shim installs
# and runs 20 on first use instead of the command falling through to the image's own node.
mkdir -p "$T/data/installs/node/22.1.0/bin" "$T/ws/web"
for b in node npm; do
  printf '#!/bin/sh\necho v22\n' > "$T/data/installs/node/22.1.0/bin/$b"; chmod +x "$T/data/installs/node/22.1.0/bin/$b"
done
ln -s 22.1.0 "$T/data/installs/node/22"   # mise's alias link: not a version of its own
ln -s "$T/bin/mise" "$T/data/shims/npm"
: > "$T/ws/web/mise.toml"
cat > "$T/ws/web/.fake-missing" <<EOF
{"node":[{"version":"20","requested_version":"20","install_path":"$T/data/installs/node/20","installed":false}],
 "jq":[{"version":"1.7","requested_version":"1.7","install_path":"$T/data/installs/jq/1.7","installed":false}]}
EOF
BEFORE="$(shared_state)"
out="$(run_shims CLAUDE_STATE_DIR="$T/state2")"
V2="$T/state2/mise-shims"
[[ "$(readlink "$V2/node" 2>/dev/null)" == "$T/data/shims/node" && -L "$V2/npm" ]] \
  && ok "a pinned but not installed version (node@20) links the shims its installed sibling provides (node, npm), asked offline" \
  || bad "node@20 (missing) did not link node and npm into $V2 (out: $out)"
[[ ! -e "$V2/pytest" && ! -L "$V2/pytest" ]] \
  && ok "a versionless tool (pytest) is still not linked" || bad "pytest was linked although no config names it"
[[ "$out" == *"; not installed yet, installs on first use: node@20"* ]] \
  && ok "the summary names the version that installs on first use" || bad "summary does not name node@20: $out"
[[ "$out" == *"; not installed and no version in /cache (run mise install): jq@1.7"* && ! -e "$V2/jq" ]] \
  && ok "a missing tool with no version anywhere in /cache is named for a mise install, nothing linked" \
  || bad "summary does not name jq@1.7 as needing a mise install: $out"
[[ "$(shared_state)" == "$BEFORE" ]] \
  && ok "the shared dir is still unchanged" || bad "the shared shims dir changed: $(diff <(echo "$BEFORE") <(shared_state))"

echo
echo "mise-unit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
