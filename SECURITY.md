# Security Policy

## Reporting a vulnerability

**Please do not report security vulnerabilities through public GitHub issues,
discussions, or pull requests.**

Use GitHub's private vulnerability reporting: go to the repository's
**Security** tab → **Report a vulnerability** (Privately report a security
vulnerability). This opens a private advisory visible only to you and the
maintainers.

Please include:

- a description of the issue and its impact,
- the version / commit you tested,
- reproduction steps or a proof of concept,
- any suggested remediation.

We aim to acknowledge a report within a few days and to keep you updated as we
work on a fix. Coordinated disclosure is appreciated — give us a reasonable
window to ship a fix before any public write-up.

## Supported versions

This project is distributed from source; there is no separate backport branch.
Security fixes land on `main` and in the latest release. Run a recent `main`
or the newest tagged release.

## Scope

In scope: anything that lets a session escape its container, leak credentials
or another session's workspace, weaken the SSH surface, or defeat the
no-API-key / authentication guarantees below.

Out of scope: vulnerabilities in upstream dependencies that already have a
public advisory (report those upstream — Docker, Node.js, Claude Code,
OpenSSH, etc.), and risks inherent to running an unattended agent with
`bypassPermissions` in a repository you control (this is the documented,
opt-in design — see `docs/architecture.md`).

## Design guarantees worth knowing

These are intentional properties; a way to break one is a valid report.

- **No API-key billing path.** The entrypoint hard-fails if
  `ANTHROPIC_API_KEY` is set, and `bin/claude-launch` refuses to pass it.
  Authentication is OAuth (Claude Max subscription) only.
- **Credentials are never baked into the image.** OAuth tokens live in a
  Docker named volume; the git SSH key and `authorized_keys` are mounted
  read-only from the host at runtime; MCP secrets come from `.env` at runtime
  via `envsubst`, never committed and never in an image layer.
- **SSH is hardened.** Key-only auth, no passwords, no root login, single
  allowed user (see `sshd_config`).
- **One container = one session = one workspace.** Sessions do not share a
  workspace; only the OAuth-credential volume is shared (by design, so token
  refreshes converge).

Note: this stack is meant for a trusted single-operator host (e.g. a homelab).
Anyone who can reach the published SSH port with the authorized key, or who
can run `docker` on the host, has full access to every session — treat host
and key access accordingly.
