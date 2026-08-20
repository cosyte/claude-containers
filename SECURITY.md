# Security

## Reporting a vulnerability

Report privately: **do not open a public issue**.

Use [GitHub private vulnerability reporting](https://github.com/cosyte/claude-containers/security/advisories/new)
(Security → Report a vulnerability), that is the channel that reaches the
maintainer directly. If it is unavailable to you, email `hello@cosyte.com` with
`SECURITY: claude-containers` in the subject.

Please include the version or commit, your host OS and Docker/runc versions, the
flags or env vars in play, and the smallest reproduction you can manage. A first
response should come within a few working days; this is a small project, so
please allow for that.

Report to the right party: a flaw in **Claude Code itself**, in the Claude
mobile app, or in the Anthropic API belongs to
[Anthropic](https://www.anthropic.com/responsible-disclosure), not here. This
repo is the container that runs Claude Code, not Claude Code.

## What this project's security model actually claims

Read this before filing: several plausible-sounding reports are documented
non-goals rather than defects.

**A container is not a security boundary against a fully weaponized agent.**
This is the load-bearing statement. The stack runs an autonomous agent that
executes shell commands, often with `--dangerously-skip-permissions`. Everything
below shrinks the blast radius of a *prompt-injected or misbehaving* agent. None
of it is a claim that a determined attacker who achieves code execution inside
the container cannot get further. **The single highest-leverage control is a
patched host runtime**: the launcher warns when host runC is older than
1.2.8 / 1.3.3 (CVE-2025-31133 / -52565 / -52881).

What the stack does enforce, and therefore what a bypass of *is* a valid report:

- **No `--privileged`, and no host Docker socket mount, ever.** Nested Docker
  (`--docker`) runs under Sysbox so the inner daemon's root maps to an
  unprivileged host uid. A path that obtains host root is in scope.
- **Capability floor.** `--security-opt no-new-privileges`, plus (default)
  dropping all Linux capabilities and re-adding only the minimal set for sshd
  and privilege-dropping: `NET_RAW`, `MKNOD` and `SETFCAP` are removed.
- **Credential isolation.** The shared `claude-auth` credential master is
  root-owned; the agent reaches only its own per-container session token.
  By default the git deploy key lives in a root-owned `ssh-agent` and the agent
  gets a signing socket only, so it cannot read the private key bytes; only an
  explicit `CLAUDE_BROKER_GIT_KEY=0` opts out to a readable key file, and a
  broker that fails to come up installs no key file rather than falling back.
  A path by which the unprivileged agent reads the master credential or the raw
  private key is in scope.
- **Egress lockdown** (`CLAUDE_EGRESS_LOCKDOWN=1`) is enforced in netfilter,
  default-deny, IP-pinned, applied at boot before the agent starts and while it
  is still unprivileged, so the agent cannot disable its own rules. A path that
  does is in scope. Note it **fails open by design**: if setup fails it logs
  loudly and leaves egress unrestricted rather than bricking connectivity.
- **Secret guard** installs a git pre-commit hook blocking obvious secret
  material. It is a backstop against an agent committing a credential, not a
  DLP control; `--no-verify` bypasses it by design.

Known and accepted, so **not** vulnerabilities in this project:

- **`ANTHROPIC_API_KEY` is refused**: the entrypoint hard-fails if it is set.
  That is deliberate billing protection, not a bug.
- **Anyone who can read the `claude-auth` Docker volume can act as you.** It
  holds live OAuth credentials. Protect it with host permissions.
- **The SSH port publishes on `0.0.0.0`** by default, so it is LAN-reachable.
  Auth is pubkey-only; set `CLAUDE_SSH_BIND=127.0.0.1` to limit it.
- **All containers share one SSH host key** (stable fingerprint), acceptable for
  a single-owner host. Use distinct keys if that matters to you.
- **Egress is open by default.** Lockdown is opt-in.
- **An IP-pinned allowlist goes stale** as CDNs rotate addresses, and
  `statsig.anthropic.com` is not publicly resolvable so it cannot be pinned.
- **Under `--docker` the agent can reach root inside its own container**, that
  is what a Docker socket is. Sysbox keeps that root off the host. The launcher
  warns that `CLAUDE_BROKER_GIT_KEY` and `CLAUDE_EGRESS_LOCKDOWN` assume root is
  separate from the agent and therefore no longer bind in that mode.

The full threat model: including the weaponized-agent supply-chain exfil case
the package-provisioning tier is built against: is in
[docs/package-provisioning-security.md](docs/package-provisioning-security.md).

## Supported versions

There are no releases. `main` is the supported version; fixes land there. The
`legacy/sysbox-broker-2026-07-12` branch is a frozen historical artifact,
retained for reference and **not maintained or patched**: see
[docs/legacy-sysbox-broker.md](docs/legacy-sysbox-broker.md).
