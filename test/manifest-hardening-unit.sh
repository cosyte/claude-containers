#!/usr/bin/env bash
# manifest-hardening-unit.sh: pure-static + function-level tests for the
# reproducible-manifest + install-script hardening. NO docker, NO network, NO build.
#
# The manifest hardening bakes two supply-chain hardenings for AGENT-initiated installs: `ignore-scripts=true`
# in the claude user's ~/.npmrc and mise `lockfile=true` in the global mise config, plus an
# advisory `claude-deps-check` linter that flags unpinned/`latest` manifest specs. The LIVE
# proof (a pinned mise.lock reinstalls identical versions offline from the shared cache with
# zero registry calls; a postinstall-script fixture does NOT execute under ignore-scripts)
# needs a real image build and is the on-host gate. Here we prove the WIRING is present and
# correctly scoped:
#   - the hardening is baked into the USER config, NOT the root/global build config (so the
#     pinned build-time `npm install -g` layers are untouched)
#   - claude-deps-check flags the right specs, is advisory by default / refuses under --strict,
#     and is fail-safe on missing/malformed manifests
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERFILE="$REPO_ROOT/Dockerfile"
DEPS_CHECK="$REPO_ROOT/bin/claude-deps-check"

# Source claude-deps-check via its self-test seam (defines is_unpinned + pulls in _common.sh
# ONCE) so the function-level tests can call it directly; the integration cases run the real
# binary as a subprocess (its own process, no double-source of _common.sh).
# shellcheck disable=SC1090
CLAUDE_DEPS_CHECK_SELFTEST=1 source "$DEPS_CHECK"
set +e

PASS=0 FAIL=0
okp()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
badp() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT

echo "reproducible manifest + install-script hardening"

# ============================================================================
echo "== Dockerfile: ignore-scripts + lockfile baked into the USER config (build untouched) =="
# ============================================================================
# ignore-scripts=true goes into the claude user's ~/.npmrc, so an AGENT install is hardened,
# but the root build-time `npm install -g` layers (which run as root, before this) are NOT.
grep -Eq "printf 'ignore-scripts=true\\\\n' > /home/\\\$\{CLAUDE_USER\}/\.npmrc" "$DOCKERFILE" \
  && okp "ignore-scripts=true is written to the claude user's ~/.npmrc (agent installs hardened)" \
  || badp "ignore-scripts=true not baked into /home/\${CLAUDE_USER}/.npmrc"

# It must NOT be in the ROOT/global npm config, that would break the build-time global installs
# (claude-code, pnpm, chrome-devtools-mcp) which legitimately run as root.
if grep -Eq 'ignore-scripts=true' <<<"$(grep -E '/usr/local/etc/npmrc|/root/\.npmrc|npm config set ignore-scripts' "$DOCKERFILE")"; then
  badp "ignore-scripts appears in a ROOT/global npm config: would break build-time global installs"
else
  okp "ignore-scripts is NOT in the root/global npm config (build-time installs unaffected)"
fi

# mise lockfile=true in the global mise config (offline determinism for a committed mise.lock)
grep -Eq 'lockfile = true' "$DOCKERFILE" \
  && grep -Eq '/home/\$\{CLAUDE_USER\}/\.config/mise/config\.toml' "$DOCKERFILE" \
  && okp "mise lockfile=true is baked into the global mise config (~/.config/mise/config.toml)" \
  || badp "mise lockfile=true / the global mise config path is missing"

# both baked configs are chowned to the claude user (not left root-owned)
grep -Eq 'chown -R \$\{CLAUDE_UID\}:\$\{CLAUDE_GID\} /home/\$\{CLAUDE_USER\}/\.npmrc /home/\$\{CLAUDE_USER\}/\.config' "$DOCKERFILE" \
  && okp "~/.npmrc + ~/.config are chowned to the claude user" \
  || badp "the baked ~/.npmrc / ~/.config are not chowned to the claude user"

# claude-deps-check is installed on PATH + made executable (the chmod list is a single
# multi-line RUN, so both the COPY and the chmod entry appear as their own lines).
{ grep -Eq 'COPY bin/claude-deps-check /usr/local/bin/claude-deps-check' "$DOCKERFILE" \
    && grep -Eq '^\s*/usr/local/bin/claude-deps-check ' "$DOCKERFILE"; } \
  && okp "claude-deps-check is COPYed onto PATH and chmod +x" \
  || badp "claude-deps-check is not installed + made executable in the image"

# The /workspace-only mise config trust must NOT be widened by it.
grep -Eq '^\s*MISE_TRUSTED_CONFIG_PATHS=/workspace(\s|\\|$)' "$DOCKERFILE" \
  && okp "MISE_TRUSTED_CONFIG_PATHS is still /workspace-only (the hardening did not widen config trust)" \
  || badp "MISE_TRUSTED_CONFIG_PATHS is no longer exactly /workspace"

# ============================================================================
echo "== is_unpinned: the pin/range classifier =="
# ============================================================================
STRICT=0
for spec in latest lts stable "*" x "" "1.x" "1.X" ">=1.0.0" "1 - 2" "1.2.*" "npm:lodash@latest" "foo@x"; do
  if is_unpinned "$spec"; then okp "unpinned (default): '$spec'"; else badp "'$spec' should be unpinned (default)"; fi
done
# Exact pins: including PRERELEASE pins (hyphen with NO surrounding spaces): these are
# reproducible and must NOT be flagged (the gate-refuter's MAJOR, a range glob was
# swallowing prerelease pins, wrongly refusing them under --strict).
for spec in "1.2.3" "22" "20.10" "3.12.1" "1.2.3-alpha.1" "2.0.0-rc.0" "1.0.0-0" "1.2.3-beta" "npm:lodash@4.17.21" "1.2.3-alpha.x" "1.2.3+build.X"; do
  if is_unpinned "$spec"; then badp "'$spec' should be PINNED (default)"; else okp "pinned (default): '$spec'"; fi
done
# but a REAL trailing-wildcard range (no prerelease/build metadata) is still unpinned
STRICT=1
for spec in "1.x" "1.2.X" "1.2.*"; do
  if is_unpinned "$spec"; then okp "unpinned range: '$spec'"; else badp "'$spec' should be unpinned (trailing wildcard)"; fi
done
STRICT=0
# caret/tilde are pinned WITH a lockfile → only unpinned under --strict
STRICT=0
{ is_unpinned "^1.2.3" || is_unpinned "~1.2.3"; } && badp "caret/tilde flagged in DEFAULT mode (should need --strict)" || okp "caret/tilde are NOT flagged in default mode"
STRICT=1
{ is_unpinned "^1.2.3" && is_unpinned "~1.2.3"; } && okp "caret/tilde ARE flagged under --strict" || badp "caret/tilde not flagged under --strict"
STRICT=0

# ============================================================================
echo "== claude-deps-check: advisory default, --strict refusal, fail-safe =="
# ============================================================================
run_dc() { bash "$DEPS_CHECK" "$@"; }   # real binary, own process

# all pinned → OK, exit 0
printf '[tools]\nnode = "22"\npython = "3.12.1"\n' > "$TMPD/mise.toml"
printf '{"dependencies":{"lodash":"4.17.21"},"devDependencies":{"vitest":"2.1.0"}}' > "$TMPD/package.json"
out="$(run_dc "$TMPD" 2>&1)"; rc=$?
{ [[ $rc -eq 0 ]] && grep -qi 'fully pinned' <<<"$out"; } \
  && okp "a fully-pinned mise.toml + package.json → OK, exit 0" \
  || badp "fully-pinned manifest not accepted (rc=$rc, out='$out')"

# unpinned → advisory: warns but exit 0
printf '[tools]\nnode = "latest"\npython = ["3.12","*"]\ngo = "1.23"\n' > "$TMPD/mise.toml"
printf '{"dependencies":{"lodash":"^4.17.21","left-pad":"*","exact":"1.0.0"}}' > "$TMPD/package.json"
out="$(run_dc "$TMPD" 2>&1)"; rc=$?
{ [[ $rc -eq 0 ]] && grep -q 'node = "latest"' <<<"$out" && grep -q 'left-pad = "\*"' <<<"$out"; } \
  && okp "unpinned specs are WARNED but advisory (exit 0) by default" \
  || badp "default mode did not warn-and-continue (rc=$rc, out='$out')"
# default must NOT flag the caret range
grep -q 'lodash' <<<"$out" && badp "default mode flagged a caret range (should need --strict)" \
  || okp "default mode leaves caret ranges alone (lockfile pins them)"

# --strict → refuse, exit 1, and now the caret is flagged
out="$(run_dc --strict "$TMPD" 2>&1)"; rc=$?
{ [[ $rc -eq 1 ]] && grep -qi 'refusing' <<<"$out" && grep -q 'lodash = "\^4.17.21"' <<<"$out"; } \
  && okp "--strict refuses (exit 1) and flags caret ranges" \
  || badp "--strict did not refuse / flag the caret (rc=$rc, out='$out')"

# regression (gate-refuter MAJOR): a manifest pinned to a PRERELEASE version must PASS
# --strict: the enforcing mode must not refuse a legitimately-pinned prerelease.
printf '[tools]\nnode = "22.1.0"\n' > "$TMPD/mise.toml"
printf '{"dependencies":{"pkg":"1.2.3-alpha.1","other":"2.0.0-rc.0"}}' > "$TMPD/package.json"
out="$(run_dc --strict "$TMPD" 2>&1)"; rc=$?
{ [[ $rc -eq 0 ]] && grep -qi 'fully pinned' <<<"$out"; } \
  && okp "--strict ACCEPTS exact prerelease pins (1.2.3-alpha.1 / 2.0.0-rc.0): no false refusal" \
  || badp "--strict wrongly refused a prerelease-pinned manifest (rc=$rc, out='$out')"

# fail-safe: no manifest → no-op exit 0
out="$(run_dc "$(mktemp -d)" 2>&1)"; rc=$?
{ [[ $rc -eq 0 ]] && grep -qi 'nothing to check' <<<"$out"; } \
  && okp "a dir with no manifest is a no-op (exit 0), never blocks a session" \
  || badp "missing manifest did not no-op cleanly (rc=$rc, out='$out')"

# fail-safe: malformed package.json → swallowed, exit 0 (not a crash)
printf 'not json {{' > "$TMPD/package.json"; printf '[tools]\nnode = "22"\n' > "$TMPD/mise.toml"
out="$(run_dc "$TMPD" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] \
  && okp "a malformed package.json is fail-soft (exit 0), never crashes the linter" \
  || badp "malformed package.json crashed the linter (rc=$rc, out='$out')"

# bareword (unquoted) mise version is handled
printf '[tools]\nnode = 22\n' > "$TMPD/mise.toml"; rm -f "$TMPD/package.json"
out="$(run_dc "$TMPD" 2>&1)"; rc=$?
{ [[ $rc -eq 0 ]] && grep -qi 'fully pinned' <<<"$out"; } \
  && okp "an unquoted mise version (node = 22) is read as pinned" \
  || badp "bareword mise version mishandled (rc=$rc, out='$out')"

# a --strict scan of a single unpinned file path refuses
printf '[tools]\nnode = "latest"\n' > "$TMPD/mise.toml"
out="$(run_dc --strict "$TMPD/mise.toml" 2>&1)"; rc=$?
{ [[ $rc -eq 1 ]] && grep -q 'node = "latest"' <<<"$out"; } \
  && okp "--strict on an explicit mise.toml path flags + refuses" \
  || badp "explicit-file --strict scan failed (rc=$rc, out='$out')"

echo
echo "manifest-hardening-unit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
