# Claude Code container

Self-hosted Docker image for running multiple isolated, long-lived Claude Code
sessions on a homelab box. One container = one session = one git repo, reachable
two ways at once: SSH into a persistent tmux session, and the Claude mobile
app's Remote Control (Code tab).

Auth is your Claude **Max** subscription via OAuth. No API keys: the entrypoint
hard-fails if `ANTHROPIC_API_KEY` is set so you never accidentally bill per
token.

> **Unofficial project.** Not affiliated with, endorsed by, or supported by
> Anthropic. "Claude" and "Claude Code" are Anthropic's trademarks and are used
> here only to say what this runs. It installs the published
> `@anthropic-ai/claude-code` CLI at a pinned version; your use of Claude Code
> and of your Claude subscription remains subject to Anthropic's own terms.
> Report Claude Code bugs to Anthropic, not here.
> **Retired:** the nested-Sysbox worker broker (`--broker`/`--sysbox`) and the
> per-session Docker engine (`--docker`); their flags refuse with an error. Background:
> [docs/legacy-sysbox-broker.md](docs/legacy-sysbox-broker.md).

## Quick start

```bash
cp .env.example .env          # edit if you want; defaults are sane
make build                    # builds the image for this host's arch
make login                    # one-time OAuth: opens a URL, you paste a code
./bin/claude-launch first-project --repo git@github.com:you/first-project.git
```

`claude-launch` prints the exact SSH command and the name to look for in the
app. SSH in and you're dropped straight into the running Claude session:

```
ssh -p 2200 claude@your-homelab
```

Open the Claude mobile app → Code tab → `first-project` has a green dot.

Stop and resume later without losing the workspace or conversation history:

```bash
./bin/claude-stop  first-project
./bin/claude-launch first-project       # resumes; no --repo needed
```

Run as many in parallel as you like: each gets its own SSH port and app
session. `./bin/claude-list` shows them all. Put `bin/` on your `PATH` to drop
the `./bin/` prefix.

## How it works

`claude-launch` runs a container per project: the entrypoint refuses an API key, starts
sshd, merges the baked-in config, clones or reuses `/workspace`, then runs Claude Code
in tmux with Remote Control. Credentials live in one shared volume (one login, every
container); config, workspace, scratch and state are per container. Diagram and design:
[docs/architecture.md](docs/architecture.md).

`/cache` is shared by every container on the host, all as one user, so anything in it is
readable from every container. An app's private state (a database, a key, a token) goes
in `/state/<app>`, the container's own volume, which no other container mounts, and so do
worktrees, clones and working folders that must last (`/state/wt`, `/state/tmp`):
[docs/volume-reference.md](docs/volume-reference.md#private-state).

## Commands

On the host (`bin/`), full flags in [docs/launcher-commands.md](docs/launcher-commands.md):

| Command | What it does |
|---|---|
| `claude-launch <name> [--repo URL]` | create or resume a container; prints the SSH line |
| `claude-list [--json]` | every container, its port, sessions, image and how far behind `main` |
| `claude-attach <name> [session]` | attach to its tmux session |
| `claude-stop <name>` | graceful stop, state kept |
| `claude-rm <name> [--purge]` | remove (and its volumes with `--purge`) |
| `claude-logs <name>` | the entrypoint/sshd log |
| `claude-sessions -C <name> CMD` | manage the sessions inside a container |
| `claude-compose-gen` | a compose stack for many repos at once |
| `claude-account-login <name>` / `claude-account-list` | log an account into a volume / show who is on which |
| `claude-image-rebuild [--check]` | is the image behind `main`; without `--check`, pull and rebuild |
| `claude-tui` | a menu over all of the above |

Inside a container: `claude-sessions`, `claude-gpu`, `claude-kit status`,
`claude-enqueue`.

## Most-used variables

Set in `.env` (auto-loaded by the scripts and passed into containers); real env vars
override it. Every variable: [docs/environment-variables.md](docs/environment-variables.md)
and `.env.example`.

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDE_IMAGE` | `claude-code-box:latest` | Image tag built/run |
| `CLAUDE_CODE_VERSION` | `2.1.293` | Pinned Claude Code npm version (min 2.1.52); auto-update stays on unless `DISABLE_AUTOUPDATER=1` |
| `CLAUDE_MODEL` | `opus` | Model the session runs, passed to `--model` verbatim (`opus` is the latest Opus on the pinned CLI). Per-container via `claude-launch --model` |
| `CLAUDE_PERMISSION_MODE` | `bypassPermissions` | `acceptEdits`/`auto`/`bypassPermissions`/`manual`/`dontAsk`/`plan`; `acceptEdits` is the safer fleet posture |
| `GIT_REPO_URL`/`_BRANCH`/`_DEPTH` |: | Clone source (or use `--repo`/`--branch`/`--depth`) |
| `GIT_AUTHOR_NAME`/`_EMAIL` (+`COMMITTER`) | host git config | Commit identity |
| `GH_TOKEN` | unset | GitHub token for `gh` and HTTPS git in every session: [docs/github-token.md](docs/github-token.md) |
| `GIT_SSH_KEY` | `~/.ssh/claude-git-key` | Host SSH key for git, mounted read-only and brokered. For git alone: never in `SSH_AUTHORIZED_KEYS` (the launch tools refuse that, and sshd in the container refuses it for logins) |
| `SSH_AUTHORIZED_KEYS` | `~/.ssh/authorized_keys` | Your own public keys allowed to SSH in (read-only), never the git key's |
| `CLAUDE_CPU_LIMIT`/`CLAUDE_MEM_LIMIT` | `2`/`4g` | Per-container resource caps |
| `CLAUDE_EGRESS_LOCKDOWN` | `0` | `1` = default-deny egress firewall, fail-open; `strict` = fail-closed. Extend with `CLAUDE_EGRESS_EXTRA_HOSTS` |
| `ANTHROPIC_API_KEY` | unset | **Must stay unset**: entrypoint hard-fails otherwise |

## Docs

| Topic | Doc |
|---|---|
| Architecture, design decisions, acceptance | [docs/architecture.md](docs/architecture.md) |
| Every environment variable | [docs/environment-variables.md](docs/environment-variables.md) |
| Every command and flag, `claude-compose-gen` | [docs/launcher-commands.md](docs/launcher-commands.md) |
| Volumes and mounts, private `/state` | [docs/volume-reference.md](docs/volume-reference.md) |
| Several repos in one container | [docs/multi-repo.md](docs/multi-repo.md) |
| Several sessions in one container | [docs/sessions.md](docs/sessions.md) |
| Changing the Claude account | [docs/account-switching.md](docs/account-switching.md) |
| Install a kit (plugins) at session start | [docs/kits.md](docs/kits.md) |
| Customizing the baked-in config | [docs/customizing-bakeins.md](docs/customizing-bakeins.md) |
| GPU sessions | [docs/gpu-sessions.md](docs/gpu-sessions.md) |
| Frontend debugging (browser image) | [docs/frontend-debugging.md](docs/frontend-debugging.md) |
| Unattended autopilot | [docs/unattended-autopilot.md](docs/unattended-autopilot.md) |
| GitHub token | [docs/github-token.md](docs/github-token.md) |
| Temp space: `/scratch`, not `/tmp` | [docs/temp-space.md](docs/temp-space.md) |
| Toolchains on demand (`mise`) | [docs/toolchains-on-demand.md](docs/toolchains-on-demand.md) |
| Toolchain provisioning, shared tool cache (design) | [docs/toolchain-provisioning.md](docs/toolchain-provisioning.md), [docs/shared-tool-cache.md](docs/shared-tool-cache.md) |
| Package provisioning security | [docs/package-provisioning-security.md](docs/package-provisioning-security.md) |
| Security notes, managed settings, egress allowlist | [docs/security-notes.md](docs/security-notes.md), [docs/managed-settings.md](docs/managed-settings.md), [docs/egress-allowlist.md](docs/egress-allowlist.md) |
| Troubleshooting | [docs/troubleshooting.md](docs/troubleshooting.md) |
| The retired Sysbox broker | [docs/legacy-sysbox-broker.md](docs/legacy-sysbox-broker.md) |

## Contributing, security, licence

- **Contributing:** [CONTRIBUTING.md](CONTRIBUTING.md), the gates are
  `make lint` + `npm test` (both Docker-free, both what CI runs); the image smoke
  test runs in CI's `smoke` job when an image path changes (`make smoke` locally
  is optional).
- **Security:** [SECURITY.md](SECURITY.md). Report privately, never in an issue.
  Read the model first: **a container is not a security boundary against a fully
  weaponized agent**, and several plausible reports are documented non-goals.
- **Licence:** [MIT](LICENSE).
- **Support:** none promised. This is self-hosted infrastructure published as-is
  in case it is useful; issues are read, but there is no SLA and no release
  cadence: `main` is the version.
