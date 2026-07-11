#!/usr/bin/env bash
# mise-unit.sh — pure-static tests for the PKG-2 baked `mise` toolchain provisioner.
# NO docker, NO network, NO image build — safe for CI / scripts/verify.sh.
#
# PKG-2 bakes mise into the image and wires it for the `claude` user. The live proof
# ("mise use node@22 / aqua:owner/tool succeed as UID 1000 with no sudo; an untrusted
# out-of-workspace mise.toml does not auto-apply") needs a full image build and is the
# on-host smoke gate (docs/toolchain-provisioning.md). Here we prove the security-
# relevant WIRING is present and correctly scoped — chiefly that the install is
# version-pinned AND SHA256-verified in-repo (no `curl | sh` of a remote script), that
# config trust is scoped to /workspace and NOT a blanket "/", and that non-interactive
# agent shells resolve tools via shims on PATH. A regression in any of these is a
# supply-chain or usability break, so it gates in CI rather than waiting for a build.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERFILE="$REPO_ROOT/Dockerfile"
PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

echo "PKG-2 baked mise toolchain provisioner"

# ---- install is version-PINNED and SHA256-VERIFIED IN-REPO (not `curl | sh`) -----------------------
MISE_ARG="$(grep -E '^ARG MISE_VERSION=' "$DOCKERFILE" | head -1 | cut -d= -f2-)"
if [[ "$MISE_ARG" =~ ^v[0-9]{4}\.[0-9]+\.[0-9]+$ ]]; then
  ok "MISE_VERSION is pinned to a real release ($MISE_ARG) — reproducible, not 'latest'"
else
  bad "MISE_VERSION is not a pinned vYYYY.M.P release (got '${MISE_ARG:-<unset>}') — build would drift"
fi

# the supply-chain-critical property: NO piping a remotely-served installer into a shell.
# Inspect EXECUTABLE lines only (strip `#` comments) — an explanatory comment may name mise.run.
NONCOMMENT="$(grep -vE '^\s*#' "$DOCKERFILE")"
if grep -Eq 'mise\.run|curl[^|]*\|[^|]*\bsh\b' <<<"$NONCOMMENT"; then
  bad "mise is installed via a piped remote script (mise.run / 'curl … | sh') — unverified supply chain"
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
  || bad "the mise download does not use 'curl -fsSL' — an HTTP error body could be installed"
grep -Eq 'github\.com/jdx/mise/releases/download' "$DOCKERFILE" \
  && ok "binary is downloaded from github.com releases (host already on the egress allowlist)" \
  || bad "mise binary is not fetched from github.com/jdx/mise/releases"
# the digest is actually CHECKED before install (sha256sum -c), not just declared
grep -Eq 'sha256sum -c' "$DOCKERFILE" \
  && ok "the downloaded binary's SHA256 is verified (sha256sum -c) before install" \
  || bad "no 'sha256sum -c' — the hardcoded digest is declared but never enforced"

# ---- non-interactive / agent shells resolve tools via the SHIMS dir on PATH ------------------------
# The Claude Code process + its `bash -c "…"` tool calls never source ~/.bashrc, so tool resolution
# for the AGENT depends entirely on the shims dir being baked onto PATH. PKG-3 relocated the mise
# data dir (and so the shims) into the shared /cache tree, so the baked PATH must point there.
if grep -Fq 'PATH=/cache/mise/shims:' "$DOCKERFILE" && grep -Fq ':${PATH}' "$DOCKERFILE"; then
  ok "mise shims dir (/cache/mise/shims) is PREPENDED to PATH preserving the existing PATH (non-interactive tool resolution)"
else
  bad "mise shims dir not prepended to PATH as '/cache/mise/shims:…:\${PATH}' — agent shells would not find mise tools"
fi

# ---- config trust is scoped to /workspace ONLY — the load-bearing supply-chain guard ---------------
grep -Eq '^\s*MISE_TRUSTED_CONFIG_PATHS=/workspace(\s|\\|$)' "$DOCKERFILE" \
  && ok "trusted_config_paths is set to /workspace (repo the agent works on auto-applies)" \
  || bad "MISE_TRUSTED_CONFIG_PATHS is not exactly /workspace"

# it must NOT be a blanket root/home trust — assert the dangerous values never appear
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
  || bad "trusted_config_paths includes a blanket / or ~ — would auto-trust configs anywhere the agent reaches"

# ---- interactive activation is APPENDED to the stock ~/.bashrc and interactive-guarded -------------
# Appending (>>) rather than overwriting preserves Debian's stock ~/.bashrc (aliases/history/prompt)
# for humans who SSH in to debug. The activation must be guarded so a non-interactive source is a no-op.
grep -Eq '>>\s*/home/\$\{CLAUDE_USER\}/\.bashrc' "$DOCKERFILE" \
  && ok "mise activation is APPENDED (>>) to ~/.bashrc, preserving the stock skeleton (no overwrite)" \
  || bad "~/.bashrc is not appended to with '>>' — a COPY/overwrite would drop the stock bashrc"
if grep -Fq 'COPY bashrc ' "$DOCKERFILE"; then
  bad "a 'COPY bashrc …' overwrite is still present — it would clobber the stock ~/.bashrc"
else
  ok "no 'COPY bashrc' overwrite line (the stock ~/.bashrc is not clobbered)"
fi
grep -Eq 'eval "\$\(mise activate bash\)"' "$DOCKERFILE" \
  && ok "the appended snippet runs 'eval \"\$(mise activate bash)\"' for interactive shells" \
  || bad "the appended bashrc snippet does not activate mise"
grep -Eq '\[\[ \$- == \*i\* \]\] \|\| return' "$DOCKERFILE" \
  && ok "the appended activation is interactive-guarded ([[ \$- == *i* ]] || return)" \
  || bad "the appended activation is not interactive-guarded — non-interactive source not a no-op"

# ---- ~/.bashrc is chowned to the claude user — robust (not a fixed -A3 window) ----------------------
grep -Eq 'chown[^\n]*/home/\$\{CLAUDE_USER\}/\.bashrc' "$DOCKERFILE" \
  && ok "~/.bashrc is chowned to the claude user" \
  || bad "no chown of ~/.bashrc to the claude user (would stay root-owned)"

echo
echo "mise-unit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
