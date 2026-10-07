#!/usr/bin/env bash
# Unit tests for what a session is told about its container: NO docker, NO root.
#
#   - bin/claude-container-facts: the section with and without chromium on PATH, the
#     chrome-devtools MCP flag, the GPU line, toolchains present and absent, space
#   - entrypoint.sh §7b: the browser decision for each CLAUDE_BROWSER value
#   - entrypoint.sh §7c: the managed CLAUDE.md gets the facts (and the GPU note on a --gpu
#     session), is rewritten at each start, and an operator's own file is left alone
#   - entrypoint.sh §8a: the global CLAUDE.md is the image's copy at every start, a
#     mounted one is left alone
#   - entrypoint.sh §8e: frontend-debugging only with the browser MCP on; an unmodified
#     copy is removed when it is off, an edited one kept
# Each entrypoint block is the real one, extracted and run against a sandbox.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRY="$REPO_ROOT/entrypoint.sh"
FACTS="$REPO_ROOT/bin/claude-container-facts"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

# A PATH holding only what the probe itself needs, plus the fakes a case adds, so the
# host's own chromium or toolchains never leak into a result.
BASE="$TMPD/base"; mkdir -p "$BASE"
for t in bash env timeout head grep sed awk df stat date cat tr mktemp mkdir chmod chown install rm; do
    ln -s "$(command -v "$t")" "$BASE/$t"
done
fake() {  # fake <dir> <name> <version line>
    mkdir -p "$1"
    printf '#!/bin/sh\necho "%s"\n' "$3" > "$1/$2"; chmod +x "$1/$2"
}

# ======================================================================================
echo "== claude-container-facts =="
WITH="$TMPD/with"
fake "$WITH" chromium "Chromium 140.0.7339.80 built on Debian"
fake "$WITH" node "v22.11.0"
fake "$WITH" git "git version 2.47.3"
mkdir -p "$TMPD/cache"
out="$(PATH="$WITH:$BASE" CLAUDE_FACTS_BROWSER_MCP=on CLAUDE_FACTS_GPU_STATE="$TMPD/none" \
    CLAUDE_FACTS_DIRS="$TMPD/cache $TMPD/nope" CLAUDE_GPU=0 "$BASE/bash" "$FACTS")"; rc=$?
(( rc == 0 )) && ok "exits 0" || bad "exit $rc: $out"
head -n 1 <<<"$out" | grep -qF 'claude-containers: container facts' \
    && ok "the first line carries the marker §7c checks" || bad "no marker: $out"
grep -qxF -- "- Browser: chromium 140.0.7339.80 at \`$WITH/chromium\`" <<<"$out" \
    && ok "chromium on PATH: its version and path" || bad "browser line: $(grep Browser <<<"$out")"
grep -qxF -- "- chrome-devtools MCP: on" <<<"$out" && ok "the MCP flag reads on" || bad "MCP line"
grep -qxF -- "- GPU: none (not a --gpu session)" <<<"$out" \
    && ok "no GPU state and not a --gpu session: none" || bad "GPU line: $(grep GPU <<<"$out")"
grep -qF 'git 2.47.3' <<<"$out" && grep -qF 'node 22.11.0' <<<"$out" && grep -qF 'gh none' <<<"$out" \
    && grep -qF 'mise none' <<<"$out" \
    && ok "toolchains: versions for the present ones, none for the absent" || bad "toolchains: $(grep Toolchains <<<"$out")"
grep -qF "\`$TMPD/cache\` " <<<"$out" && grep -qF "\`$TMPD/nope\` absent" <<<"$out" \
    && ok "space: free space for a directory, absent for a missing one" || bad "space: $(grep Space <<<"$out")"
grep -qF 'mise use' <<<"$out" && grep -qF 'No apt, no sudo' <<<"$out" \
    && ok "says how to install more" || bad "install line missing"

WITHOUT="$TMPD/without"; fake "$WITHOUT" git "git version 2.47.3"
echo "gpu: ok (Fake GPU 2000, driver 580.00.00, 5000/5120 MiB free, util 0%, nvenc 0)" > "$TMPD/gpu-state"
out="$(PATH="$WITHOUT:$BASE" CLAUDE_FACTS_BROWSER_MCP=bogus CLAUDE_FACTS_GPU_STATE="$TMPD/gpu-state" \
    CLAUDE_FACTS_DIRS="$TMPD/cache" "$BASE/bash" "$FACTS")"
grep -qxF -- "- Browser: none" <<<"$out" && ok "no chromium on PATH: browser: none" \
    || bad "browser line without chromium: $(grep Browser <<<"$out")"
grep -qxF -- "- chrome-devtools MCP: off" <<<"$out" && ok "an unknown MCP value reads off" || bad "MCP line"
grep -qF -- '- GPU: ok (Fake GPU 2000, driver 580.00.00' <<<"$out" \
    && ok "the GPU line is the boot probe's" || bad "GPU line: $(grep GPU <<<"$out")"

# ======================================================================================
echo "== entrypoint.sh §7b: the browser decision =="
B7="$(awk '/^# --- 7b\. Browser decision/{f=1} /^# --- 7c\./{exit} f' "$ENTRY")"
[[ -n "$B7" ]] || bad "could not extract §7b"
decide() {  # decide <PATH> <CLAUDE_BROWSER>
    ( PATH="$1"; CLAUDE_BROWSER="$2"; set -euo pipefail; eval "$B7"; echo "$BROWSER_MCP" )
}
BAKED="$TMPD/baked"; fake "$BAKED" chromium "Chromium 140"; fake "$BAKED" chrome-devtools-mcp "1.0.0"
for v in "" "1" "auto"; do
    [[ "$(decide "$BAKED:$BASE" "$v")" == on ]] && ok "baked, CLAUDE_BROWSER='$v': on" || bad "baked '$v' should be on"
done
[[ "$(decide "$BAKED:$BASE" $'OFF\r')" == on ]] && bad "baked, CLAUDE_BROWSER=OFF must be off" || ok "baked, CLAUDE_BROWSER=OFF: off"
[[ "$(decide "$WITHOUT:$BASE" "1")" == off ]] && ok "not baked, even CLAUDE_BROWSER=1: off" || bad "unbaked must be off"
[[ "$(decide "$WITH:$BASE" "")" == off ]] && ok "chromium without the MCP binary: off" || bad "chromium alone must be off"

# ======================================================================================
echo "== entrypoint.sh §7c: the session's managed memory =="
B7C="$(awk '/^# --- 7c\. Session memory/{f=1} /^# --- 8\./{exit} f' "$ENTRY")"
grep -qE '^SESSION_MD=' <<<"$B7C" && grep -qE '^SESSION_MD_OWNER=' <<<"$B7C" && grep -qE '^FACTS_CMD=' <<<"$B7C" \
    && grep -qE '^GPU_NOTE_SRC=' <<<"$B7C" \
    && ok "§7c names its root-only paths on their own lines (so this sandbox redirect is real)" \
    || bad "§7c must assign SESSION_MD, SESSION_MD_OWNER, FACTS_CMD, GPU_NOTE_SRC on their own lines"
SMD="$TMPD/etc/claude-code/CLAUDE.md"
run_7c() {  # run_7c <CLAUDE_GPU> [PATH]
    local blk; blk="$(sed -e "s#^SESSION_MD=.*#SESSION_MD=\"$SMD\"#" \
        -e "s#^SESSION_MD_OWNER=.*#SESSION_MD_OWNER=\"$(id -u):$(id -g)\"#" \
        -e "s#^FACTS_CMD=.*#FACTS_CMD=\"$FACTS\"#" \
        -e "s#^GPU_NOTE_SRC=.*#GPU_NOTE_SRC=\"$REPO_ROOT/claude-config/CLAUDE.gpu.md\"#" <<<"$B7C")"
    ( log() { echo "[entrypoint] $*"; }; set -euo pipefail; CLAUDE_GPU="$1"; BROWSER_MCP=off
      GPU_STATE_FILE="$TMPD/gpu-state"; PATH="${2:-$WITHOUT:$BASE}"; eval "$blk" )
}
out="$(run_7c 0)"; rc=$?
(( rc == 0 )) && grep -qxF -- "- Browser: none" "$SMD" && ! grep -qF 'GPU session note' "$SMD" \
    && ok "writes the facts (browser: none), no GPU note off a --gpu session" || bad "§7c plain (rc=$rc): $out"
out="$(run_7c 0 "$WITH:$BASE")"
grep -qF -- "- Browser: chromium 140.0.7339.80" "$SMD" \
    && ok "the next start rewrites it (now chromium)" || bad "§7c did not rewrite: $(cat "$SMD")"
out="$(run_7c 1)"
grep -qF 'container facts' "$SMD" && grep -qF 'GPU session note' "$SMD" && grep -qF -- '- GPU: ok (Fake GPU 2000' "$SMD" \
    && ok "a --gpu session gets the facts, its GPU line and the GPU note" || bad "§7c gpu: $(cat "$SMD")"
echo "# the operator's own" > "$SMD"
out="$(run_7c 1)"
[[ "$(cat "$SMD")" == "# the operator's own" ]] && grep -qF "operator's own file" <<<"$out" \
    && ok "an operator's own file (no marker) is left alone, and the log says so" || bad "§7c clobbered: $out"
rm -f "$SMD"; printf '#!/bin/sh\nexit 1\n' > "$TMPD/fail-facts"; chmod +x "$TMPD/fail-facts"
out="$(FACTS="$TMPD/fail-facts" run_7c 0)"; rc=$?
(( rc == 0 )) && grep -qF 'container facts' "$SMD" && grep -qF 'probe (claude-container-facts) failed' "$SMD" \
    && ok "a failed probe never stops the boot, and says it failed" || bad "§7c probe failure (rc=$rc): $out"

# ======================================================================================
echo "== entrypoint.sh §8a: the global CLAUDE.md at every start =="
B8A="$(awk '/^# 8a\. Global CLAUDE.md/{f=1} /^# 8b\./{exit} f' "$ENTRY")"
grep -qE '^MOUNTINFO=' <<<"$B8A" && ok "§8a names MOUNTINFO on its own line" || bad "§8a must assign MOUNTINFO on its own line"
BAKE="$TMPD/bake"; CFG="$TMPD/home/.claude"; mkdir -p "$BAKE" "$CFG"
MI="$TMPD/mountinfo"; echo "1 0 0:1 / / rw - overlay overlay rw" > "$MI"
run_8a() {
    local blk; blk="$(sed -e "s#^MOUNTINFO=.*#MOUNTINFO=\"$MI\"#" <<<"$B8A")"
    ( log() { echo "[entrypoint] $*"; }; set -euo pipefail; BAKE_DIR="$BAKE"; CLAUDE_CONFIG_DIR="$CFG"
      CLAUDE_UID="$(id -u)"; CLAUDE_GID="$(id -g)"; eval "$blk" )
}
echo "v1" > "$BAKE/CLAUDE.md"
run_8a >/dev/null && diff -q "$BAKE/CLAUDE.md" "$CFG/CLAUDE.md" >/dev/null \
    && ok "first start: the image's copy" || bad "first start did not install it"
echo "v2" > "$BAKE/CLAUDE.md"; echo "edited in the volume" >> "$CFG/CLAUDE.md"
out="$(run_8a)"
diff "$BAKE/CLAUDE.md" "$CFG/CLAUDE.md" >/dev/null && grep -qF "installed the image's copy" <<<"$out" \
    && ok "second start: the new image copy replaces the old one (diff prints nothing)" || bad "second start: $(cat "$CFG/CLAUDE.md")"
out="$(run_8a)"
[[ -z "$out" ]] && ok "an unchanged copy is left as is, silently" || bad "unchanged start logged: $out"
echo "the owner's own" > "$CFG/CLAUDE.md"
echo "2 1 0:2 /x $CFG/CLAUDE.md rw,relatime - ext4 /dev/sda1 rw" >> "$MI"
out="$(run_8a)"
[[ "$(cat "$CFG/CLAUDE.md")" == "the owner's own" ]] && grep -qF 'is mounted' <<<"$out" \
    && ok "a mounted CLAUDE.md is left alone, and the log says so" || bad "§8a clobbered a mount: $out"

# ======================================================================================
echo "== entrypoint.sh §8e: a skill only where it can work =="
B8E="$(awk '/^# 8e\. Skills/{f=1} /^# --- 9\./{exit} f' "$ENTRY")"
mkdir -p "$BAKE/skills/frontend-debugging" "$BAKE/skills/example-skill"
echo "fd" > "$BAKE/skills/frontend-debugging/SKILL.md"; echo "ex" > "$BAKE/skills/example-skill/SKILL.md"
run_8e() {  # run_8e <BROWSER_MCP>
    ( log() { echo "[entrypoint] $*"; }; set -euo pipefail; BAKE_DIR="$BAKE"; CLAUDE_CONFIG_DIR="$CFG"
      CLAUDE_UID="$(id -u)"; CLAUDE_GID="$(id -g)"; BROWSER_MCP="$1"; eval "$B8E" )
}
SK="$CFG/skills"
run_8e off >/dev/null; rc=$?
(( rc == 0 )) && [[ -f "$SK/example-skill/SKILL.md" && ! -e "$SK/frontend-debugging" ]] \
    && ok "browser MCP off: frontend-debugging absent, other skills installed" || bad "§8e off (rc=$rc): $(ls "$SK")"
run_8e on >/dev/null
[[ -f "$SK/frontend-debugging/SKILL.md" ]] && ok "browser MCP on: frontend-debugging installed" || bad "§8e on"
out="$(run_8e off)"
[[ ! -e "$SK/frontend-debugging" ]] && grep -qF 'Skill frontend-debugging: removed' <<<"$out" \
    && ok "back to off: the unmodified copy is removed" || bad "§8e did not remove: $out"
run_8e on >/dev/null; echo "my notes" >> "$SK/frontend-debugging/SKILL.md"
run_8e off >/dev/null
grep -qF 'my notes' "$SK/frontend-debugging/SKILL.md" 2>/dev/null \
    && ok "an edited copy is kept" || bad "§8e removed an edited skill"

# ======================================================================================
echo "== image wiring =="
grep -q 'COPY bin/claude-container-facts /usr/local/bin/claude-container-facts' "$REPO_ROOT/Dockerfile" \
    && ok "the probe is baked" || bad "the Dockerfile must COPY bin/claude-container-facts"
bash -n "$ENTRY" && ok "entrypoint.sh parses" || bad "entrypoint.sh has a syntax error"

echo
echo "container-facts-unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
