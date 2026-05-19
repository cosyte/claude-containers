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

1. Needs Claude Code ≥ 2.1.52 (this image pins 2.1.144). Confirm in
   `claude-logs <name>` ("Claude Code session 'claude' started in tmux").
2. Remote Control is **outbound HTTPS only** — no inbound port. If egress is
   firewalled/allowlisted, the session can't register. Temporarily allow
   outbound 443 and check the app.
3. The app session name is the (sanitized) project name. Look in the **Code**
   tab; green dot = the `claude` process is running. No dot → SSH in, check the
   tmux pane; relaunch with `claude-session` if it dropped to a shell.
4. The account in the app must be the same Max account used for `make login`.

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

## Container restart-loops

`claude-launch` surfaces the last 30 log lines if startup fails. Common causes:
bad `GIT_REPO_URL`/branch, missing auth volume, unreadable mounted key. Fix the
cause, then `claude-rm <name>` and relaunch (or `docker start` after fixing a
mount).

## Restricting egress

Egress is open by default — Claude Code, npm, pip, git and MCP servers all need
outbound. To lock down a paranoid setup, attach the container to an `internal`
Docker network plus a proxy/firewall that allows only:

- `api.anthropic.com`, `claude.ai`, `*.anthropic.com` (API + Remote Control)
- `registry.npmjs.org`, your git host, any MCP server hosts you enable

Easiest is a host firewall (nftables) or an egress proxy with
`HTTPS_PROXY`/`HTTP_PROXY` set in `.env`. Blocking everything else still leaves
SSH (inbound) and Remote Control (outbound 443) working. Don't set
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` — it can disable the Remote Control
eligibility check.

## Performance / OOM

This image installs Claude Code via npm (not the native installer), avoiding
the historical startup filesystem scan that OOM'd containers. If a container is
still memory-starved, raise `CLAUDE_MEM_LIMIT`. Builds in `/workspace` honor
`CLAUDE_CPU_LIMIT`/`CLAUDE_MEM_LIMIT`.
