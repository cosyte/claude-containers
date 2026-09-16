## Security notes

- **`--dangerously-skip-permissions` is the default.** The container is
  isolated from the host (separate fs, non-root `claude` user, resource caps),
  but the agent has free rein *inside* it: it can run any command and push to
  any repo its mounted key can reach. Treat each container as a blast radius of
  one repo. For a production fleet against real repos, set
  `CLAUDE_PERMISSION_MODE=acceptEdits` (in-project edits auto-approved, shell/
  network still gated): now honored by **both** the interactive session and
  autopilot, not just the app prompt.
- **Policy the session cannot rewrite.** The settings this image asserts as
  *policy* (`permissions.defaultMode`, `skipDangerousModePermissionPrompt`) are
  delivered to
  `/etc/claude-code/managed-settings.json`, which Claude Code reads above every
  other settings level and which `root` owns, written before the agent process
  starts. A session that rewrites or empties its own
  `~/.claude/settings.json` does not change them. `includeCoAuthoredBy` stays a
  preference and is deliberately not managed. The boot log's `Managed policy`
  line names exactly which settings are managed, or says policy is **NOT
  ENFORCED** and why: it reports the file on disk, so it never claims enforcement
  it does not have and never denies one it does, and it never refuses a boot.
  Change the policy from the host by setting `CLAUDE_PERMISSION_MODE`, by mounting
  your own file onto that path (the image never overwrites one it did not write),
  or by turning this image's own delivery off with `CLAUDE_MANAGED_POLICY=0`
  (which cannot remove a file you mounted yourself). Turning bypass mode off outright
  (`permissions.disableBypassPermissionsMode`) is available at this path and is
  deliberately **not** set by this image: that call is the operator's. Full
  guide: [docs/managed-settings.md](managed-settings.md).
- **Secret guard (on by default).** A fleet-wide git pre-commit hook
  (`CLAUDE_SECRET_GUARD=1`) blocks the autonomous agent from committing obvious
  secrets: `.env`, `*.pem`, `*.key`, `id_rsa`, files containing a `PRIVATE KEY`
  block: before they can be pushed with the mounted key. Bypass a deliberate
  file once with `git commit --no-verify`; extend the deny-list via
  `CLAUDE_SECRET_GUARD_EXTRA`; disable with `CLAUDE_SECRET_GUARD=0`. The hook
  chains to a repo's own `pre-commit` so existing project hooks still run.
- **Escape hardening + the honest blast radius.** Each container runs with
  `--security-opt no-new-privileges` and, by default (`CLAUDE_HARDEN_CAPS=1`),
  `--cap-drop ALL` plus a minimal re-add: removing the Docker-default `NET_RAW`,
  `MKNOD`, and `SETFCAP` a compromised agent would reach for. The launcher also
  **warns if the host runC is older than 1.2.8 / 1.3.3** (the Nov-2025 escape
  CVEs CVE-2025-31133/52565/52881): patching the host runtime is the single
  highest-leverage control, because **a container is not a security boundary
  against a fully weaponized agent** (AWS says as much of its own runtime). These
  controls shrink blast radius but do **not** by themselves contain the secrets
  the agent can reach: see secret brokering below. For an untrusted-input /
  multi-tenant threat model, also run a microVM runtime (gVisor/Kata) rather than
  relying on container isolation alone.
- **Every flat session gets resource + disk hygiene.** `--memory-reservation` +
  `--pids-limit` cap every session; `claude-disk-gc --loop` (a standalone tool,
  run it by hand or on your own cron/timer) prunes dangling images/containers/
  networks **and** the build cache (`docker system prune -f` + `docker builder
  prune -f`) without ever touching a running container or a volume, and trims the
  shared `/cache` volume's re-fetchable download caches when it exceeds
  `CLAUDE_CACHE_MAX_MIB`. Docker-free logic tests: `test/disk-unit.sh`,
  `test/sizing-unit.sh` (CI); one-command sanity pass: `bin/claude-disk-verify`.
  (A nested-Sysbox worker-broker substrate used to run alongside this, a
  root-owned broker spawning autonomous nested workers with a K-aware resource
  envelope and a per-launch disk-pressure refusal. It is retired; see
  [docs/legacy-sysbox-broker.md](legacy-sysbox-broker.md).)
- **Secret brokering (git key + credentials).** By default the SSH deploy key is
  loaded into a **root-owned `ssh-agent`** and only a signing socket is exposed
  to the agent (via a root `socat` relay): git still pushes, but the
  unprivileged, prompt-injectable agent can never read the key bytes, not from a
  file, the agent protocol, the socket, or root's `/proc/<pid>/mem`. You do not
  have to know a flag exists to get that. `CLAUDE_BROKER_GIT_KEY=0` is the
  explicit opt-out back to a `claude`-readable `~/.ssh/id_ed25519`, and it is the
  only value that produces one: unset brokers, `1`/`true`/`yes`/`on` brokers, and
  an unrecognised value brokers too, so a typo cannot silently downgrade
  containment. If the agent/relay cannot be established the boot **fails closed**:
  no key file is installed, git is left unable to authenticate with that key, and
  the failure is logged loudly (a failed push is recoverable, an exfiltrated
  deploy key is not). Whichever path runs, the boot log carries a
  `Deploy key readable :` line saying in plain language whether the agent user
  can read the key right now. **Upgrading:** an existing `.env` copied from an
  older `.env.example` carries a literal `CLAUDE_BROKER_GIT_KEY=0` line, which is
  read as the explicit opt-out and keeps the old readable-file behaviour: delete
  that line to pick up brokering. The shared **`claude-auth` credential master is always**
  locked to `root` (`/auth`, mode 700), so the agent can't reach the token that
  backs the rest of the fleet; it only ever holds its **own** per-container
  session token, which is unavoidable (Claude Code authenticates with it, and a
  Max subscription has no scopable API key). Rotate the master with
  `docker volume rm claude-auth` + `make login`.
- **Egress lockdown (opt-in).** `CLAUDE_EGRESS_LOCKDOWN=1` applies a default-deny
  iptables firewall at boot: as root, before the agent starts and while it's
  still unprivileged, so a prompt-injected agent can neither exfiltrate to
  arbitrary hosts nor disable its own egress rules. Enforcement is at the network
  layer on a pinned IP allowlist, because the research that motivated this found
  Claude Code's own app-layer allowlist was bypassable (a SOCKS5 null-byte parser
  differential) and SNI/CONNECT proxy allowlists are evadable by domain fronting.
  The baked allowlist covers the Claude API, OAuth, the Remote Control feature
  flags (`statsig.*`/`growthbook.*`, blocking those breaks RC), npm, GitHub
  (via its published IP ranges) and Anthropic's own published **inbound** ranges;
  extend with `CLAUDE_EGRESS_EXTRA_HOSTS`. It adds ~10s to boot and the
  `NET_ADMIN` cap. On the `1`/`true`/`yes`/`on` spellings it
  **fails open** (logs loudly, leaves egress unrestricted) rather than bricking
  connectivity, and that is still the default posture. Every host Claude Code's
  published network requirements name is either pinned or recorded, with a reason,
  in [docs/egress-allowlist.md](egress-allowlist.md), including the wildcard
  entries an IP allowlist can never admit: those are named in the boot log
  together with the feature they cost, rather than left to fail silently. Caveat:
  `statsig.anthropic.com` isn't publicly resolvable so it can't be pinned:
  re-verify if RC eligibility fails.
- **Keeping the allowlist current (`CLAUDE_EGRESS_REFRESH_INTERVAL`).** A pinned
  address is a snapshot, and a container that runs for weeks outlives it: set the
  variable to a number of seconds (`900` is a reasonable start) and the same
  allowlist is re-resolved on that interval and re-committed, as root, through the
  same atomic restore the boot pass used. The agent has no `NET_ADMIN` and cannot
  signal a root process, so it can neither alter the refreshed rules nor stop the
  refresh. **A failed lookup never narrows the allowlist**: a host that previously
  resolved and now comes back empty retains the ruleset already in force and is
  logged by name, because an empty answer under a live session is evidence about
  the resolver rather than about the host, and a ruleset narrowed on it takes a
  working container off the network mid-task. The same holds for a restore that
  cannot commit and for a failed fetch of the published GitHub ranges. Unset (the
  default) nothing is refreshed and the boot log says so.
- **Egress lockdown, fail-closed (`CLAUDE_EGRESS_LOCKDOWN=strict`).** Same
  firewall, opposite trade: if the ruleset cannot be applied, the container
  **refuses to start the agent** and exits nonzero, naming egress lockdown in the
  boot log (readable with `claude-logs` after it has stopped). Every reason the
  firewall reports a failure is fatal under `strict`, missing `iptables` and an
  allowlist that resolved to nothing alike: fail-open turns lockdown into a
  request, and `strict` is for when you need it to be a requirement, e.g. running
  an agent on untrusted input. Use it knowing the cost: a strict container that
  can never apply its ruleset keeps restarting until you stop it, exactly like one
  with a bad `GIT_REPO_URL`, and the way out is to set the variable back to `1`
  or `0`. `strict` is contained only as well as the ruleset underneath it: on a
  host or image where the IPv6 pass cannot run, the boot log still says `IPv6
  UNRESTRICTED` and the container still starts, because the IPv4 lockdown DID
  apply. A value that is neither an off value nor a recognised on/`strict`
  spelling boots with egress unrestricted and is reported in the boot log with the
  posture it produced, so a mistyped `strict` cannot read as an intentional "off".
- **Package-registry egress (opt-in, additive).** `CLAUDE_EGRESS_PACKAGES=1`
  adds the curated package registries: PyPI, crates.io, the Go module proxy,
  `mise.run`, and `ghcr.io`: to the same IP-pinned allowlist, so agent-driven
  `pip`/`cargo`/`go`/`mise` installs work while lockdown is on. It is **curated,
  not open**: a registry that isn't listed still DROPs, because *open* egress is
  the supply-chain exfil path the container refuses. Nothing broadens unless the
  flag is explicitly set, and the fail-open-as-a-whole semantics are unchanged.
  Debian/apt **system** libraries are deliberately not here: no self-service path
  currently provisions those (see docs/legacy-sysbox-broker.md). The threat model (the
  Nx-class weaponized-agent exfil) and the containment rules are in
  [docs/package-provisioning-security.md](package-provisioning-security.md).
  The baked `mise` toolchain provisioner (rootless language/CLI installs) rides on
  this containment: see [Toolchains on demand](toolchains-on-demand.md#toolchains-on-demand-mise) and
  [docs/toolchain-provisioning.md](toolchain-provisioning.md).
- **`claude-auth` volume** holds your live OAuth credentials
  (`.credentials.json`): effectively your Claude session. Anyone who can read
  this Docker volume can act as you. Rotate by `docker volume rm claude-auth`
  then `make login` again (or `claude auth logout` then re-login).
- **SSH keys.** The git key and authorized_keys are mounted read-only and never
  baked into the image. The git key is copied to a 0600 file owned by `claude`
  (read-only bind mounts can't satisfy SSH's permission check directly). Host
  keys persist in `claude-sshkeys` so the fingerprint is stable; all containers
  share it (acceptable for a single-owner homelab, note it and use distinct
  keys if that matters to you).
- **The SSH port is published on all host interfaces** (`0.0.0.0`) by default,
  so it is reachable from the whole LAN. Auth is pubkey-only, but to limit the
  exposure set `CLAUDE_SSH_BIND=127.0.0.1` (host-only) or another interface:
  honored by `claude-launch` and `claude-compose-gen`.
- Egress is open by default (Claude, npm, git, MCP all need it). Locking it
  down: [docs/troubleshooting.md](troubleshooting.md#restricting-egress).
