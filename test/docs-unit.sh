#!/usr/bin/env bash
# Docs match the code: NO docker, NO network. Fails when a change adds a surface without its docs:
#   - every long flag bin/claude-launch and bin/claude-compose-gen parse (their `case` arms)
#     appears in README.md or docs/launcher-commands.md;
#   - every CLAUDE_*/GIT_* variable entrypoint.sh or bin/* reads appears in .env.example, or in
#     ALLOWED below with the reason it is not an operator setting;
#   - every docs/*.md is linked from README.md;
#   - every relative link in README.md and docs/*.md names a file;
#   - every "ADR <number>" names a file under docs/adr/<number>* (none exist yet, so any citation
#     fails until its record is added).
# shellcheck source=test/lib/prelude.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/prelude.sh"
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

# --- 1. Launcher flags -------------------------------------------------------------------------
# A case arm is an indented line starting `--flag)` or `--a|--b)`. The removed flags still have
# arms (they refuse with a pointer to their history), so they are documented as removed instead.
echo "launcher flags documented"
flag_docs="$(cat README.md docs/launcher-commands.md)"
for bin in bin/claude-launch bin/claude-compose-gen; do
    missing=()
    while IFS= read -r f; do
        grep -qE -- "(^|[^a-z0-9-])${f}([^a-z0-9-]|$)" <<<"$flag_docs" || missing+=("$f")
    done < <(grep -oE '^[[:space:]]+-{1,2}[a-z][a-z0-9-]*(\|-{1,2}[a-z][a-z0-9-]*)*\)' "$bin" \
                 | tr -d ' \t)' | tr '|' '\n' | grep -E '^--' | sort -u)
    if (( ${#missing[@]} )); then
        bad "$bin: flags in no doc: ${missing[*]}"
    else
        ok "$bin: every long flag is in README.md or docs/launcher-commands.md"
    fi
done

# --- 2. Environment variables ------------------------------------------------------------------
# Not operator settings, so not in .env.example. One reason per group.
ALLOWED=(
    # Retired: the entrypoint warns or refuses when one is still set (§0, §0b).
    CLAUDE_APT_PROVISION CLAUDE_EGRESS_APT CLAUDE_BROKER_DIR CLAUDE_BROKER_SPOOL
    CLAUDE_CACHE_PROXY CLAUDE_CACHE_PROXY_HOST CLAUDE_CACHE_PROXY_PORT CLAUDE_CONTROLLER
    CLAUDE_CONTROLLER_MAX_SLOTS CLAUDE_DOCKER CLAUDE_SYSBOX CLAUDE_SYSBOX_VERIFY
    CLAUDE_WORKER_BROKER CLAUDE_WORKER_TARBALL CLAUDE_GOAL_CHAIN_REVIEW
    # Claude Code's own variables, set by the entrypoint or named in a comment.
    CLAUDE_CODE_DISABLE_ARTIFACT CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
    CLAUDE_CODE_ENABLE_TELEMETRY CLAUDE_CODE_ENHANCED_TELEMETRY_BETA CLAUDE_CONFIG_DIR CLAUDE_CODE_SESSION_ID
    # Set by the image, the entrypoint or a parent tool for its children, never by an operator.
    CLAUDE_HOME CLAUDE_MODE CLAUDE_PROJECT_NAME CLAUDE_STATE_DIR CLAUDE_SOCK CLAUDE_WORKSPACE
    CLAUDE_GPU_DEVICE CLAUDE_GPU_BACKENDS CLAUDE_BLENDER_DEVICE CLAUDE_LOGIN_MODE
    CLAUDE_RC_LABEL CLAUDE_RC_TMUX_TARGET CLAUDE_RC_RESPAWN_CMD CLAUDE_RC_DEBUG_LOG
    CLAUDE_RC_DEBUG_FILTER CLAUDE_SESSION_CRASH_TIMES CLAUDE_TMUX_SESSION CLAUDE_FACTS_BROWSER_MCP
    CLAUDE_FACTS_GPU_STATE CLAUDE_DOCKER_ROOT CLAUDE_TMPFS_SIZE GIT_REPOS GIT_COMMIT GIT_DIRTY
    CLAUDE_CONTAINERS CLAUDE_AGENT_PATH
    # Test seams: a suite points a tool at a fake binary, directory or measurement.
    CLAUDE_BIN CLAUDE_BIN_RE CLAUDE_KIT_CLAUDE_BIN CLAUDE_CODE_PREFIX CLAUDE_SESSIONS_BIN
    CLAUDE_SESSION_CMD CLAUDE_SESSION_ID_BIN CLAUDE_RC_WATCHDOG_BIN CLAUDE_CREDS_FILE
    CLAUDE_SESSIONS_CGROUP CLAUDE_SESSIONS_REGISTRY CLAUDE_SESSIONS_RUN_DIR
    CLAUDE_SESSIONS_SWITCH_FILE CLAUDE_SESSIONS_SEND_DELAY CLAUDE_SESSIONS_SWITCH_NUDGE_TRIES
    CLAUDE_SESSIONS_TICK CLAUDE_MISE_WORKSPACE CLAUDE_RESPAWN_LOCK_DIR CLAUDE_KIT_START_LOG CLAUDE_DEPS_CHECK_SELFTEST
    CLAUDE_BLENDER_ROOT CLAUDE_BLENDER_URLS CLAUDE_BLENDER_TEST_SHA256 CLAUDE_GPU_MESA_EGL_VENDOR
    CLAUDE_GPU_POLL CLAUDE_GPU_PROBE_TIMEOUT CLAUDE_FACTS_DIRS CLAUDE_FACTS_PROBE_TIMEOUT
    CLAUDE_GH_CHECK_ROOT CLAUDE_EGRESS_STATE_DIR CLAUDE_EGRESS_DEBUG CLAUDE_EGRESS_PRINT_HOSTS CLAUDE_DISK_DATA_ROOT
    CLAUDE_DISK_GC_DRYRUN CLAUDE_DISK_FREE_MIB_OVERRIDE CLAUDE_CACHE_SIZE_MIB_OVERRIDE
    CLAUDE_SCRATCH_ROOT CLAUDE_SCRATCH_PROC CLAUDE_SCRATCH_USE_PCT_OVERRIDE CLAUDE_SCRATCH_REAP_BIN
    CLAUDE_ORPHAN_PS CLAUDE_ORPHAN_KILL CLAUDE_ORPHAN_INTERVAL CLAUDE_ORPHAN_GRACE CLAUDE_ORPHAN_UID
    CLAUDE_PORTS_USED_OVERRIDE CLAUDE_IMAGE_REBUILD_FETCH_TIMEOUT CLAUDE_UPDATE_WAIT
    CLAUDE_SKIP_AUTH_CHECK CLAUDE_CONTAINERS_TUN_DEV CLAUDE_CONTAINERS_USERNS_SYSCTL
    CLAUDE_HEALTHCHECK_PGREP
)
echo "variables in .env.example"
missing=()
while IFS= read -r v; do
    grep -qw -- "$v" .env.example && continue
    [[ " ${ALLOWED[*]} " == *" $v "* ]] && continue
    missing+=("$v")
done < <(grep -rohE '\b(CLAUDE|GIT)_[A-Z0-9_]*[A-Z0-9]\b' entrypoint.sh entrypoint.d/ bin/ | sort -u)
if (( ${#missing[@]} )); then
    bad "read by entrypoint.sh, entrypoint.d/ or bin/ but in neither .env.example nor ALLOWED: ${missing[*]}"
else
    ok "every CLAUDE_*/GIT_* variable the code reads is in .env.example or allowed with a reason"
fi

# --- 3. Every doc is linked from README.md -----------------------------------------------------
echo "docs linked from README.md"
missing=()
for d in docs/*.md; do
    grep -qF "]($d" README.md || missing+=("$d")
done
if (( ${#missing[@]} )); then bad "not linked from README.md: ${missing[*]}"
else ok "every docs/*.md is linked from README.md"; fi

# --- 4. No ADR reference without its file ------------------------------------------------------
echo "ADR references resolve"
missing=()
while IFS= read -r n; do
    compgen -G "docs/adr/${n}*" >/dev/null || missing+=("ADR $n")
done < <(git ls-files -z -co --exclude-standard | xargs -0 grep -ohIE '\bADR [0-9]+\b' 2>/dev/null | awk '{print $2}' | sort -u)
if (( ${#missing[@]} )); then bad "cited with no file under docs/adr/: ${missing[*]}"
else ok "every 'ADR <number>' has its file"; fi

# --- 5. Relative links resolve -----------------------------------------------------------------
# Every `](target)` in README.md and docs/*.md that is not a URL names a file or directory,
# relative to the file that links it (the anchor part is not checked).
echo "relative links resolve"
missing=()
for f in README.md docs/*.md; do
    while IFS= read -r t; do
        [[ "$t" =~ ^[a-z]+: ]] && continue
        [[ -e "$(dirname "$f")/$t" ]] || missing+=("$f -> $t")
    done < <(grep -oE '\]\([^)#]+' "$f" | sed 's/^](//; s/ .*//')
done
if (( ${#missing[@]} )); then bad "links to no file: ${missing[*]}"
else ok "every relative link in README.md and docs/*.md resolves"; fi

echo
echo "docs-unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
