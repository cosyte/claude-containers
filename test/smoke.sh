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
BRKCN="claude-smoke-broker-$$"
BRWACN="claude-smoke-browser-auto-$$"
BRWOCN="claude-smoke-browser-off-$$"
BRWFCN="claude-smoke-browser-force-$$"
AUTHVOL="claude-smoke-auth-$$"
WSVOL="claude-smoke-ws-$$"
PASS=0 FAIL=0

cleanup() {
    docker rm -f "$CN" "$OTELCN" "$EGCN" "$BRKCN" "$BRWACN" "$BRWOCN" "$BRWFCN" >/dev/null 2>&1 || true
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
# No CLAUDE_MODEL was passed, so the entrypoint must default to opus (best available).
check "entrypoint defaults the model to opus (best available)" \
    'grep -qE "Model[[:space:]]*: opus" <<<"$(docker logs "$CN" 2>&1)"'

# --- the CLI pin, checked against the RUNNING IMAGE (CC-CLAUDE-CODE-UPGRADE) --------
# test/cli-version-unit.sh proves the six *declarations* of the pin agree, but it is
# pure-static — it reads repo files and never the built image. These are the live half:
# the image you are actually about to run really ships the pinned CLI, and really is at
# or above the Opus-4.8 floor. A stale gitignored .env silently overrides the repo's pin
# (the Makefile's `-include .env` beats `?=` AND the Dockerfile ARG), so without a check
# against the real image a host can keep shipping an old CLI — and `--model opus` keeps
# silently resolving to Opus 4.7 — with every other gate green.
PINNED_VER="$(sed -n 's/^ARG CLAUDE_CODE_VERSION=\(.*\)$/\1/p' "$(dirname "${BASH_SOURCE[0]}")/../Dockerfile")"
OPUS48_FLOOR=2.1.154
check "image ships the pinned Claude Code CLI ($PINNED_VER)" \
    '[[ "$(cexec "claude --version" 2>/dev/null | awk "{print \$1}")" == "$PINNED_VER" ]]'
check "the CLI in the image clears the Opus-4.8 floor ($OPUS48_FLOOR — else '--model opus' means 4.7)" \
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
echo "== 15. git-key brokering: usable by the agent, not readable =="
# Mount a throwaway deploy key and broker it. The agent must be able to USE it
# (ssh-agent lists it) but never READ the private bytes.
ssh-keygen -q -t ed25519 -f "$TMP/gitkey" -N ''
docker run -d --name "$BRKCN" -e CLAUDE_SKIP_AUTH_CHECK=1 -e CLAUDE_PROJECT_NAME=broker \
    -e CLAUDE_BROKER_GIT_KEY=1 \
    -v "$TMP/repo:/workspace" -v "$TMP/key.pub:/etc/claude/authorized_keys:ro" \
    -v "$TMP/gitkey:/etc/claude/git-key:ro" "$IMAGE" >/dev/null 2>&1 || true
for _ in $(seq 1 40); do docker logs "$BRKCN" 2>&1 | grep -q "started in tmux" && break; sleep 1; done
brk() { docker exec "$BRKCN" gosu claude bash -lc "$1"; }
check "broker engaged (key held in root ssh-agent)" \
    'docker logs "$BRKCN" 2>&1 | grep -q "key broker.*root ssh-agent"'
check "agent can USE the key (ssh-agent lists it via the relay)" \
    'brk "ssh-add -l" 2>/dev/null | grep -qE "ED25519|SHA256"'
check "agent CANNOT read the private key (no readable key file)" \
    '! brk "test -e ~/.ssh/id_ed25519"'
check "agent CANNOT extract the key (ssh-add -L gives public only)" \
    '! brk "ssh-add -L 2>/dev/null | grep -qi PRIVATE"'
check "real ssh-agent socket is root-only (claude cannot reach it directly)" \
    '[ "$(docker exec "$BRKCN" stat -c %U /run/claude/agent-root.sock)" = root ] && ! brk "cat /run/claude/agent-root.sock" 2>/dev/null'
check "shared /auth credential master is locked to root (agent cannot list it)" \
    '[ "$(docker exec "$BRKCN" stat -c "%A %U" /auth)" = "drwx------ root" ] && ! brk "ls /auth" 2>/dev/null'
docker rm -f "$BRKCN" >/dev/null 2>&1 || true

echo
echo "== 16. browser variant: MCP auto-enables, opt-out honored, loud on lean =="
# The real browser variant (make build-browser) bakes chromium + chrome-devtools-mcp.
# We don't need the ~200 MB image here: the entrypoint's §10b detection is purely
# "both binaries on PATH", so mounting two stub executables onto the LEAN image
# faithfully simulates the baked variant and exercises the auto-register logic in
# CI. (mcp add-json/get are local-config ops — no OAuth/network — so a stub that
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
# reads to see the tools) — not that the server spawns. The stub is never
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

# --- 16e. Disk-backed scratch (TMPDIR) ----------------------------------------
# /tmp is a 1g tmpfs in RAM. Anything honoring TMPDIR (pip/uv wheel builds, docker
# save|load, the inner containerd) hits that wall and ENOSPCs while the pool has terabytes
# free — so temp must land on a disk-backed volume instead.
#
# Needs its OWN container: the scratch volume + TMPDIR are supplied by claude-launch, not
# baked into the image, so $CN (a bare `docker run` above) has neither. Reproduce the
# launcher's two flags exactly, then assert the IMAGE does its half — prepare the dir and
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
# sshd builds a FRESH environment, so a login shell must re-export it — otherwise an
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
    echo "  SKIP  17 container-workflow checks (\$IMAGE has no baked engine — build with WITH_DOCKER=1)"
elif [ "$HOST_HAS_SYSBOX" != "1" ]; then
    echo "  SKIP  17 container-workflow checks (host has no sysbox-runc runtime — nested Docker cannot be exercised)"
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
