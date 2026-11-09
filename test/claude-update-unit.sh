#!/usr/bin/env bash
# Unit tests for entrypoint.sh §7d, Claude Code at npm's latest at every start: NO docker, NO
# network, NO root. The block is extracted from its file and run for real, under the entrypoint's
# shell options, against a sandboxed prefix, a fake `npm` on PATH and a fake launcher:
#   - npm's latest newer than the installed version: one `npm install -g` of exactly that
#     version into the prefix, under a timeout, then the launcher run to finish and verify it
#   - already the latest, or newer: no install; DISABLE_AUTOUPDATER=1: no npm call at all
#   - offline, a registry answer that is not a version, a failed install, or a CLI that then
#     reports another version: a WARNING, and the boot goes on (never fatal)
#   - the section runs after §7a and before §10, the first boot step that runs the CLI
# shellcheck source=test/lib/prelude.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/prelude.sh"
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/lib/entrypoint.sh
source "$REPO_ROOT/test/lib/entrypoint.sh"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

PKGJSON="lib/node_modules/@anthropic-ai/claude-code/package.json"

# The fake npm: logs each call, answers `view` with FAKE_LATEST (FAKE_VIEW_FAIL=1: exit 1, as
# offline), and on `install` writes the package.json of the version asked for into --prefix
# (FAKE_INSTALL_FAIL=1: exit 1 and write nothing).
FAKE="$TMPD/fake"; mkdir -p "$FAKE"; CALLS="$TMPD/calls"
cat > "$FAKE/npm" <<'EOF'
#!/usr/bin/env bash
echo "npm $*" >> "$FAKE_CALLS"
case "$1" in
    view)
        [[ "${FAKE_VIEW_FAIL:-0}" == 1 ]] && exit 1
        printf '%s\n' "$FAKE_LATEST" ;;
    install)
        [[ "${FAKE_INSTALL_FAIL:-0}" == 1 ]] && exit 1
        prefix="" spec=""
        args=("$@")
        for ((i=0; i<${#args[@]}; i++)); do
            [[ "${args[i]}" == --prefix ]] && prefix="${args[i+1]}"
            [[ "${args[i]}" == @anthropic-ai/claude-code@* ]] && spec="${args[i]}"
        done
        mkdir -p "$prefix/lib/node_modules/@anthropic-ai/claude-code"
        printf '{"name":"@anthropic-ai/claude-code","version":"%s"}\n' "${spec##*@}" \
            > "$prefix/lib/node_modules/@anthropic-ai/claude-code/package.json" ;;
    *) exit 2 ;;
esac
EOF
chmod +x "$FAKE/npm"
# The fake launcher: what bin/claude-launcher prints for --version once the native binary is
# linked, read from the prefix's package.json (FAKE_LAUNCHER_SAYS overrides it).
cat > "$FAKE/claude" <<'EOF'
#!/usr/bin/env bash
echo "launcher $*" >> "$FAKE_CALLS"
v="${FAKE_LAUNCHER_SAYS:-$(jq -r .version "$FAKE_PREFIX/lib/node_modules/@anthropic-ai/claude-code/package.json" 2>/dev/null)}"
echo "$v (Claude Code)"
EOF
chmod +x "$FAKE/claude"

BLOCK7D="$(awk '/^# --- 7d\. Claude Code at npm/{f=1} f{print}' "$(ep_section 7d)")"
block() {  # the block with its three root paths pointed into sandbox $1
    sed -e "s#^CC_PREFIX=.*#CC_PREFIX=\"$1/prefix\"#" \
        -e "s#^CC_LAUNCHER=.*#CC_LAUNCHER=\"$FAKE/claude\"#" \
        -e "s#^CC_MANAGED_FILE=.*#CC_MANAGED_FILE=\"$1/managed-settings.json\"#" <<<"$BLOCK7D"
}
probe="$(block "$TMPD/probe")"
if [[ -n "$BLOCK7D" ]] && grep -qF "CC_PREFIX=\"$TMPD/probe/prefix\"" <<<"$probe" \
   && grep -qF "CC_LAUNCHER=\"$FAKE/claude\"" <<<"$probe" \
   && grep -qF "CC_MANAGED_FILE=\"$TMPD/probe/managed-settings.json\"" <<<"$probe" \
   && ! grep -qE '/opt/claude-code|/usr/local/bin/claude|/etc/claude-code' <<<"$(grep -v '^[[:space:]]*#' <<<"$probe")"; then
    ok "§7d extracted, its prefix, launcher and managed file redirected into a sandbox"
else
    bad "§7d did not extract, or its paths did not redirect: these cases would touch /opt/claude-code or /etc"
fi

# r7 <installed version or ""> [VAR=VAL ...]: the block under set -euo pipefail in a fresh
# sandbox $SB, its prefix holding <installed>. $out is the boot log, then block_continued=1
# only if the block ran to its end (the evidence that it never stops the boot).
N=0
r7() { N=$((N+1)); SB="$TMPD/sb$N"; : > "$CALLS"; out="$(run7d "$SB" "$@")"; }
run7d() {
    local sb="$1" inst="$2"; shift 2
    mkdir -p "$sb/prefix"
    if [[ -n "$inst" ]]; then
        mkdir -p "$sb/prefix/${PKGJSON%/*}"
        printf '{"version":"%s"}\n' "$inst" > "$sb/prefix/$PKGJSON"
    fi
    [[ -z "${MANAGED_JSON:-}" ]] || printf '%s\n' "$MANAGED_JSON" > "$sb/managed-settings.json"
    local blk; blk="$(block "$sb")"
    ( unset DISABLE_AUTOUPDATER FAKE_VIEW_FAIL FAKE_INSTALL_FAIL FAKE_LAUNCHER_SAYS
      export PATH="$FAKE:$PATH" FAKE_CALLS="$CALLS" FAKE_PREFIX="$sb/prefix" FAKE_LATEST=2.1.319
      # shellcheck disable=SC2163  # "$@" is VAR=VAL pairs, exported as given
      if [[ $# -gt 0 ]]; then export "$@"; fi
      log() { echo "[entrypoint] $*"; }
      asclaude() { "$@"; }
      set -euo pipefail
      eval "$blk"
      echo "block_continued=1" ) 2>&1
}
continued() { grep -qxF 'block_continued=1' <<<"$1"; }
installed() { jq -r .version "$SB/prefix/$PKGJSON" 2>/dev/null; }

echo "== §7d: Claude Code at npm's latest =="
r7 2.1.302
continued "$out" && [[ "$(installed)" == 2.1.319 ]] \
    && [[ "$(grep -c '^npm install' "$CALLS")" == 1 ]] \
    && grep -qE "^npm install -g --prefix $SB/prefix .*@anthropic-ai/claude-code@2\.1\.319$" "$CALLS" \
    && grep -qxF 'launcher --version' "$CALLS" \
    && grep -qF 'Claude Code         : 2.1.319 (updated from 2.1.302)' <<<"$out" \
    && ok "older than npm's latest: one install of exactly that version into the prefix, verified through the launcher" \
    || bad "update (installed $(installed)): $out / $(cat "$CALLS")"
grep -qE 'timeout "\$CC_VIEW_TIMEOUT" npm view' <<<"$BLOCK7D" && grep -qE 'timeout "\$CC_INSTALL_TIMEOUT" npm install' <<<"$BLOCK7D" \
    && ok "both npm calls run under a timeout (a hung registry cannot hold the boot)" \
    || bad "an npm call in §7d has no timeout"

r7 2.1.319
continued "$out" && ! grep -q '^npm install' "$CALLS" && grep -qF "Claude Code         : 2.1.319, npm's latest" <<<"$out" \
    && ok "already npm's latest: no install" || bad "already latest: $out / $(cat "$CALLS")"
r7 2.1.320
continued "$out" && ! grep -q '^npm install' "$CALLS" && [[ "$(installed)" == 2.1.320 ]] \
    && grep -qF "newer than npm's latest (2.1.319): kept" <<<"$out" \
    && ok "newer than npm's latest: kept, never downgraded" || bad "newer: $out / $(cat "$CALLS")"
r7 2.1.302 DISABLE_AUTOUPDATER=1
continued "$out" && [[ ! -s "$CALLS" ]] && [[ "$(installed)" == 2.1.302 ]] \
    && grep -qF 'DISABLE_AUTOUPDATER=1: no update at start' <<<"$out" \
    && ok "DISABLE_AUTOUPDATER=1: the baked version is kept, and npm is never called" || bad "disabled: $out / $(cat "$CALLS")"
MANAGED_JSON='{"env":{"DISABLE_AUTOUPDATER":"1"}}' r7 2.1.302
continued "$out" && [[ ! -s "$CALLS" ]] && [[ "$(installed)" == 2.1.302 ]] \
    && ok "DISABLE_AUTOUPDATER=1 in an operator's managed settings file: kept, npm never called" || bad "managed off: $out / $(cat "$CALLS")"
MANAGED_JSON='{"permissions":{"defaultMode":"plan"}}' r7 2.1.302
continued "$out" && [[ "$(installed)" == 2.1.319 ]] \
    && ok "a managed file without that env: it updates" || bad "managed without env: $out"
r7 2.1.302 DISABLE_AUTOUPDATER=0
continued "$out" && [[ "$(installed)" == 2.1.319 ]] \
    && ok "DISABLE_AUTOUPDATER=0 is not a disabling value: it updates" || bad "DISABLE_AUTOUPDATER=0: $out"

r7 2.1.302 FAKE_VIEW_FAIL=1
continued "$out" && ! grep -q '^npm install' "$CALLS" && [[ "$(installed)" == 2.1.302 ]] \
    && grep -qF "WARNING: Claude Code 2.1.302 kept: npm's latest version could not be read" <<<"$out" \
    && ok "offline: a WARNING, the installed version kept, the boot goes on" || bad "offline: $out"
r7 2.1.302 FAKE_LATEST='<html>'
continued "$out" && ! grep -q '^npm install' "$CALLS" && grep -qF 'WARNING' <<<"$out" \
    && ok "a registry answer that is not a version: a WARNING, nothing installed" || bad "garbage: $out"
r7 2.1.302 FAKE_INSTALL_FAIL=1
continued "$out" && grep -qF 'WARNING: the update to Claude Code 2.1.319 failed or took over' <<<"$out" \
    && grep -qF 'the sessions start on 2.1.302' <<<"$out" \
    && ok "a failed install: a WARNING naming the version the sessions start on, the boot goes on" || bad "install failed: $out"
r7 2.1.302 FAKE_LAUNCHER_SAYS=claude-native-binary-not-installed
continued "$out" && grep -qF "WARNING: Claude Code 2.1.319 was installed, but the CLI reports 'claude-native-binary-not-installed'" <<<"$out" \
    && ok "a CLI that does not report the installed version: a WARNING" || bad "launcher mismatch: $out"
r7 ""
continued "$out" && [[ "$(installed)" == 2.1.319 ]] && grep -qF '(updated from no version)' <<<"$out" \
    && ok "no package.json in the prefix: installs npm's latest" || bad "nothing installed: $out"

# The CLI's first use at boot is §10's `claude mcp`; the update must be done by then, and the
# managed floor (§7a) written first.
order=" $(ep_order) "
pos() { local i=0 n; for n in $order; do [[ "$n" == "$1" ]] && { echo "$i"; return; }; i=$((i+1)); done; echo -1; }
(( $(pos 7d) > $(pos 7a) && $(pos 7d) < $(pos 10) && $(pos 10) >= 0 )) \
    && ok "§7d runs after §7a (the managed floor) and before §10 (the first CLI call)" \
    || bad "section order: $order"
for f in "$EP_D"/[0-9]*.sh; do
    grep -vE '^[[:space:]]*#' "$f" | grep -qE '(^|[^-])claude (mcp|plugin)' || continue
    n="${f##*/}"; n="${n%%-*}"; n="${n#0}"
    (( $(pos "$n") > $(pos 7d) )) || echo "$n"
done > "$TMPD/early"
[[ ! -s "$TMPD/early" ]] && ok "no section before §7d runs the claude CLI" || bad "sections before §7d run the CLI: $(cat "$TMPD/early")"

echo
echo "claude-update-unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
