#!/usr/bin/env bash
# Automated smoke test for the Claude Code container image.
#
# Validates everything that does NOT require the interactive OAuth flow or a
# phone: the entrypoint guards, baked-in config/MCP/plugins/commands/skills
# merge, workspace-trust pre-accept, tmux session, sshd, SSH login, and the
# two fail-fast paths. The real `make login` + mobile-app checks (acceptance
# criteria 2-auth and 5) remain manual and are listed at the end.
#
#   test/smoke.sh                       # tests claude-code-box:latest
#   IMAGE=claude-code-box:test test/smoke.sh   # or any other tag
#   make smoke                          # build + smoke-test in one step
set -euo pipefail

IMAGE="${IMAGE:-claude-code-box:latest}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
CN="claude-smoke-$$"
OTELCN="claude-smoke-otel-$$"
EGCN="claude-smoke-egress-$$"
# IPv6 egress fixtures (section 14b): a throwaway ULA network plus one locked-down
# container and two identical HTTP peers on it. The subnet is derived from the PID so
# two smoke runs on one host do not collide on the same prefix.
EG6NET="claude-smoke-egress6-$$"
EG6SUBNET="fd00:5006:$(printf '%x' $(( $$ % 65536 )))::/64"
EG6CN="claude-smoke-egress6-cn-$$"
EG6ALLOW="claude-smoke-egress6-allow-$$"
EG6DENY="claude-smoke-egress6-deny-$$"
# Strict-lockdown fixtures (section 14c): one container that CANNOT apply its ruleset
# and must therefore never reach an agent session, and one that can and must.
EGSFCN="claude-smoke-egress-strict-fail-$$"
EGSOKCN="claude-smoke-egress-strict-ok-$$"
# Periodic-refresh fixture (section 14d): one lockdown container with a deliberately
# short interval, so a live refresh happens inside the life of a smoke run.
EGRFCN="claude-smoke-egress-refresh-$$"
BRKCN="claude-smoke-broker-$$"
BRKOFFCN="claude-smoke-broker-off-$$"
BRKFAILCN="claude-smoke-broker-fail-$$"
NOKEYCN="claude-smoke-nokey-$$"
BRWACN="claude-smoke-browser-auto-$$"
BRWOCN="claude-smoke-browser-off-$$"
BRWFCN="claude-smoke-browser-force-$$"
BRWLCN="claude-smoke-browser-live-$$"
AUTHVOL="claude-smoke-auth-$$"
WSVOL="claude-smoke-ws-$$"
PASS=0 FAIL=0

cleanup() {
    docker rm -f "$CN" "$OTELCN" "$EGCN" "$BRKCN" "$BRKOFFCN" "$BRKFAILCN" "$NOKEYCN" \
                 "$BRWACN" "$BRWOCN" "$BRWFCN" "$BRWLCN" \
                 "$EG6CN" "$EG6ALLOW" "$EG6DENY" "$EGSFCN" "$EGSOKCN" "$EGRFCN" >/dev/null 2>&1 || true
    # The network only goes after its containers do, or Docker refuses to remove it.
    docker network rm "$EG6NET" >/dev/null 2>&1 || true
    docker volume rm "$AUTHVOL" "$WSVOL" >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT

ok()   { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "== image: $IMAGE =="
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "image missing: build first"; exit 1; }

# --- fixtures ---------------------------------------------------------------
ssh-keygen -q -t ed25519 -f "$TMP/key" -N ''
git init -q "$TMP/repo"
( cd "$TMP/repo"
  # Identity via env so the commit survives `make smoke`, which exports .env
  # (empty GIT_AUTHOR_*/GIT_COMMITTER_* there would otherwise override -c).
  GIT_AUTHOR_NAME=smoke GIT_AUTHOR_EMAIL=smoke@test \
  GIT_COMMITTER_NAME=smoke GIT_COMMITTER_EMAIL=smoke@test \
    git commit -q --allow-empty -m init )
echo "smoke-marker" > "$TMP/repo/marker.txt"

# A throwaway plugins bake-in to prove the merge mechanism generically
# (the shipped claude-config/plugins/plugins.json is intentionally empty).
cat > "$TMP/plugins.json" <<'JSON'
{
  "extraKnownMarketplaces": {
    "smoke-mkt": { "source": { "source": "git", "url": "https://example.invalid/x.git" }, "autoUpdate": false }
  },
  "enabledPlugins": { "smoke-plugin@smoke-mkt": true }
}
JSON

echo
echo "== 1. ANTHROPIC_API_KEY hard-fail =="
if docker run --rm -e ANTHROPIC_API_KEY=sk-test "$IMAGE" >/dev/null 2>&1; then
    bad "container should refuse to start with ANTHROPIC_API_KEY set"
else
    ok "refuses ANTHROPIC_API_KEY"
fi

echo
echo "== 2. fail-fast: no credentials =="
out="$(docker run --rm -v "$AUTHVOL:/auth" "$IMAGE" 2>&1 || true)"
echo "$out" | grep -q "No credentials in the claude-auth volume" \
    && ok "clear error when auth volume empty" \
    || bad "missing/!clear no-credentials error"

echo
echo "== 3. fail-fast: empty workspace, no repo =="
out="$(docker run --rm -e CLAUDE_SKIP_AUTH_CHECK=1 -v "$WSVOL:/workspace" "$IMAGE" 2>&1 || true)"
echo "$out" | grep -q "Empty workspace and no GIT_REPO_URL" \
    && ok "clear error when no repo and empty workspace" \
    || bad "missing/!clear no-repo error"

echo
echo "== 4. boots with bind-mounted workspace =="
# Run under the SAME escape-hardening profile the launcher applies (cap-drop ALL
# + minimal caps + no-new-privileges), so the whole suite proves boot, config
# merge, SSH login, and git all work hardened. Sourced from _common.sh to avoid
# drift. GH_TOKEN also exercises the git credential-helper wiring (asserted §8).
HARDEN_FLAGS="$(source "$REPO_ROOT/bin/_common.sh"; harden_run_args)"
# shellcheck disable=SC2086  # HARDEN_FLAGS is intentionally word-split
docker run -d --name "$CN" \
    $HARDEN_FLAGS \
    -e CLAUDE_SKIP_AUTH_CHECK=1 \
    -e CLAUDE_PROJECT_NAME=smoke \
    -e GH_TOKEN=ghp_smoketestdummy \
    -p 127.0.0.1::22 \
    -v "$TMP/repo:/workspace" \
    -v "$TMP/key.pub:/etc/claude/authorized_keys:ro" \
    -v "$TMP/plugins.json:/opt/claude-config/plugins/plugins.json:ro" \
    "$IMAGE" >/dev/null

# wait for the entrypoint to reach the tmux launch (or die)
for i in $(seq 1 60); do
    log="$(docker logs "$CN" 2>&1 || true)"
    grep -q "Claude Code session 'claude' started in tmux" <<<"$log" && break
    [[ "$(docker inspect -f '{{.State.Running}}' "$CN" 2>/dev/null)" == "true" ]] \
        || { echo "container exited early:"; echo "$log" | tail -20; break; }
    sleep 2
done

cexec() { docker exec "$CN" bash -lc "$1"; }
asclaude_x() { docker exec "$CN" gosu claude env CLAUDE_CONFIG_DIR=/home/claude/.claude HOME=/home/claude bash -lc "$1"; }

check "entrypoint reached tmux launch" \
    'grep -q "started in tmux" <<<"$(docker logs "$CN" 2>&1)"'
check "tmux session 'claude' is alive" \
    'asclaude_x "tmux has-session -t claude" >/dev/null 2>&1'
check "sshd is running" \
    'cexec "pgrep -x sshd" >/dev/null 2>&1'
check "workspace bind mount visible (skipped clone)" \
    'cexec "cat /workspace/marker.txt" 2>/dev/null | grep -q smoke-marker'
# No CLAUDE_MODEL was passed, so the entrypoint must default to opus (best available).
check "entrypoint defaults the model to opus (best available)" \
    'grep -qE "Model[[:space:]]*: opus" <<<"$(docker logs "$CN" 2>&1)"'

# --- the CLI pin, checked against the RUNNING IMAGE (CC-CLAUDE-CODE-UPGRADE) --------
# test/cli-version-unit.sh proves the six *declarations* of the pin agree, but it is
# pure-static: it reads repo files and never the built image. These are the live half:
# the image you are actually about to run really ships the pinned CLI, and really is at
# or above the Opus-4.8 floor. A stale gitignored .env silently overrides the repo's pin
# (the Makefile's `-include .env` beats `?=` AND the Dockerfile ARG), so without a check
# against the real image a host can keep shipping an old CLI, and `--model opus` keeps
# silently resolving to Opus 4.7: with every other gate green.
PINNED_VER="$(sed -n 's/^ARG CLAUDE_CODE_VERSION=\(.*\)$/\1/p' "$(dirname "${BASH_SOURCE[0]}")/../Dockerfile")"
OPUS48_FLOOR=2.1.154
check "image ships the pinned Claude Code CLI ($PINNED_VER)" \
    '[[ "$(cexec "claude --version" 2>/dev/null | awk "{print \$1}")" == "$PINNED_VER" ]]'
check "the CLI in the image clears the Opus-4.8 floor ($OPUS48_FLOOR, else '--model opus' means 4.7)" \
    'v="$(cexec "claude --version" 2>/dev/null | awk "{print \$1}")"; [[ "$(printf "%s\n%s\n" "$OPUS48_FLOOR" "$v" | sort -V | head -1)" == "$OPUS48_FLOOR" ]]'
check "claude binary is at /usr/local/bin/claude" \
    'cexec "test -e /usr/local/bin/claude"'
# The reason the CLI version is pinned at all: these two flags must combine.
check "--dangerously-skip-permissions and --remote-control both exist in this CLI" \
    'h="$(cexec "claude --help" 2>/dev/null)"; grep -q -- "--dangerously-skip-permissions" <<<"$h" && grep -q -- "--remote-control" <<<"$h"'

echo
echo "== 5. baked-in config merged =="
check "settings.json defaultMode=bypassPermissions" \
    'cexec "jq -e \".permissions.defaultMode==\\\"bypassPermissions\\\"\" /home/claude/.claude/settings.json" >/dev/null 2>&1'
check "settings.json has skipDangerousModePermissionPrompt" \
    'cexec "jq -e \".skipDangerousModePermissionPrompt==true\" /home/claude/.claude/settings.json" >/dev/null 2>&1'
check "plugin marketplace merged into settings.json (mechanism)" \
    'cexec "jq -e \".extraKnownMarketplaces[\\\"smoke-mkt\\\"]\" /home/claude/.claude/settings.json" >/dev/null 2>&1'
check "plugin enabled in settings.json (mechanism)" \
    'cexec "jq -e \".enabledPlugins[\\\"smoke-plugin@smoke-mkt\\\"]\" /home/claude/.claude/settings.json" >/dev/null 2>&1'
check "global CLAUDE.md installed" \
    'cexec "test -s /home/claude/.claude/CLAUDE.md"'
check "baked slash command installed" \
    'cexec "test -f /home/claude/.claude/commands/container-info.md"'
check "baked skill installed" \
    'cexec "test -f /home/claude/.claude/skills/example-skill/SKILL.md"'

echo
echo "== 5b. managed settings: operator policy at the root-owned vendor path =="
# Section 5 proves the settings this image asserts reach ~/.claude/settings.json. That
# file is owned by the AGENT user, on a per-project volume that outlives the container,
# and section 8b's merge lets the existing file win, so it is the policed process that
# owns the file the policy is written in. This section is the other half: the subset that
# is POLICY is also delivered to /etc/claude-code/managed-settings.json, which Claude Code
# reads above every other settings level (https://code.claude.com/docs/en/managed-settings)
# and which root owns.
#
# These live here rather than in test/unit.sh because root ownership, mode bits, and a
# write that the kernel refuses are only truly observable in a running container.
MSFILE=/etc/claude-code/managed-settings.json
MSDIR=/etc/claude-code
MSSETTINGS=/home/claude/.claude/settings.json
msjq()   { docker exec "$CN" jq -e "$1" "$2" >/dev/null 2>&1; }
msstat() { docker exec "$CN" stat -c "$1" "$2" 2>/dev/null || true; }

check "the managed settings file exists at the vendor path ($MSFILE)" \
    'docker exec "$CN" test -f "$MSFILE"'
check "it is owned by root (uid 0), not by the agent user" \
    '[ "$(msstat %u "$MSFILE")" = 0 ]'
check "it carries no write bit for group or other (mode 644)" \
    '[ "$(msstat %a "$MSFILE")" = 644 ]'
check "its directory is root-owned and not writable by the agent user (0:755)" \
    '[ "$(msstat %u:%a "$MSDIR")" = "0:755" ]'

# WHAT IS POLICY AND WHAT IS NOT. The containment posture and the pin that keeps the CLI
# on the version this image verifies its flags against are policy; a commit-message
# preference is not, and is deliberately left where a session can still change it.
check "policy: permissions.defaultMode is delivered as managed" \
    'msjq ".permissions.defaultMode == \"bypassPermissions\"" "$MSFILE"'
check "policy: skipDangerousModePermissionPrompt is delivered as managed" \
    'msjq ".skipDangerousModePermissionPrompt == true" "$MSFILE"'
check "policy: env.DISABLE_AUTOUPDATER is delivered as managed" \
    'msjq ".env.DISABLE_AUTOUPDATER == \"1\"" "$MSFILE"'
check "preference: includeCoAuthoredBy is NOT managed (a session may still change it)" \
    'msjq "has(\"includeCoAuthoredBy\") | not" "$MSFILE"'
check "bypass mode is NOT disabled by this image (that call is deliberately the operator's)" \
    'msjq "(.permissions // {}) | has(\"disableBypassPermissionsMode\") | not" "$MSFILE"'

# The log is MATERIALIZED once and every assertion greps the variable: this file runs
# under `pipefail`, where `docker logs … | grep -q X` fails the PIPELINE on a match.
MSLOG="$(docker logs "$CN" 2>&1 || true)"
check "the boot log reports policy as ENFORCED, naming the file" \
    'grep -qE "Managed policy +: ENFORCED" <<<"$MSLOG" && grep -qF "$MSFILE" <<<"$MSLOG"'
check "the boot log names WHICH settings are managed" \
    'grep -qF "permissions.defaultMode" <<<"$MSLOG" && grep -qF "skipDangerousModePermissionPrompt" <<<"$MSLOG" && grep -qF "env.DISABLE_AUTOUPDATER" <<<"$MSLOG"'
check "and says they are not overridable from inside the container" \
    'grep -qiF "NOT overridable" <<<"$MSLOG"'
check "policy was in force BEFORE the agent started (the managed line precedes the tmux launch)" \
    'f="$(grep -m1 -E "Managed policy|started in tmux" <<<"$MSLOG")"; case "$f" in *"Managed policy"*) true ;; *) false ;; esac'

# The property that matters, and the one no log line can establish: a session running as
# the agent user cannot change this file. Every attempt is made AS THE AGENT, and the
# file's bytes are compared before and after the whole sweep.
MS_SHA_BEFORE="$(docker exec "$CN" sha256sum "$MSFILE" 2>/dev/null | cut -d' ' -f1 || true)"
ms_got=()
for _attempt in \
    'echo pwned > FILE' \
    'echo pwned >> FILE' \
    ': > FILE' \
    'rm -f FILE' \
    'mv FILE FILE.stolen' \
    'cp /dev/null FILE' \
    'ln -sf /dev/null FILE' \
    'sed -i s/permissions/pwned/ FILE' \
    'chmod 666 FILE' \
    'touch DIR/managed-settings.json.new' \
    'rm -rf DIR'
do
    _cmd="${_attempt//FILE/$MSFILE}"; _cmd="${_cmd//DIR/$MSDIR}"
    # `if`, not `A && B`: this file runs under `set -e`, and a denied write is the
    # EXPECTED outcome here, so it must not be able to abort the suite.
    if asclaude_x "$_cmd" >/dev/null 2>&1; then ms_got+=("$_attempt"); fi
done
[[ ${#ms_got[@]} -eq 0 ]] \
    && ok "every write, replace and delete attempted as the agent user is denied (11 of them)" \
    || bad "the agent user succeeded at: ${ms_got[*]}"
check "and the managed file's contents are unchanged after every attempt" \
    '[ "$(docker exec "$CN" sha256sum "$MSFILE" | cut -d" " -f1)" = "$MS_SHA_BEFORE" ]'

# A2: the policy must not depend on the agent-writable file carrying it too. The agent
# rewrites its own settings.json with contradicting values, and then empties it: neither
# reaches the managed file, so the value Claude Code reads at the top of the hierarchy is
# unchanged. settings.json is restored afterwards so later sections see what they expect.
docker exec "$CN" cp "$MSSETTINGS" /tmp/settings.pre-a2.json || true
MS_CONTRA='{"permissions":{"defaultMode":"plan"},"skipDangerousModePermissionPrompt":false,"env":{"DISABLE_AUTOUPDATER":"0"}}'
asclaude_x "printf '%s' '$MS_CONTRA' > $MSSETTINGS" >/dev/null 2>&1 || true
check "the agent really did rewrite its own ~/.claude/settings.json (the test is live)" \
    'msjq ".permissions.defaultMode == \"plan\"" "$MSSETTINGS"'
check "a contradicting ~/.claude/settings.json leaves the managed file byte-identical" \
    '[ "$(docker exec "$CN" sha256sum "$MSFILE" | cut -d" " -f1)" = "$MS_SHA_BEFORE" ]'
check "and the managed file still carries the image's value, not the session's" \
    'msjq ".permissions.defaultMode == \"bypassPermissions\"" "$MSFILE"'
asclaude_x "printf '%s' '{}' > $MSSETTINGS" >/dev/null 2>&1 || true
check "emptying ~/.claude/settings.json to {} also leaves the managed policy in force" \
    '[ "$(docker exec "$CN" sha256sum "$MSFILE" | cut -d" " -f1)" = "$MS_SHA_BEFORE" ] && msjq ".skipDangerousModePermissionPrompt == true" "$MSFILE"'

# The remaining half of A2 is the CLI's own precedence. Claude Code reports the settings
# source it selected through the interactive /status view, which needs a real OAuth
# session: exactly the thing this suite deliberately does not have (`make login` is manual
# and stays manual). `claude doctor` is the non-interactive route the vendor documents for
# the same question, so it is asked; if it cannot answer in this environment the result is
# a SKIP, never a PASS on an observable nobody read.
MS_DOCTOR="$(docker exec "$CN" gosu claude env CLAUDE_CONFIG_DIR=/home/claude/.claude HOME=/home/claude \
    timeout 60 claude doctor 2>&1 </dev/null || true)"
if grep -qF "$MSFILE" <<<"$MS_DOCTOR"; then
    ok "the CLI itself names $MSFILE as a settings source while settings.json contradicts it"
elif grep -qiE 'managed settings|enterprise managed' <<<"$MS_DOCTOR"; then
    ok "the CLI itself reports a managed settings source while settings.json contradicts it"
else
    # The byte count is deliberate: it separates "doctor ran and named no managed
    # source" from "doctor produced nothing at all here", which is the difference
    # between an observable this environment cannot reach and a branch that is dead.
    echo "  SKIP  the CLI's own report of which settings source it selected ('claude doctor' produced ${#MS_DOCTOR} bytes and named no managed settings source; /status needs a real OAuth session, which this suite has by design not got). A2's mechanical half is asserted above, outside this SKIP."
fi
# `cp` writes THROUGH the existing file, so settings.json keeps the agent's ownership.
docker exec "$CN" cp /tmp/settings.pre-a2.json "$MSSETTINGS" || true
check "settings.json was restored for the sections that follow" \
    'msjq ".permissions.defaultMode == \"bypassPermissions\"" "$MSSETTINGS"'

echo
echo "== 6. workspace trust pre-accepted =="
check "hasCompletedOnboarding == true" \
    'cexec "jq -e \".hasCompletedOnboarding==true\" /home/claude/.claude/.claude.json" >/dev/null 2>&1'
check "projects[/workspace].hasTrustDialogAccepted == true" \
    'cexec "jq -e \".projects[\\\"/workspace\\\"].hasTrustDialogAccepted==true\" /home/claude/.claude/.claude.json" >/dev/null 2>&1'

echo
echo "== 7. SSH in (non-interactive command) =="
PORT="$(docker port "$CN" 22/tcp | head -1 | sed 's/.*://')"
if ssh -i "$TMP/key" -p "$PORT" \
       -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
       -o ConnectTimeout=5 claude@127.0.0.1 \
       'tmux has-session -t claude && echo SSH_TMUX_OK' 2>/dev/null \
   | grep -q SSH_TMUX_OK; then
    ok "ssh login works and reaches the live tmux session"
else
    bad "ssh login / tmux reach failed (port $PORT)"
fi

echo
echo "== 8. GH_TOKEN wires gh in as git credential helper =="
check "entrypoint ran 'gh auth setup-git' for GH_TOKEN" \
    'grep -q "gh wired in as git credential helper" <<<"$(docker logs "$CN" 2>&1)"'
check "git credential helper for github.com HTTPS uses gh" \
    'asclaude_x "git config --global --get-all credential.https://github.com.helper" 2>/dev/null | grep -q "gh auth git-credential"'

echo
echo "== 9. claude-compose-gen per-repo resource overrides =="
GENOUT="$TMP/gen-compose.yml"
# Sentinel values 7 / 777m won't collide with any plausible global default.
# Repos given as owner/repo so no --org / gh enumeration is needed offline; the
# service names (and override keys) are the bare repo names alpha / beta.
if "$REPO_ROOT/bin/claude-compose-gen" --out "$GENOUT" \
       --cpu alpha=7 --mem alpha=777m --model alpha=sonnet --browser beta acme/alpha acme/beta >/dev/null 2>&1; then
    # Extract exactly one service's block (its `^  name:` header to the next
    # service or top-level key) so assertions don't depend on line offsets: the
    # environment block grows over time and fixed -A windows silently rot.
    svc_block(){ awk -v s="^  $1:\$" '
        $0 ~ s {f=1; print; next}
        f && /^  [A-Za-z0-9_-]+:$/ {exit}
        f && /^[A-Za-z]/ {exit}
        f {print}' "$GENOUT"; }
    check "--cpu override applies cpus to the target repo" \
        'svc_block alpha | grep -q "cpus: 7"'
    check "--mem override applies mem_limit to the target repo" \
        'svc_block alpha | grep -q "mem_limit: 777m"'
    check "non-overridden repo keeps the global default (no override leak)" \
        '! svc_block beta | grep -qE "cpus: 7|mem_limit: 777m"'
    check "--browser sets CLAUDE_BROWSER on the target repo" \
        'svc_block beta | grep -q "CLAUDE_BROWSER"'
    check "--browser repo uses the browser image" \
        'svc_block beta | grep -qE "image: .*:browser"'
    check "--browser does not leak to non-browser repos" \
        '! svc_block alpha | grep -q "CLAUDE_BROWSER"'
    check "--model override sets the literal model on the target repo" \
        'svc_block alpha | grep -q "CLAUDE_MODEL.*sonnet"'
    check "non-overridden repo defaults CLAUDE_MODEL to opus (best available)" \
        'svc_block beta | grep "CLAUDE_MODEL" | grep -q opus'
    check "--model does not leak the override to other repos" \
        '! svc_block beta | grep -q sonnet'
else
    bad "claude-compose-gen failed to generate with --cpu/--mem/--model/--browser"
fi

echo
echo "== 10. Remote Control healthcheck + watchdog =="
check "claude-healthcheck present + executable" \
    'cexec "test -x /usr/local/bin/claude-healthcheck"'
check "claude-rc-watchdog present + executable" \
    'cexec "test -x /usr/local/bin/claude-rc-watchdog"'
check "image declares a HEALTHCHECK" \
    'docker inspect -f "{{if .Config.Healthcheck}}yes{{end}}" "$IMAGE" | grep -q yes'
check "entrypoint starts the Remote Control watchdog" \
    'grep -q "Remote Control watchdog started" <<<"$(docker logs "$CN" 2>&1)"'
check "claude pane lives in tmux window 'main'" \
    'asclaude_x "tmux list-windows -t claude" 2>/dev/null | grep -qw main'
check "RC watchdog process is running" \
    'cexec "pgrep -f claude-rc-watchdog" >/dev/null 2>&1'
# No auth in smoke, so `claude` is not running and the probe will report
# unhealthy: assert only that it executes cleanly and emits a verdict line.
check "healthcheck runs and emits a verdict line" \
    'cexec "/usr/local/bin/claude-healthcheck" 2>&1 | grep -qE "^(healthy|unhealthy:)"'

echo
echo "== 11. fleet hardening: secret guard, queue helper, telemetry plumbing =="
check "claude-secret-guard baked + executable" \
    'cexec "test -x /usr/local/bin/claude-secret-guard"'
check "claude-enqueue baked + executable" \
    'cexec "test -x /usr/local/bin/claude-enqueue"'
check "secret guard installed (global core.hooksPath → the guard)" \
    'asclaude_x "test \"\$(readlink \$(git config --global core.hooksPath)/pre-commit)\" = /usr/local/bin/claude-secret-guard"'
check "secret guard blocks a staged .env (filename deny-list)" \
    'asclaude_x "cd /workspace && printf SECRET=x > .env && git add -f .env && git -c user.email=t@t -c user.name=t commit -m leak 2>&1 | grep -q claude-secret-guard; rc=\$?; git restore --staged .env 2>/dev/null; rm -f .env; exit \$rc"'
# OTel is env-passthrough; assert the entrypoint composes + logs it when enabled.
docker run -d --name "$OTELCN" -e CLAUDE_SKIP_AUTH_CHECK=1 -e CLAUDE_PROJECT_NAME=otelsmoke \
    -e CLAUDE_OTEL_ENABLED=1 -e OTEL_EXPORTER_OTLP_ENDPOINT=http://otel.invalid:4318 \
    -v "$TMP/repo:/workspace" "$IMAGE" >/dev/null 2>&1 || true
for _ in $(seq 1 30); do docker logs "$OTELCN" 2>&1 | grep -q "started in tmux" && break; sleep 1; done
check "OpenTelemetry export composed + logged when enabled" \
    'docker logs "$OTELCN" 2>&1 | grep -q "OpenTelemetry .*: on"'
docker rm -f "$OTELCN" >/dev/null 2>&1 || true

echo
echo "== 12. SCM observer: baked + event extraction =="
# Two PRs: #7 failing CI (→ event), #8 healthy (→ no event). The `events`
# dry-run is a pure jq transform (no gh/workspace), so it runs in any container.
cat > "$TMP/scm.json" <<'JSON'
[ {"number":7,"title":"x","url":"u7","headRefOid":"h7","mergeable":"MERGEABLE","reviewDecision":"REVIEW_REQUIRED","statusCheckRollup":[{"conclusion":"FAILURE"}]},
  {"number":8,"title":"y","url":"u8","headRefOid":"h8","mergeable":"MERGEABLE","reviewDecision":"APPROVED","statusCheckRollup":[{"conclusion":"SUCCESS"}]} ]
JSON
check "claude-scm-observer baked + executable" \
    'cexec "test -x /usr/local/bin/claude-scm-observer"'
check "observer routes a failing-CI PR and skips a healthy one" \
    'out="$(docker exec -i "$CN" claude-scm-observer events < "$TMP/scm.json")"; grep -q "pr7-ci-h7" <<<"$out" && ! grep -q "pr8" <<<"$out"'

echo
echo "== 13. escape hardening applied (and still functional) =="
# The container booted with HARDEN_FLAGS in §4; everything above (boot, SSH §7,
# git §8) therefore already passed under the hardened profile. Assert the flags
# actually took effect on the container.
check "no-new-privileges is set on the container" \
    'docker inspect -f "{{.HostConfig.SecurityOpt}}" "$CN" | grep -q "no-new-privileges"'
check "dangerous default caps are dropped (NET_RAW / MKNOD not present)" \
    'caps="$(docker inspect -f "{{.HostConfig.CapAdd}}" "$CN")"; echo "$caps" | grep -q "CHOWN" && ! echo "$caps" | grep -qiE "NET_RAW|MKNOD"'
check "runC preflight flags this host as vulnerable or safe (runs without error)" \
    '(source "$REPO_ROOT/bin/_common.sh"; preflight_runc) >/dev/null 2>&1'

echo
echo "== 14. egress lockdown (opt-in) boots and enforces (or fails open) =="
check "claude-egress-firewall baked + executable" \
    'cexec "test -x /usr/local/bin/claude-egress-firewall"'
# Boot a lockdown container (needs NET_ADMIN). The KEY safety property is that
# lockdown never bricks boot: it either applies default-deny, or fails OPEN, the
# container must come up either way. If the network is reachable and lockdown
# engages, also assert a non-allowlisted IP is blocked.
EGHARDEN="$(source "$REPO_ROOT/bin/_common.sh"; CLAUDE_EGRESS_LOCKDOWN=1 harden_run_args)"
# shellcheck disable=SC2086
docker run -d --name "$EGCN" $EGHARDEN \
    -e CLAUDE_SKIP_AUTH_CHECK=1 -e CLAUDE_PROJECT_NAME=egress -e CLAUDE_EGRESS_LOCKDOWN=1 \
    -v "$TMP/repo:/workspace" "$IMAGE" >/dev/null 2>&1 || true
for _ in $(seq 1 60); do
    docker logs "$EGCN" 2>&1 | grep -qE "Egress lockdown" && break; sleep 1
done
check "lockdown container still boots (never bricks, default-deny or fail-open)" \
    'docker exec "$EGCN" gosu claude tmux has-session -t claude >/dev/null 2>&1'
check "lockdown either enforces default-deny or fails OPEN, never half-applied" \
    'p="$(docker exec "$EGCN" iptables -S OUTPUT 2>/dev/null | head -1)"; [ "$p" = "-P OUTPUT DROP" ] || [ "$p" = "-P OUTPUT ACCEPT" ]'
# Only meaningful when default-deny actually engaged (network was reachable):
if docker exec "$EGCN" iptables -S OUTPUT 2>/dev/null | head -1 | grep -q "DROP"; then
    check "default-deny blocks a non-allowlisted IP (1.1.1.1:443)" \
        '! docker exec "$EGCN" gosu claude curl -sS -m8 -o /dev/null https://1.1.1.1 2>/dev/null'
    check "default-deny still permits an allowlisted host (api.github.com)" \
        'c=$(docker exec "$EGCN" gosu claude curl -sS -m12 -o /dev/null -w "%{http_code}" https://api.github.com 2>/dev/null); [ -n "$c" ] && [ "$c" != 000 ]'
else
    echo "  SKIP  default-deny allow/deny checks (lockdown failed open, no network in test env)"
fi
docker rm -f "$EGCN" >/dev/null 2>&1 || true

echo
echo "== 14b. egress lockdown covers IPv6, on a network that actually routes it =="
# Section 14 runs on the default bridge, which hands out no routable IPv6 address, so it
# cannot see the family this section is about: a container there can be "default-deny"
# on IPv4 and have no IPv6 at all, and the checks above would look identical either way.
#
# Here the container gets a real IPv6 address on a throwaway ULA network, and the
# allow/deny pair is proved against TWO IDENTICAL PEERS on that same network, both the
# same image serving the same port. The only difference between them is whether their
# address is on the allowlist, so a passing deny check cannot be an offline test host
# and a passing allow check cannot be a hole. Nothing here needs IPv6 internet access.
#
# If this host's Docker cannot give the container a routable IPv6 address, every live
# check below is reported SKIPPED, never passed: a firewall test that silently degrades
# into a no-op is worse than no test at all.
EG6_OK=1
docker network create --ipv6 --subnet "$EG6SUBNET" "$EG6NET" >/dev/null 2>&1 || EG6_OK=0
if [[ "$EG6_OK" == 1 ]]; then
    docker run -d --name "$EG6ALLOW" --network "$EG6NET" --entrypoint python3 "$IMAGE" \
        -m http.server 80 --bind :: >/dev/null 2>&1 || EG6_OK=0
    docker run -d --name "$EG6DENY" --network "$EG6NET" --entrypoint python3 "$IMAGE" \
        -m http.server 80 --bind :: >/dev/null 2>&1 || EG6_OK=0
fi
# Each peer sits on exactly one network, so ranging over Networks yields its address.
eg6addr() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.GlobalIPv6Address}}{{end}}' "$1" 2>/dev/null || true; }
eg4addr() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1" 2>/dev/null || true; }
A6=""; A4=""; D6=""
if [[ "$EG6_OK" == 1 ]]; then
    A6="$(eg6addr "$EG6ALLOW")"; A4="$(eg4addr "$EG6ALLOW")"; D6="$(eg6addr "$EG6DENY")"
    [[ -n "$A6" && -n "$A4" && -n "$D6" ]] || EG6_OK=0
fi
if [[ "$EG6_OK" == 1 ]]; then
    # The allowlist carries the ALLOWED peer three ways: its container name (which the
    # network's embedded DNS resolves to both families) and its two literal addresses
    # (which getent returns as themselves). Any one of them is enough, and together they
    # keep this test off a single resolver behaviour. The IPv4 entry also keeps the IPv4
    # pass off its "resolved to zero IPs" fail-open path on an offline host, so what is
    # under test here is the IPv6 ruleset rather than the test host's internet. That path
    # is live and is reached by resolution alone: the published inbound ranges are folded
    # in after the guard, never before it, so they cannot stand in for an answer this
    # peer address is here to provide (test/egress-packages-unit.sh asserts both halves).
    # shellcheck disable=SC2086
    docker run -d --name "$EG6CN" $EGHARDEN --network "$EG6NET" \
        -e CLAUDE_SKIP_AUTH_CHECK=1 -e CLAUDE_PROJECT_NAME=egress6 -e CLAUDE_EGRESS_LOCKDOWN=1 \
        -e CLAUDE_EGRESS_EXTRA_HOSTS="$EG6ALLOW $A4 $A6" \
        -v "$TMP/repo:/workspace" "$IMAGE" >/dev/null 2>&1 || EG6_OK=0
    for _ in $(seq 1 90); do
        docker logs "$EG6CN" 2>&1 | grep -qE "Egress lockdown" && break; sleep 1
    done
fi

if [[ "$EG6_OK" != 1 ]]; then
    echo "  SKIP  live IPv6 default-deny check (this host's Docker gave the container no routable IPv6 address)"
    echo "  SKIP  live IPv6 allowlisted-host check (same reason)"
    echo "  SKIP  live IPv6 non-allowlisted drop check (same reason)"
    echo "  SKIP  live IPv6 agent-cannot-alter-the-rules check (same reason)"
elif ! docker exec "$EG6CN" ip6tables -S OUTPUT 2>/dev/null | head -1 | grep -q "DROP"; then
    # The IPv6 ruleset did not apply. That is a legal outcome (fail-open is the posture),
    # but the boot log then owes the operator the word UNRESTRICTED, so check THAT and
    # skip the live allow/deny pair rather than pretending it ran.
    echo "  SKIP  live IPv6 allow/deny checks (the IPv6 ruleset did not apply on this host)"
    check "an unapplied IPv6 ruleset is reported as UNRESTRICTED in the boot log, not as lockdown" \
        'docker logs "$EG6CN" 2>&1 | grep -q "Egress lockdown.*IPv6 UNRESTRICTED"'
else
    check "IPv6 OUTPUT policy is default-deny inside the locked-down container" \
        'p="$(docker exec "$EG6CN" ip6tables -S OUTPUT 2>/dev/null | head -1)"; [ "$p" = "-P OUTPUT DROP" ]'
    check "default-deny was in force BEFORE the agent started (the firewall precedes the tmux launch)" \
        'f="$(docker logs "$EG6CN" 2>&1 | grep -m1 -E "Egress lockdown|started in tmux")"; case "$f" in *"Egress lockdown"*) true ;; *) false ;; esac'
    check "the boot log reports BOTH families by name, default-deny on each" \
        'docker logs "$EG6CN" 2>&1 | grep -q "Egress lockdown.*IPv4 default-deny, IPv6 default-deny"'
    check "an ALLOWLISTED peer is still reachable over IPv6" \
        'c=$(docker exec "$EG6CN" gosu claude curl -6 -sS -m12 -o /dev/null -w "%{http_code}" "http://[$A6]/" 2>/dev/null); [ "$c" = 200 ]'
    check "a NON-allowlisted IPv6 destination is dropped (identical peer, identical port, only the allowlist differs)" \
        '! docker exec "$EG6CN" gosu claude curl -6 -sS -m8 -o /dev/null "http://[$D6]/" 2>/dev/null'
    # AC11 needs the agent's attempt to fail for the RIGHT reason. Resolve ip6tables as
    # root first and prove root can run it: then a failure as the claude user is the
    # missing NET_ADMIN, not a binary that is missing or off the unprivileged PATH.
    # `|| true` is load-bearing: this file runs under `set -e`, so an image with no
    # ip6tables would abort the entire smoke run here instead of failing this one check.
    IP6BIN="$(docker exec "$EG6CN" bash -lc 'command -v ip6tables' 2>/dev/null | tr -d '\r' || true)"
    check "ip6tables works for root in this container (so the agent's failures below are permission, not a missing binary)" \
        '[ -n "$IP6BIN" ] && docker exec "$EG6CN" "$IP6BIN" -S OUTPUT >/dev/null 2>&1'
    check "the unprivileged agent CANNOT flip the IPv6 OUTPUT policy (it holds no NET_ADMIN)" \
        '! docker exec "$EG6CN" gosu claude "$IP6BIN" -P OUTPUT ACCEPT 2>/dev/null'
    check "the unprivileged agent CANNOT flush the IPv6 OUTPUT chain" \
        '! docker exec "$EG6CN" gosu claude "$IP6BIN" -F OUTPUT 2>/dev/null'
    check "the unprivileged agent CANNOT delete the IPv6 allowlist rule it dislikes" \
        '! docker exec "$EG6CN" gosu claude "$IP6BIN" -D OUTPUT 1 2>/dev/null'
    check "the IPv6 rules are STILL in force after the agent's attempts to remove them" \
        'p="$(docker exec "$EG6CN" ip6tables -S OUTPUT 2>/dev/null | head -1)"; [ "$p" = "-P OUTPUT DROP" ]'
    check "the non-allowlisted IPv6 destination is STILL dropped after those attempts" \
        '! docker exec "$EG6CN" gosu claude curl -6 -sS -m8 -o /dev/null "http://[$D6]/" 2>/dev/null'
    check "the ALLOWLISTED peer is still reachable after those attempts (the rules were not merely flushed)" \
        'c=$(docker exec "$EG6CN" gosu claude curl -6 -sS -m12 -o /dev/null -w "%{http_code}" "http://[$A6]/" 2>/dev/null); [ "$c" = 200 ]'
fi
docker rm -f "$EG6CN" "$EG6ALLOW" "$EG6DENY" >/dev/null 2>&1 || true
docker network rm "$EG6NET" >/dev/null 2>&1 || true

echo
echo "== 14c. CLAUDE_EGRESS_LOCKDOWN=strict refuses to start the agent when the ruleset cannot be applied =="
# Section 14 pins the DEFAULT posture: lockdown never bricks boot, it applies or it
# fails OPEN, and the agent starts either way. `strict` is the opposite promise, for an
# operator running an agent on untrusted input: no ruleset, no agent. This section
# proves it on a live container, because the property that matters is not a log line,
# it is that nothing is reachable in the container afterwards.
#
# THE FAILURE IS FORCED BY WITHHOLDING NET_ADMIN, not by breaking the network: the same
# image and the same request, launched with the capability set an ordinary (non-lockdown)
# container gets, so the firewall cannot write a single rule. That reproduces on any
# host, online or offline, which a DNS-based failure would not.
EGNOCAP="$(source "$REPO_ROOT/bin/_common.sh"; CLAUDE_EGRESS_LOCKDOWN=0 harden_run_args)"
# shellcheck disable=SC2086
docker run -d --name "$EGSFCN" $EGNOCAP \
    -e CLAUDE_SKIP_AUTH_CHECK=1 -e CLAUDE_PROJECT_NAME=egress-strict -e CLAUDE_EGRESS_LOCKDOWN=strict \
    -v "$TMP/repo:/workspace" "$IMAGE" >/dev/null 2>&1 || true
eg_running() { docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false; }
for _ in $(seq 1 90); do
    [[ "$(eg_running "$EGSFCN")" == "true" ]] || break
    sleep 1
done
check "a strict container that cannot apply its ruleset does not stay up" \
    '[ "$(eg_running "$EGSFCN")" != true ]'
check "it exits NONZERO (the refusal is a failure, not a quiet clean stop)" \
    'c="$(docker inspect -f "{{.State.ExitCode}}" "$EGSFCN" 2>/dev/null || echo 0)"; [ "$c" != 0 ]'
# The log is MATERIALIZED once, and every assertion below greps the variable. This file
# runs under `pipefail`, where `docker logs ... | grep -q X` fails the PIPELINE on a
# MATCH (grep -q exits early, docker logs takes SIGPIPE 141): a test that reds at random.
# Reading it after the container has STOPPED is also the point of AC8: this is exactly
# what `claude-logs` shows an operator who comes back to a container that would not boot.
EGSF_LOG="$(docker logs "$EGSFCN" 2>&1 || true)"
check "its retrievable boot log names egress lockdown as the reason for the refusal" \
    'grep -q "ERROR: Egress lockdown" <<<"$EGSF_LOG"'
check "the refusal quotes the flag that caused it (CLAUDE_EGRESS_LOCKDOWN=strict)" \
    'grep -q "CLAUDE_EGRESS_LOCKDOWN=strict" <<<"$EGSF_LOG"'
# The whole point of strict. No agent, by the container's own account and by ours.
check "no agent session was ever announced (the tmux launch is never reached)" \
    '! grep -q "started in tmux" <<<"$EGSF_LOG"'
check "no agent session is reachable in that container" \
    '! docker exec "$EGSFCN" gosu claude tmux has-session -t claude >/dev/null 2>&1'
docker rm -f "$EGSFCN" >/dev/null 2>&1 || true

# The other half, and the one that would make strict useless if it broke: given the
# capability it needs, a strict container boots exactly like an on-spelling one.
# shellcheck disable=SC2086
docker run -d --name "$EGSOKCN" $EGHARDEN \
    -e CLAUDE_SKIP_AUTH_CHECK=1 -e CLAUDE_PROJECT_NAME=egress-strict-ok -e CLAUDE_EGRESS_LOCKDOWN=strict \
    -v "$TMP/repo:/workspace" "$IMAGE" >/dev/null 2>&1 || true
for _ in $(seq 1 90); do
    grep -qE "Egress lockdown" <<<"$(docker logs "$EGSOKCN" 2>&1 || true)" && break
    [[ "$(eg_running "$EGSOKCN")" == "true" ]] || break
    sleep 1
done
EGSOK_LOG="$(docker logs "$EGSOKCN" 2>&1 || true)"
if grep -q "Egress lockdown.*IPv4 default-deny" <<<"$EGSOK_LOG"; then
    check "a strict container whose ruleset APPLIES reaches a running agent session" \
        'docker exec "$EGSOKCN" gosu claude tmux has-session -t claude >/dev/null 2>&1'
    check "and it is the SAME default-deny ruleset the on spellings get" \
        'p="$(docker exec "$EGSOKCN" iptables -S OUTPUT 2>/dev/null | head -1)"; [ "$p" = "-P OUTPUT DROP" ]'
    check "the ruleset was in force BEFORE the agent started (the firewall precedes the tmux launch)" \
        'f="$(grep -m1 -E "Egress lockdown|started in tmux" <<<"$EGSOK_LOG")"; case "$f" in *"Egress lockdown"*) true ;; *) false ;; esac'
else
    # The ruleset could not be applied here either (no network in this test env, so the
    # allowlist resolved to nothing). That is not a reason to claim a pass: report the
    # applies-path as skipped and assert the refusal that DID happen instead, which is
    # still the strict contract.
    echo "  SKIP  strict-applies checks (the ruleset could not be applied in this environment)"
    check "a strict container that could not apply the ruleset refused here too (no agent session)" \
        '! docker exec "$EGSOKCN" gosu claude tmux has-session -t claude >/dev/null 2>&1'
fi
docker rm -f "$EGSOKCN" >/dev/null 2>&1 || true

echo
echo "== 14d. the allowlist is RE-RESOLVED on an interval, by a process the agent cannot reach =="
# Everything above pins the allowlist ONCE, at boot. This container is meant to run for
# weeks, and an IP-pinned allowlist is a snapshot: CDNs rotate, the rules end up pointing
# at addresses nobody serves, and the agent's tooling starts failing at a moment nobody is
# watching. CLAUDE_EGRESS_REFRESH_INTERVAL re-resolves and re-commits on a timer.
#
# THIS SECTION NEEDS A LIVE CONTAINER, which is why it is here and not in the unit suites:
# the unit suites prove the DECISIONS against a fake kernel, and what only a real container
# can show is that a second ruleset really commits into a running kernel and that the
# unprivileged agent can neither alter it nor stop the thing committing it. The interval is
# 10s so a refresh lands inside the life of a smoke run; an operator would use minutes.
#
# The log is materialized into a variable before every grep, for the pipefail/SIGPIPE
# reason spelled out in section 15 below.
# shellcheck disable=SC2086
docker run -d --name "$EGRFCN" $EGHARDEN \
    -e CLAUDE_SKIP_AUTH_CHECK=1 -e CLAUDE_PROJECT_NAME=egress-refresh -e CLAUDE_EGRESS_LOCKDOWN=1 \
    -e CLAUDE_EGRESS_REFRESH_INTERVAL=10 \
    -v "$TMP/repo:/workspace" "$IMAGE" >/dev/null 2>&1 || true
for _ in $(seq 1 60); do
    grep -qE "Egress refresh" <<<"$(docker logs "$EGRFCN" 2>&1 || true)" && break; sleep 1
done
EGRF_LOG="$(docker logs "$EGRFCN" 2>&1 || true)"
check "the boot log states the refresh posture it chose (an operator can read the interval back)" \
    'grep -qE "Egress refresh +:" <<<"$EGRF_LOG"'
check "a lockdown container still boots with a refresh configured (the feature never blocks the agent session)" \
    'docker exec "$EGRFCN" gosu claude tmux has-session -t claude >/dev/null 2>&1'

if grep -qE "Egress refresh +: every 10s" <<<"$EGRF_LOG"; then
    # Wait for a SECOND commit, on top of the boot one. The line names the family, so a
    # refresh that logged but committed nothing cannot pass this.
    for _ in $(seq 1 90); do
        grep -q "REFRESH: IPv4 allowlist re-resolved and the refreshed ruleset committed atomically" \
            <<<"$(docker logs "$EGRFCN" 2>&1 || true)" && break
        sleep 1
    done
    EGRF_LOG="$(docker logs "$EGRFCN" 2>&1 || true)"
    check "the allowlist is re-resolved and the refreshed ruleset is COMMITTED, atomically, after boot" \
        'grep -q "REFRESH: IPv4 allowlist re-resolved and the refreshed ruleset committed atomically" <<<"$EGRF_LOG"'
    check "the container is still default-deny after the refresh (a refresh never opens a family)" \
        'p="$(docker exec "$EGRFCN" iptables -S OUTPUT 2>/dev/null | head -1)"; [ "$p" = "-P OUTPUT DROP" ]'
    check "the refreshed ruleset still carries an allowlist (it re-committed the list, it did not seal the container)" \
        '[ "$(docker exec "$EGRFCN" iptables -S OUTPUT 2>/dev/null | grep -c -- "-d ")" -gt 0 ]'
    check "no refresh path ever failed open (the boot pass's posture is not this one's)" \
        '! grep -q "REFRESH:.*failing OPEN" <<<"$EGRF_LOG"'

    # --- AC11: the same privilege ownership as the boot pass -------------------------
    # The boot pass runs as root before the privilege drop, which is what makes its rules
    # unalterable from inside the session. A refresh that ran any other way would hand a
    # prompt-injected agent the one thing the whole design withholds.
    EGRF_PID="$(docker exec "$EGRFCN" cat /run/claude-egress/daemon.pid 2>/dev/null || true)"
    check "the refresh daemon is running, and it is running as root" \
        '[ -n "$EGRF_PID" ] && [ "$(docker exec "$EGRFCN" stat -c %u "/proc/$EGRF_PID" 2>/dev/null)" = 0 ]'
    check "the agent user cannot even read the refresh state directory (root-only, mode 700)" \
        '! docker exec "$EGRFCN" gosu claude cat /run/claude-egress/daemon.pid >/dev/null 2>&1'
    check "the agent user CANNOT stop the refresh (an unprivileged process cannot signal a root one)" \
        '! docker exec "$EGRFCN" gosu claude kill -TERM "$EGRF_PID" 2>/dev/null'
    check "and the refresh daemon is still alive after the agent tried" \
        'docker exec "$EGRFCN" test -d "/proc/$EGRF_PID"'
    check "the agent user CANNOT alter the refreshed ruleset (no NET_ADMIN, by construction)" \
        '! docker exec "$EGRFCN" gosu claude iptables -P OUTPUT ACCEPT 2>/dev/null'
    check "and the refreshed ruleset is still default-deny after the agent tried" \
        'p="$(docker exec "$EGRFCN" iptables -S OUTPUT 2>/dev/null | head -1)"; [ "$p" = "-P OUTPUT DROP" ]'
else
    # No network in this test environment, so the allowlist resolved to nothing and the
    # boot pass failed OPEN. It really does fail open here, and that is a property of the
    # script rather than an assumption of this branch: the guard counts what resolution
    # produced, and the published inbound ranges (which are a constant, not an answer)
    # are folded in only after it. A refresh over a container this same log reported as
    # UNRESTRICTED would silently seal it mid-session, so the correct behaviour is to
    # start nothing and say why. Assert THAT rather than claiming a pass.
    echo "  SKIP  live refresh checks (the boot ruleset could not be applied in this environment)"
    check "a boot pass that committed nothing starts no refresh, and the boot log says why" \
        'grep -qE "Egress refresh +: OFF \(the boot pass committed no ruleset" <<<"$EGRF_LOG"'
    check "and no refresh daemon is running in that container" \
        '! docker exec "$EGRFCN" test -e /run/claude-egress/daemon.pid'
fi
docker rm -f "$EGRFCN" >/dev/null 2>&1 || true

echo
echo "== 15. git-key handling: brokered BY DEFAULT, usable by the agent, not readable =="
# CC-11 flipped the default. Every container below is launched the way a real operator
# launches one, and the only difference between them is which explicit choice (if any)
# the operator recorded. §15a passes NO CLAUDE_BROKER_GIT_KEY at all: that is the case
# that used to hand the agent a readable deploy key.
#
# The deploy key's own PUBLIC half is mounted as authorized_keys, so the container's own
# sshd is a real ssh remote that only this key can open. That makes "git push actually
# works through the relay" provable with no network and no external host.
ssh-keygen -q -t ed25519 -f "$TMP/gitkey" -N ''
printf 'not-a-private-key\n' > "$TMP/badkey"      # non-empty, so §5 engages; unloadable, so the broker fails
GKPRIV="$(sed -n '2p' "$TMP/gitkey")"             # a base64 line of the PRIVATE key body
# Every assertion in this section reads its container's log through a HERE-STRING, never
# through `docker logs … | grep -q`. This file runs under `pipefail`, where `grep -q`
# exits on the first match, `docker logs` then takes SIGPIPE (141), and the PIPELINE fails
# BECAUSE THE STRING WAS FOUND. Whether it fires depends on how much log follows the
# matched line, so it shows up as assertions that pass or fail at random across runs and
# move whenever the boot log grows. Sections 14b, 14c and 5b already materialize the log
# for exactly this reason; this section now does the same.
logof()    { docker logs "$1" 2>&1 || true; }
loggrep()  { local cn="$1"; shift; grep "$@" <<<"$(logof "$cn")"; }
wait_boot() { for _ in $(seq 1 40); do loggrep "$1" -q "started in tmux" && return 0; sleep 1; done; return 1; }

# --- 15a. THE DEFAULT: no flag set at all -------------------------------------------
docker run -d --name "$BRKCN" -e CLAUDE_SKIP_AUTH_CHECK=1 -e CLAUDE_PROJECT_NAME=broker \
    -v "$TMP/repo:/workspace" -v "$TMP/gitkey.pub:/etc/claude/authorized_keys:ro" \
    -v "$TMP/gitkey:/etc/claude/git-key:ro" "$IMAGE" >/dev/null 2>&1 || true
wait_boot "$BRKCN" || true
brk()  { docker exec "$BRKCN" gosu claude bash -lc "$1"; }
brksh(){ docker exec "$BRKCN" gosu claude sh -c "$1"; }
check "broker engaged with NO operator flag set (key held in root ssh-agent)" \
    'loggrep "$BRKCN" -q "key broker.*root ssh-agent"'
check "the boot log STATES the key is not readable by the agent user" \
    'loggrep "$BRKCN" -q "Deploy key readable : NO"'
check "agent can USE the key (ssh-agent lists it via the relay)" \
    'grep -qE "ED25519|SHA256" <<<"$(brk "ssh-add -l" 2>/dev/null || true)"'
check "agent CANNOT read the private key (no readable key file)" \
    '! brk "test -e ~/.ssh/id_ed25519"'
check "no file ANYWHERE under the agent's home holds private key material" \
    '! brksh "grep -rq -- \"PRIVATE KEY\" /home/claude 2>/dev/null"'
check "the mounted key itself is root-only (the agent cannot read it off the mount)" \
    '! brksh "cat /etc/claude/git-key >/dev/null 2>&1"'

# THE POINT OF THE DEFAULT: containment that breaks git is containment nobody keeps.
# A real push, over ssh, signed by the brokered key, into a bare repo in the container.
check "git push over the mounted key SUCCEEDS on the default path (signed through the relay)" \
    'brk "git init -q --bare /home/claude/bare.git && git init -q /home/claude/src && cd /home/claude/src && GIT_AUTHOR_NAME=smoke GIT_AUTHOR_EMAIL=smoke@test GIT_COMMITTER_NAME=smoke GIT_COMMITTER_EMAIL=smoke@test git commit -q --allow-empty -m brokered && git remote add self claude@localhost:/home/claude/bare.git && git push -q self HEAD:refs/heads/smoke" >/dev/null 2>&1'
check "the pushed ref really landed (the relay signed a real authentication)" \
    'brk "git --git-dir=/home/claude/bare.git rev-parse --verify -q refs/heads/smoke" >/dev/null 2>&1'
check "the push used the relay socket, not a key file (SSH_AUTH_SOCK is the relay)" \
    'brk "echo \$SSH_AUTH_SOCK" 2>/dev/null | grep -q "/run/claude/agent.sock"'

# AC1, sub-clause 2: THE SSH-AGENT PROTOCOL. "List identities" is the only "give me the
# keys" question the protocol has, and it answers with public blobs by design. Assert on
# BYTES, not on a keyword: dump every response the agent user can obtain from the relay
# and prove the mounted key's own private material appears in none of them.
check "the agent-protocol identity query yields a PUBLIC key and no private bytes" \
    'o="$(brk "ssh-add -L; ssh-add -l" 2>&1)"; grep -q "ssh-ed25519" <<<"$o" \
     && ! grep -qiE "PRIVATE KEY|BEGIN OPENSSH" <<<"$o" && ! grep -qF "$GKPRIV" <<<"$o"'
check "agent CANNOT extract the key (ssh-add -L gives public only)" \
    '! brk "ssh-add -L 2>/dev/null | grep -qi PRIVATE"'
check "real ssh-agent socket is root-only (claude cannot reach it directly)" \
    '[ "$(docker exec "$BRKCN" stat -c %U /run/claude/agent-root.sock)" = root ] && ! brk "cat /run/claude/agent-root.sock" 2>/dev/null'

# AC1, sub-clause 3: PROCESS MEMORY. The key lives in a root-owned ssh-agent's address
# space. From the agent uid the kernel's own ptrace_may_access check must refuse
# /proc/<pid>/mem: not a convention, an EACCES.
BRKPID="$(docker exec "$BRKCN" pgrep -u root -x ssh-agent 2>/dev/null | head -1 || true)"
if [ -n "$BRKPID" ]; then
    check "the broker's ssh-agent runs as root, a different uid from the agent" \
        '[ "$(docker exec "$BRKCN" stat -c %U /proc/'"$BRKPID"')" = root ]'
    check "the agent user CANNOT read the broker's process memory (/proc/<pid>/mem denied)" \
        '! brksh "cat /proc/'"$BRKPID"'/mem >/dev/null 2>&1"'
    check "the denial is a permission error, not a missing file" \
        'grep -qiE "permission denied|operation not permitted" <<<"$(brksh "cat /proc/'"$BRKPID"'/mem 2>&1 >/dev/null" || true)"'
    check "the /proc surfaces the agent CAN read carry no private key bytes" \
        '! grep -qF "$GKPRIV" <<<"$(brksh "cat /proc/'"$BRKPID"'/cmdline /proc/'"$BRKPID"'/environ 2>/dev/null" || true)"'
else
    bad "could not find the broker's root ssh-agent process: the memory-isolation checks did not run"
fi
check "shared /auth credential master is locked to root (agent cannot list it)" \
    '[ "$(docker exec "$BRKCN" stat -c "%A %U" /auth)" = "drwx------ root" ] && ! brk "ls /auth" 2>/dev/null'
docker rm -f "$BRKCN" >/dev/null 2>&1 || true

# --- 15b. THE EXPLICIT OPT-OUT: today's readable file, unchanged ---------------------
docker run -d --name "$BRKOFFCN" -e CLAUDE_SKIP_AUTH_CHECK=1 -e CLAUDE_PROJECT_NAME=brokeroff \
    -e CLAUDE_BROKER_GIT_KEY=0 \
    -v "$TMP/repo:/workspace" -v "$TMP/gitkey.pub:/etc/claude/authorized_keys:ro" \
    -v "$TMP/gitkey:/etc/claude/git-key:ro" "$IMAGE" >/dev/null 2>&1 || true
wait_boot "$BRKOFFCN" || true
check "CLAUDE_BROKER_GIT_KEY=0 still installs the historical key file, agent-owned at mode 600" \
    '[ "$(docker exec "$BRKOFFCN" stat -c "%U %a" /home/claude/.ssh/id_ed25519)" = "claude 600" ]'
check "the opt-out path points ssh at that key file (an operator relying on it is unaffected)" \
    'docker exec "$BRKOFFCN" grep -q "IdentityFile ~/.ssh/id_ed25519" /home/claude/.ssh/config'
check "the opt-out boot log says plainly that the key IS readable by the agent user" \
    'loggrep "$BRKOFFCN" -q "Deploy key readable : YES"'
docker rm -f "$BRKOFFCN" >/dev/null 2>&1 || true

# --- 15c. FAIL CLOSED: brokering engaged, cannot be established ----------------------
# Same default launch, but the mounted "key" is unloadable, so ssh-add fails and the
# relay never comes up. Before CC-11 this fell through to `install ... id_ed25519`.
docker run -d --name "$BRKFAILCN" -e CLAUDE_SKIP_AUTH_CHECK=1 -e CLAUDE_PROJECT_NAME=brokerfail \
    -v "$TMP/repo:/workspace" -v "$TMP/gitkey.pub:/etc/claude/authorized_keys:ro" \
    -v "$TMP/badkey:/etc/claude/git-key:ro" "$IMAGE" >/dev/null 2>&1 || true
wait_boot "$BRKFAILCN" || true
check "a failed broker still lets the container BOOT (fail-closed must not brick the session)" \
    'loggrep "$BRKFAILCN" -q "started in tmux"'
check "a failed broker installs NO readable key file (the fail-open fallback is gone)" \
    '! docker exec "$BRKFAILCN" test -e /home/claude/.ssh/id_ed25519'
check "the failure is logged loudly and says it is NOT falling back to a readable key" \
    'loggrep "$BRKFAILCN" -q "NOT falling back to a readable key file"'
check "the failed-broker boot log still states the key's readability" \
    'loggrep "$BRKFAILCN" -q "Deploy key readable : NO"'
check "no relay socket and no IdentityFile are left behind" \
    '! docker exec "$BRKFAILCN" test -S /run/claude/agent.sock \
     && ! docker exec "$BRKFAILCN" grep -q IdentityFile /home/claude/.ssh/config'
check "git is left UNABLE to authenticate with that deploy key (ssh auth is refused)" \
    '! docker exec "$BRKFAILCN" gosu claude bash -lc "ssh -o BatchMode=yes -o ConnectTimeout=5 claude@localhost true" >/dev/null 2>&1'
docker rm -f "$BRKFAILCN" >/dev/null 2>&1 || true

# --- 15d. NO KEY MOUNTED: say so, claim nothing more, change nothing -----------------
docker run -d --name "$NOKEYCN" -e CLAUDE_SKIP_AUTH_CHECK=1 -e CLAUDE_PROJECT_NAME=nokey \
    -e GH_TOKEN=ghp_smoketestdummy \
    -v "$TMP/repo:/workspace" -v "$TMP/key.pub:/etc/claude/authorized_keys:ro" \
    "$IMAGE" >/dev/null 2>&1 || true
wait_boot "$NOKEYCN" || true
check "no key mounted -> the boot log says exactly that" \
    'loggrep "$NOKEYCN" -q "No git SSH key mounted"'
check "no key mounted -> no YES/NO readability is claimed about a key that does not exist" \
    '! loggrep "$NOKEYCN" -qE "Deploy key readable : (YES|NO)"'
check "no key mounted -> the readability line reads n/a (nothing is left to infer)" \
    'loggrep "$NOKEYCN" -q "Deploy key readable : n/a"'
check "no key mounted -> no key file, no ssh config and no relay are written" \
    '! docker exec "$NOKEYCN" test -e /home/claude/.ssh/id_ed25519 \
     && ! docker exec "$NOKEYCN" test -e /home/claude/.ssh/config \
     && ! docker exec "$NOKEYCN" test -e /run/claude/agent.sock'
check "no key mounted -> HTTPS git is unchanged: GH_TOKEN still wires gh in as the helper" \
    'loggrep "$NOKEYCN" -q "gh wired in as git credential helper"'
check "no key mounted -> the github.com HTTPS credential helper is really configured" \
    'grep -q "gh auth git-credential" <<<"$(docker exec "$NOKEYCN" gosu claude env HOME=/home/claude git config --global --get-all credential.https://github.com.helper 2>/dev/null || true)"'
docker rm -f "$NOKEYCN" >/dev/null 2>&1 || true

echo
echo "== 16. browser variant: MCP auto-enables, opt-out honored, loud on lean =="
# The real browser variant (make build-browser) bakes chromium + chrome-devtools-mcp.
# We don't need the ~200 MB image here: the entrypoint's §10b detection is purely
# "both binaries on PATH", so mounting two stub executables onto the LEAN image
# faithfully simulates the baked variant and exercises the auto-register logic in
# CI. (mcp add-json/get are local-config ops, no OAuth/network, so a stub that
# is never executed is sufficient; registration stores the config, it never spawns
# the server here.)
mkdir -p "$TMP/browserbin"
printf '#!/bin/sh\necho "Chromium 999.0 (smoke stub)"\n' > "$TMP/browserbin/chromium"
printf '#!/bin/sh\necho "chrome-devtools-mcp (smoke stub)"\n'  > "$TMP/browserbin/chrome-devtools-mcp"
chmod +x "$TMP/browserbin/chromium" "$TMP/browserbin/chrome-devtools-mcp"
STUB_MOUNTS=(
    -v "$TMP/browserbin/chromium:/usr/local/bin/chromium:ro"
    -v "$TMP/browserbin/chrome-devtools-mcp:/usr/local/bin/chrome-devtools-mcp:ro"
)
mcp_get() { docker exec "$1" gosu claude env CLAUDE_CONFIG_DIR=/home/claude/.claude HOME=/home/claude claude mcp get chrome-devtools >/dev/null 2>&1; }
wait_tmux() { for _ in $(seq 1 60); do docker logs "$1" 2>&1 | grep -q "started in tmux" && return 0; sleep 1; done; return 1; }
# Is $IMAGE itself the browser variant? (make build-browser sets claude.browser=1.)
# 16c/16d assert LEAN-image behavior, so they're skipped on a real browser image
# where the baked binaries would legitimately change the outcome.
IMG_IS_BROWSER="$(docker image inspect -f '{{ index .Config.Labels "claude.browser" }}' "$IMAGE" 2>/dev/null || echo 0)"

# --- 16a. AUTO: browser image, no CLAUDE_BROWSER flag -> self-registers -------
docker run -d --name "$BRWACN" -e CLAUDE_SKIP_AUTH_CHECK=1 -e CLAUDE_PROJECT_NAME=browserauto \
    "${STUB_MOUNTS[@]}" -v "$TMP/repo:/workspace" "$IMAGE" >/dev/null 2>&1 || true
wait_tmux "$BRWACN" || true
check "browser image auto-detected (no second flag needed)" \
    'docker logs "$BRWACN" 2>&1 | grep -qi "Browser image detected.*auto-registering"'
check "chrome-devtools MCP registered on a plain browser-image launch" \
    'docker logs "$BRWACN" 2>&1 | grep -q "Registered MCP server .chrome-devtools."'
# Proves the MCP is REGISTERED + discoverable in config (what frontend-debugging
# reads to see the tools), not that the server spawns. The stub is never
# executed and the config's --executablePath (/usr/bin/chromium) only exists on
# the real make-build-browser image; a live-server check belongs to the manual
# on-host run, not this stubbed CI simulation.
check "claude mcp get chrome-devtools succeeds (registered + discoverable in config)" \
    'mcp_get "$BRWACN"'
docker rm -f "$BRWACN" >/dev/null 2>&1 || true

# --- 16b. OPT-OUT: browser image + CLAUDE_BROWSER=0 -> not registered ---------
docker run -d --name "$BRWOCN" -e CLAUDE_SKIP_AUTH_CHECK=1 -e CLAUDE_PROJECT_NAME=browseroff \
    -e CLAUDE_BROWSER=0 "${STUB_MOUNTS[@]}" -v "$TMP/repo:/workspace" "$IMAGE" >/dev/null 2>&1 || true
wait_tmux "$BRWOCN" || true
check "explicit opt-out (CLAUDE_BROWSER=0) is honored on a browser image" \
    'docker logs "$BRWOCN" 2>&1 | grep -qi "chrome-devtools MCP disabled"'
check "opt-out leaves the chrome-devtools MCP unregistered" \
    '! mcp_get "$BRWOCN"'
docker rm -f "$BRWOCN" >/dev/null 2>&1 || true

# --- 16c. FORCE on a LEAN image (no stubs) -> loud, actionable, no silent op --
# Only meaningful on a lean image: on the real browser variant the baked binaries
# make the force succeed (correctly), so skip rather than false-fail.
if [ "$IMG_IS_BROWSER" = "1" ]; then
    echo "  SKIP  16c force-on-lean checks (\$IMAGE is the browser variant, not lean)"
else
    docker run -d --name "$BRWFCN" -e CLAUDE_SKIP_AUTH_CHECK=1 -e CLAUDE_PROJECT_NAME=browserforce \
        -e CLAUDE_BROWSER=1 -v "$TMP/repo:/workspace" "$IMAGE" >/dev/null 2>&1 || true
    wait_tmux "$BRWFCN" || true
    check "CLAUDE_BROWSER=1 on a non-browser image fails LOUD (ERROR, not a buried warn)" \
        'docker logs "$BRWFCN" 2>&1 | grep -q "ERROR: CLAUDE_BROWSER=1"'
    check "the loud failure is actionable (names the rebuild command)" \
        'docker logs "$BRWFCN" 2>&1 | grep -q "make build-browser"'
    check "no MCP is registered when the request cannot be satisfied (no silent op)" \
        '! mcp_get "$BRWFCN"'
    docker rm -f "$BRWFCN" >/dev/null 2>&1 || true
fi

# --- 16d. DEFAULT path: LEAN image, CLAUDE_BROWSER unset -> silent, no register
# The most common real-world launch. Reuse the §4 lean container ($CN): no stubs,
# no CLAUDE_BROWSER -> §10b's auto branch must find no binaries and do nothing
# (no registration, no "Browser image detected" log). Skip on a browser image,
# where unset correctly auto-registers.
if [ "$IMG_IS_BROWSER" = "1" ]; then
    echo "  SKIP  16d lean-default checks (\$IMAGE is the browser variant, not lean)"
else
    check "lean image + unset CLAUDE_BROWSER registers nothing (silent default)" \
        '! mcp_get "$CN"'
    check "lean image emits no false 'Browser image detected' log" \
        '! docker logs "$CN" 2>&1 | grep -qi "Browser image detected"'
fi

# --- 16e. LIVE: the registered MCP actually drives a real Chrome --------------
# 16a proves the MCP is REGISTERED. It cannot prove the browser LAUNCHES: the
# stubs are never executed. That gap hid a real outage: the pin was 0.x, which
# has no --chromeArg, so yargs SILENTLY dropped --no-sandbox, Chrome died with
# "No usable sandbox!", and every tool call returned "Target closed" while
# `claude mcp get` still reported "Connected". Registration checks are blind to
# it; only spawning the registered command and making a CDP round-trip is not.
# Needs the baked Chromium, so it runs only on the real browser variant.
if [ "$IMG_IS_BROWSER" != "1" ]; then
    echo "  SKIP  16e live browser checks (\$IMAGE is lean, no baked Chromium to drive)"
else
    docker run -d --name "$BRWLCN" -e CLAUDE_SKIP_AUTH_CHECK=1 -e CLAUDE_PROJECT_NAME=browserlive \
        -v "$TMP/repo:/workspace" "$IMAGE" >/dev/null 2>&1 || true
    wait_tmux "$BRWLCN" || true
    # Read the REGISTERED command/args back out of the config and spawn exactly
    # those, so the test exercises what a session really runs, not a copy of it.
    docker exec -i "$BRWLCN" gosu claude tee /home/claude/mcp-live-probe.mjs >/dev/null <<'PROBE'
import {spawn} from 'node:child_process';
import {readFileSync} from 'node:fs';
const cfg = JSON.parse(readFileSync('/home/claude/.claude/.claude.json', 'utf8'));
const s = (cfg.mcpServers ?? {})['chrome-devtools'];
if (!s) { console.error('no chrome-devtools server registered'); process.exit(1); }
const p = spawn(s.command, s.args ?? [], {env: {...process.env, ...(s.env ?? {})}});
p.on('error', e => { console.error('spawn failed: ' + e.message); process.exit(1); });
const send = o => p.stdin.write(JSON.stringify(o) + '\n');
let buf = '';
p.stdout.on('data', d => {
  buf += d;
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line) continue;
    let m;
    try { m = JSON.parse(line); } catch { continue; }
    if (m.id !== 2) continue;
    const text = (m.result?.content ?? []).map(c => c.text).join(' ').replace(/\n/g, ' ');
    if (m.result && !m.result.isError) { console.log('OK: ' + text); process.exit(0); }
    console.error('tool call failed: ' + text);   // e.g. "Target closed"
    process.exit(1);
  }
});
send({jsonrpc: '2.0', id: 1, method: 'initialize', params: {protocolVersion: '2024-11-05', capabilities: {}, clientInfo: {name: 'smoke', version: '1'}}});
setTimeout(() => {
  send({jsonrpc: '2.0', method: 'notifications/initialized'});
  send({jsonrpc: '2.0', id: 2, method: 'tools/call', params: {name: 'list_pages', arguments: {}}});
}, 1500);
setTimeout(() => { console.error('timed out waiting for list_pages'); process.exit(1); }, 60000);
PROBE
    check "registered chrome-devtools MCP really launches Chrome (live CDP round-trip)" \
        'docker exec "$BRWLCN" gosu claude node /home/claude/mcp-live-probe.mjs'
    # Pins the exact regression: --chromeArg must EXIST, or --no-sandbox is dropped.
    check "pinned chrome-devtools-mcp supports --chromeArg (launch flags not silently dropped)" \
        'docker exec "$BRWLCN" gosu claude chrome-devtools-mcp --help 2>&1 | grep -q -- "--chromeArg"'
    docker rm -f "$BRWLCN" >/dev/null 2>&1 || true
fi

# --- 16f. Disk-backed scratch (TMPDIR) ----------------------------------------
# /tmp is a 1g tmpfs in RAM. Anything honoring TMPDIR (pip/uv wheel builds, docker
# save|load, the inner containerd) hits that wall and ENOSPCs while the pool has terabytes
# free, so temp must land on a disk-backed volume instead.
#
# Needs its OWN container: the scratch volume + TMPDIR are supplied by claude-launch, not
# baked into the image, so $CN (a bare `docker run` above) has neither. Reproduce the
# launcher's two flags exactly, then assert the IMAGE does its half: prepare the dir and
# re-export TMPDIR for login shells.
SCRCN="claude-smoke-scratch-$$"
SCRVOL="claude-smoke-scratch-vol-$$"
docker volume create "$SCRVOL" >/dev/null 2>&1 || true
docker run -d --name "$SCRCN" -e CLAUDE_SKIP_AUTH_CHECK=1 -e CLAUDE_PROJECT_NAME=scratchsmoke \
    -e TMPDIR=/scratch -v "$SCRVOL:/scratch" \
    --tmpfs /tmp:rw,nosuid,nodev,exec,size=1g \
    -v "$TMP/repo:/workspace" "$IMAGE" >/dev/null 2>&1 || true
wait_tmux "$SCRCN" || true

check "the entrypoint reports preparing the disk-backed scratch dir" \
    'docker logs "$SCRCN" 2>&1 | grep -qi "Scratch (TMPDIR)"'
check "the agent's TMPDIR points at /scratch, not the tmpfs" \
    '[ "$(docker exec "$SCRCN" gosu claude sh -c "echo \$TMPDIR")" = "/scratch" ]'
# Guard against a vacuous pass: /scratch must EXIST and be a real mount, not resolve to /.
check "/scratch is a mounted volume and is NOT a tmpfs" \
    'docker exec "$SCRCN" sh -c "mountpoint -q /scratch" && ! docker exec "$SCRCN" findmnt -no FSTYPE /scratch | grep -q tmpfs'
# The actual user-visible bug: a write bigger than the whole tmpfs must now succeed.
check "a 1200MB write (larger than the entire 1g tmpfs) succeeds in TMPDIR" \
    'docker exec "$SCRCN" gosu claude sh -c "dd if=/dev/zero of=\$TMPDIR/big bs=1M count=1200 2>/dev/null && rm -f \$TMPDIR/big"'
# sshd builds a FRESH environment, so a login shell must re-export it: otherwise an
# interactive `pip install` fails where the agent's own identical command succeeds.
check "an SSH-style login shell (cleared env) also gets the disk-backed TMPDIR" \
    '[ "$(docker exec "$SCRCN" gosu claude env -i /bin/bash -lc "echo \$TMPDIR")" = "/scratch" ]'
# It is scratch, not state: a volume survives restart, so stale files must be cleared on boot
# or abandoned wheel builds accumulate until the pool fills.
docker exec "$SCRCN" sh -c 'touch /scratch/stale-from-last-boot' >/dev/null 2>&1 || true
docker restart "$SCRCN" >/dev/null 2>&1 || true
wait_tmux "$SCRCN" || true
check "scratch is cleared on boot (a volume does not self-empty like a tmpfs)" \
    '! docker exec "$SCRCN" test -e /scratch/stale-from-last-boot'
docker rm -f "$SCRCN" >/dev/null 2>&1 || true
docker volume rm "$SCRVOL" >/dev/null 2>&1 || true

# --- 17. Container workflows (--docker): the agent can actually build + run ----
# The end-to-end proof, and the only one that matters: an UNPRIVILEGED agent inside the
# session builds an image and runs a container, with no --privileged and no host socket.
# Gated twice, because both halves are genuinely optional:
#   - the image must have the engine baked (claude.docker LABEL / WITH_DOCKER=1)
#   - the HOST must have the Sysbox runtime (CI runners do not)
# A skip here is honest: it says the case was not exercised, rather than passing vacuously.
IMG_IS_DOCKER="$(docker image inspect -f '{{ index .Config.Labels "claude.docker" }}' "$IMAGE" 2>/dev/null || echo 0)"
HOST_HAS_SYSBOX=0
docker info --format '{{range $r, $_ := .Runtimes}}{{$r}} {{end}}' 2>/dev/null | grep -qw sysbox-runc && HOST_HAS_SYSBOX=1

if [ "$IMG_IS_DOCKER" != "1" ]; then
    echo "  SKIP  17 container-workflow checks (\$IMAGE has no baked engine, build with WITH_DOCKER=1)"
elif [ "$HOST_HAS_SYSBOX" != "1" ]; then
    echo "  SKIP  17 container-workflow checks (host has no sysbox-runc runtime, nested Docker cannot be exercised)"
else
    DKCN="claude-smoke-docker-$$"
    docker run -d --name "$DKCN" --runtime=sysbox-runc --security-opt no-new-privileges \
        -e CLAUDE_SKIP_AUTH_CHECK=1 -e CLAUDE_PROJECT_NAME=dockersmoke -e CLAUDE_DOCKER=1 \
        -v "$TMP/repo:/workspace" "$IMAGE" >/dev/null 2>&1 || true
    wait_tmux "$DKCN" || true

    check "the inner dockerd starts and reports ready" \
        'docker logs "$DKCN" 2>&1 | grep -q "Inner dockerd.*ready"'
    # The container must NOT be privileged and must NOT see the host socket. If either of
    # these ever flips, the isolation story is gone regardless of what else passes.
    check "the container is NOT privileged" \
        '[ "$(docker inspect -f "{{.HostConfig.Privileged}}" "$DKCN")" = "false" ]'
    check "no host docker socket is mounted into it" \
        '! docker inspect -f "{{range .Mounts}}{{.Source}}{{end}}" "$DKCN" | grep -q "docker.sock"'
    # Sysbox's userns is the whole mechanism: container-root must map to a NON-zero host uid.
    check "container-root maps to an unprivileged host uid (Sysbox userns is active)" \
        'docker exec "$DKCN" cat /proc/self/uid_map | awk "{exit !(\$2 != 0)}"'
    # gosu, not `docker exec -u`: exec does not apply supplementary groups, so it would
    # report a false failure here. gosu is how the entrypoint actually starts the agent.
    check "the unprivileged agent is in the docker group (can reach the socket)" \
        'docker exec "$DKCN" gosu claude id -nG | grep -qw docker'
    check "the agent BUILDS an image" \
        'docker exec "$DKCN" gosu claude sh -c "cd /tmp && printf \"FROM alpine\nRUN echo ok > /p\n\" > Dockerfile && docker build -q -t smoke:1 . >/dev/null"'
    check "the agent RUNS a container from it" \
        'docker exec "$DKCN" gosu claude docker run --rm smoke:1 cat /p | grep -q ok'
    check "docker compose is available to the agent" \
        'docker exec "$DKCN" gosu claude docker compose version >/dev/null 2>&1'
    # Teardown regression: an inner container still running must not wedge removal. Before
    # the entrypoint's TERM trap stopped the inner daemon, `docker rm -f` failed with
    # "did not receive an exit event" and aborted claude-rm mid-purge, stranding volumes.
    docker exec "$DKCN" gosu claude docker run -d --name linger alpine sleep 300 >/dev/null 2>&1 || true
    check "the container stops cleanly even with a live inner container (no wedged teardown)" \
        'docker stop -t 25 "$DKCN" >/dev/null 2>&1 && docker rm -f "$DKCN" >/dev/null 2>&1'
    docker rm -f "$DKCN" >/dev/null 2>&1 || true
fi

echo
echo "==============================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==============================================="
echo "Manual checks still required (need real OAuth + phone):"
echo "  - make login   persists creds to the claude-auth volume"
echo "  - the session shows in the Claude mobile app Code tab, green dot"
echo "  - --dangerously-skip-permissions applies under Remote Control"
echo "    (send a shell task from the app; it should run with no prompt)"
echo "  - healthcheck flips to (healthy) once Claude is authed and connected;"
echo "    the RC watchdog restarts the session if the RC link drops"
[[ "$FAIL" -eq 0 ]]
