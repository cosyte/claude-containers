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
TMP="$(mktemp -d)"
CN="claude-smoke-$$"
AUTHVOL="claude-smoke-auth-$$"
WSVOL="claude-smoke-ws-$$"
PASS=0 FAIL=0

cleanup() {
    docker rm -f "$CN" >/dev/null 2>&1 || true
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
# GH_TOKEN here also exercises the entrypoint's git credential-helper
# wiring — a dummy value is fine, gh auth setup-git never validates it
# (asserted in section 8).
docker run -d --name "$CN" \
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
echo "==============================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==============================================="
echo "Manual checks still required (need real OAuth + phone):"
echo "  - make login   persists creds to the claude-auth volume"
echo "  - the session shows in the Claude mobile app Code tab, green dot"
echo "  - --dangerously-skip-permissions applies under Remote Control"
echo "    (send a shell task from the app; it should run with no prompt)"
[[ "$FAIL" -eq 0 ]]
