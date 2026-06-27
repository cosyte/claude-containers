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
AUTHVOL="claude-smoke-auth-$$"
WSVOL="claude-smoke-ws-$$"
PASS=0 FAIL=0

cleanup() {
    docker rm -f "$CN" "$OTELCN" "$EGCN" >/dev/null 2>&1 || true
    docker volume rm "$AUTHVOL" "$WSVOL" >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT

ok()   { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "== image: $IMAGE =="
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "image missing — build first"; exit 1; }

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
       --cpu alpha=7 --mem alpha=777m --browser beta acme/alpha acme/beta >/dev/null 2>&1; then
    # Extract exactly one service's block (its `^  name:` header to the next
    # service or top-level key) so assertions don't depend on line offsets — the
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
else
    bad "claude-compose-gen failed to generate with --cpu/--mem/--browser"
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
# unhealthy — assert only that it executes cleanly and emits a verdict line.
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
# lockdown never bricks boot: it either applies default-deny, or fails OPEN — the
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
check "lockdown container still boots (never bricks — default-deny or fail-open)" \
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
    echo "  SKIP  default-deny allow/deny checks (lockdown failed open — no network in test env)"
fi
docker rm -f "$EGCN" >/dev/null 2>&1 || true

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
