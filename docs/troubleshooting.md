# Troubleshooting

`claude-logs <name>` shows the entrypoint/sshd log (startup, clone, MCP
registration). For the live Claude session, SSH in and you attach to tmux.

## Auth

**`make login` shows a URL but no browser opens.** Expected — it's headless.
Copy the URL to a browser on any machine, sign in with your **Max** account,
paste the code back into the terminal. Credentials persist to the `claude-auth`
volume; you only do this once.

**Container exits immediately with "No credentials in the claude-auth volume".**
Run `make login` before launching. Verify:
`docker run --rm -v claude-auth:/auth alpine ls -l /auth/.credentials.json`.

**"ANTHROPIC_API_KEY is set" and the container refuses to start.** Intentional.
Remove `ANTHROPIC_API_KEY` from `.env` and your shell. This image is
subscription-OAuth only; an API key would silently bill per token.

**Logged in but sessions say unauthenticated.** The credential reconcile loop
converges `/auth` and the per-container copy every ~30s. If you just ran
`make login` while a container was already up, restart it
(`claude-stop`/`claude-launch`) so it re-seeds immediately. Re-auth from
scratch: `docker volume rm claude-auth && make login`.

## Remote Control session not in the mobile app

### "Remote Control is not yet enabled for your account" (most common)

This message is almost always **misleading** — it usually does NOT mean your
account lacks Remote Control. Remote Control eligibility is the GrowthBook
feature flag `tengu_ccr_bridge`, fetched at startup. If Claude Code's telemetry
fetch is suppressed, that flag is never retrieved and falls back to its `false`
default, producing this exact error even on a fully eligible Max/Pro account.
This is documented by Anthropic and reported in 50+ upstream issues.

The killers, in order of likelihood:

1. **`DISABLE_TELEMETRY`, `DO_NOT_TRACK`, or `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`**
   set anywhere — env, or `~/.claude/settings.json` `env` block. Any truthy
   value makes Claude Code skip GrowthBook entirely. **This image deliberately
   does not set them**; the entrypoint also self-heals older per-container
   volumes (strips them from settings.json and clears the stale flag cache).
   Verify inside a container:
   `jq .env /home/claude/.claude/settings.json` and `env | grep -E 'TELEMETRY|DO_NOT_TRACK|NONESSENTIAL'` — all should be absent.
2. **Stale flag cache.** Removing the var isn't enough on its own — the old
   evaluation is frozen. Clear it and re-fetch:
   `jq 'del(.cachedGrowthBookFeatures,.cachedExperimentFeatures)' ~/.claude/.claude.json` (write back), `rm -rf ~/.claude/statsig`, then run any prompt (`claude -p ping`) to repopulate. Confirm `jq -r '.cachedGrowthBookFeatures.tengu_ccr_bridge' ~/.claude/.claude.json` is `true`.
3. **Wrong auth type.** RC needs a full-scope `claude auth login` session token.
   An inference-only `CLAUDE_CODE_OAUTH_TOKEN` / `claude setup-token`, or
   `ANTHROPIC_API_KEY` / `CLAUDE_CODE_USE_BEDROCK|VERTEX|FOUNDRY`, disqualifies
   it. This image uses subscription OAuth and refuses API keys, so this only
   bites if you override auth.
4. Diagnose precisely with `claude remote-control --verbose` inside the
   container — it prints which condition failed.

After a rebuild + container recreate (below), all four are handled
automatically. If `tengu_ccr_bridge` is *still* `false` with a clean env,
cleared cache, and full-scope login, you're in the genuine minority server-side
rollout/entitlement-sync case (upstream issues #34528/#37003) — no client fix;
contact Anthropic.

### Session present but not showing

1. Needs Claude Code ≥ 2.1.52 (this image pins 2.1.144). Confirm in
   `claude-logs <name>` ("Claude Code session 'claude' started in tmux").
2. Remote Control is **outbound HTTPS only** — no inbound port. If egress is
   firewalled/allowlisted, the session can't register. Temporarily allow
   outbound 443 and check the app.
3. The app session name is the (sanitized) project name. Look in the **Code**
   tab; green dot = the `claude` process is running. No dot → SSH in, check the
   tmux pane; relaunch with `claude-session` if it dropped to a shell.
4. The app must be signed into the **same account** used for `make login`.

## Remote Control link drops mid-session (`(unhealthy)`, watchdog)

A session that registered fine can still lose its Remote Control link later.
Claude Code's RC bridge (a v2 SSE transport) reconnects on a **bounded retry
budget**; once that budget is exhausted the link is permanently dead with no
recovery — the mobile/web app shows the session offline while the local
`claude` process keeps running, apparently healthy. Upstream bug —
anthropics/claude-code#34255 (also \#29726).

The image handles this with two pieces:

- **Healthcheck (`claude-healthcheck`)** — the Docker `HEALTHCHECK` probe. It
  checks liveness (sshd, the tmux session, the `claude --remote-control`
  process) *and* reads the RC debug log for the bridge's terminal give-up
  (`recovery exhausted after …` / `notifyBridgeFailed`). A silently dropped
  link therefore shows as `(unhealthy)` in `docker ps` and in the `claude-list`
  STATUS column — not only an outright crash.
- **RC watchdog (`claude-rc-watchdog`)** — a background process started by the
  entrypoint. It tails the same log; on a confirmed dead link it waits for the
  claude pane to go idle (so an in-flight turn is never cut off), then respawns
  the pane with `claude-session --continue`. The Remote Control name is
  unchanged, so the app reconnects on its own within ~30s and the conversation
  is preserved.

**What you'll see.** `claude-list` shows `Up … (unhealthy)` briefly, then the
watchdog restarts the session and it returns to `(healthy)`. `claude-logs
<name>` carries the watchdog's `[rc-watchdog]` lines explaining each decision.

**Tuning / disabling** (env vars, set at `claude-launch`):

- `CLAUDE_RC_WATCHDOG=0` — disable the watchdog entirely (the healthcheck still
  reports `(unhealthy)`, but nothing auto-recovers).
- `CLAUDE_RC_CHECK_INTERVAL` (30s), `CLAUDE_RC_IDLE_SECONDS` (45s),
  `CLAUDE_RC_COOLDOWN` (180s), `CLAUDE_RC_MAX_RESTARTS` (10) — poll cadence, the
  idle window a pane must hold before a restart, the minimum gap between
  restarts, and the consecutive-failure limit after which the watchdog stops.
- `CLAUDE_RC_DEBUG_LOG` — path of the RC debug log (default
  `/tmp/claude-rc-debug.log`). Set it empty to turn off RC logging, which also
  disables drop detection — liveness checks still run.

**Watchdog gave up (`MAX_RESTARTS` reached).** The link stayed dead across
every restart, so this is no longer a transient bridge drop — treat it as a
registration failure. Work through the "Remote Control session not in the
mobile app" section above, and run `claude remote-control --verbose` in the
container to see which condition fails.

## `--dangerously-skip-permissions` with Remote Control

There were earlier reports that skip-permissions didn't fully apply under
Remote Control. On the pinned 2.1.144, `remote-control --permission-mode`
explicitly accepts `bypassPermissions`, the launch passes
`--dangerously-skip-permissions --remote-control`, and `settings.json` also
sets `permissions.defaultMode=bypassPermissions` +
`skipDangerousModePermissionPrompt`. So unattended operation works.

**Verify end to end:** from the mobile app, send a task that needs a shell
command (e.g. "run `ls /` and show output"). It should execute with no approval
prompt. If a future Claude Code version prompts anyway:

- Set `CLAUDE_PERMISSION_MODE=acceptEdits` in `.env` and relaunch. Edits
  auto-apply; shell commands prompt in the app (you tap approve). Safer, still
  usable remotely.
- Or pin back to a known-good `CLAUDE_CODE_VERSION` and rebuild.

## Git auth failures

- `Permission denied (publickey)` on push/clone: the host `GIT_SSH_KEY`
  (`~/.ssh/claude-git-key` by default) doesn't exist, wasn't mounted, or isn't
  authorized on the remote. `claude-launch` warns if the file is missing.
  Generate one (`ssh-keygen -t ed25519 -f ~/.ssh/claude-git-key`) and add the
  `.pub` as a deploy key / to your git account.
- Inside the container the key is copied to `~/.ssh/id_ed25519` (0600, owned by
  `claude`) because SSH rejects keys readable via a shared mount. Confirm:
  `ssh -p <port> claude@host 'ssh -T git@github.com'`.
- Public/https repos clone fine with no key.
- Wrong commit author: set `GIT_AUTHOR_NAME`/`GIT_AUTHOR_EMAIL` in `.env`
  (otherwise the host's `git config --global` is used).

## SSH connection refused / closed

- `claude-launch` warns and disables SSH if no `authorized_keys` was found at
  `SSH_AUTHORIZED_KEYS`. Point it at a file containing your public key and
  relaunch. (Remote Control still works without SSH.)
- Wrong port: `claude-list` shows the assigned port; `claude-launch <name>`
  reprints the connect line. Ports are auto-assigned in 2200–2299.
- Host key changed after `docker volume rm claude-sshkeys`: clear the stale
  entry with `ssh-keygen -R "[host]:<port>"`.
- Connects then immediately closes: that's the tmux attach exiting because the
  Claude pane died. SSH in again — you'll get a shell (remain-on-exit);
  relaunch with `claude-session`, or check `claude-logs`.

## Workspace trust prompt appears

The entrypoint pre-accepts trust by seeding `.claude.json`. If you still get
the dialog, the per-container config volume didn't mount (check
`docker inspect <ctr>` for the `/home/claude/.claude` mount) or `/workspace`
isn't the path Claude opened. As a one-off, accept it once — it persists in the
config volume.

## Frontend debugging (`--browser` / `CLAUDE_BROWSER=1`)

The `--browser` flag registers the official
[`chrome-devtools-mcp`](https://github.com/ChromeDevTools/chrome-devtools-mcp)
server inside the container, so Claude can navigate, evaluate, screenshot,
inspect console/network, run Lighthouse, and capture perf/heap traces against
any frontend the agent runs.

- **`--browser` warns "image not built with WITH_BROWSER=1".** The default
  image is lean — Chromium and the MCP are only baked when you opt in. Build
  the variant:
  ```
  make build-browser            # tags claude-code-box:browser
  CLAUDE_IMAGE=claude-code-box:browser ./bin/claude-launch myproj --browser …
  ```
  Or `make build WITH_BROWSER=1 CLAUDE_IMAGE=mytag` for a custom tag. Set
  `CLAUDE_IMAGE` in `.env` so every launch uses the browser variant by default.
- **The MCP is registered but Chrome won't start in Claude.** Verify the
  binary chain inside the container:
  ```
  ssh -p <port> claude@host 'chromium --version && chrome-devtools-mcp --help | head -5'
  ```
  Both must succeed. If `chromium` is missing, the image was built without
  `WITH_BROWSER=1`.
- **"Failed to launch the browser process".** Almost always sandbox/seccomp.
  The entrypoint already passes `--chromeArg=--no-sandbox
  --chromeArg=--disable-dev-shm-usage --chromeArg=--disable-gpu` to
  `chrome-devtools-mcp`, which is what containers need. If you're on a host
  with extremely restrictive seccomp (e.g. some hardened Kubernetes), relax
  the seccomp profile for the container or expose `--cap-add=SYS_ADMIN`.
- **Run it manually as `claude` to see real errors:**
  ```
  ssh -p <port> claude@host '
    chrome-devtools-mcp --executablePath /usr/bin/chromium \
      --headless --isolated --chromeArg=--no-sandbox \
      <<<"{}"; echo exit=$?'
  ```
- **The flag is per-session.** SSH remotes / on-disk state aren't affected; if
  you stop and `claude-launch <name>` resumes, the MCP registration is in the
  per-container config volume and persists across restarts.

## Container restart-loops

`claude-launch` surfaces the last 30 log lines if startup fails. Common causes:
bad `GIT_REPO_URL`/branch, missing auth volume, unreadable mounted key. Fix the
cause, then `claude-rm <name>` and relaunch (or `docker start` after fixing a
mount).

## Changed `.env` but a resumed container ignores it

`claude-launch <name>` on a *stopped* container runs `docker start`, which
reuses the container's creation-time environment, port mappings, and mounts.
Editing `.env` (or passing new `--repo`/`--port`/`--expose`/`--dev-cmd`) has no
effect on resume — `claude-launch` prints a warning when it sees options it
must ignore. To apply the new values, recreate the container:
`claude-rm <name>` (add `--purge` to also drop the workspace/config volumes),
then `claude-launch <name> …` again.

## Restricting egress

Egress is open by default — Claude Code, npm, pip, git and MCP servers all need
outbound. To lock down a paranoid setup, attach the container to an `internal`
Docker network plus a proxy/firewall that allows only:

- `api.anthropic.com`, `claude.ai`, `*.anthropic.com`, `cdn.growthbook.io`
  (API + Remote Control + the feature-flag fetch RC eligibility depends on)
- `registry.npmjs.org`, your git host, any MCP server hosts you enable

Easiest is a host firewall (nftables) or an egress proxy with
`HTTPS_PROXY`/`HTTP_PROXY` set in `.env`. Blocking everything else still leaves
SSH (inbound) and Remote Control (outbound 443) working. **Never set
`DISABLE_TELEMETRY`, `DO_NOT_TRACK`, or `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`**
— each disables the GrowthBook fetch that resolves the `tengu_ccr_bridge`
Remote Control gate, breaking RC with a misleading "not yet enabled for your
account" (see the Remote Control section above). The image and entrypoint
deliberately avoid them.

## Performance / OOM

This image installs Claude Code via npm (not the native installer), avoiding
the historical startup filesystem scan that OOM'd containers. If a container is
still memory-starved, raise `CLAUDE_MEM_LIMIT`. Builds in `/workspace` honor
`CLAUDE_CPU_LIMIT`/`CLAUDE_MEM_LIMIT`.
