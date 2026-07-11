# claude-containers package provisioning = curated-allowlist + contained install

**Status:** ACCEPTED — 2026-07-11 (PKG-1). This document is both the **threat model** and the
**decision record** for self-service package provisioning in `claude-containers`. The repo keeps no
formal `decisions/` directory, so this doc *is* the record (the umbrella-side roadmap
`operations/roadmaps/claude-containers.md` §II.8 tracks it as the ADR "claude-containers package
provisioning = curated-allowlist + contained install"). It **gates PKG-2..PKG-6** — nothing that
lets the agent fetch packages builds until the containment described here is in place.

**Scope of what shipped in PKG-1:** the opt-in `CLAUDE_EGRESS_PACKAGES` profile in
`bin/claude-egress-firewall` (an additive, IP-pinned registry allowlist) plus this threat model.
Everything downstream — `mise` (PKG-2), the shared cache (PKG-3), brokered `apt` (PKG-4),
`--ignore-scripts` + pinned manifests (PKG-5) — inherits the containment stated here.

---

## 1. The threat — a weaponized package exfiltrates credentials during provisioning

Handing a prompt-injectable agent the ability to install packages is *the* attack surface that has
already been weaponized in the wild. The **Nx incident** (August 2025) shipped malicious npm
**postinstall** scripts that specifically **weaponized local AI coding agents** (Claude Code, Gemini,
Amazon Q) into reconnaissance-and-exfiltration tooling, stealing GitHub/npm tokens, SSH keys,
environment variables, and crypto wallets.⁷ It is the canonical example of the exact surface that
self-service provisioning opens.

The attack chain is short and runs entirely inside the agent's own trust context:

1. **A malicious (or typosquatted, or newly-compromised) dependency enters an install.** The agent
   runs `pip install`, `cargo install`, `go install`, `npm install`, or `mise use …` for a
   legitimate-looking tool that pulls a poisoned package.
2. **An install-time hook runs automatically.** `npm install` (and `pip`, `cargo`, `gem`, …) auto-run
   install/postinstall hooks **with the same filesystem and environment access as the agent that
   invoked them**.⁸ No prompt, no confirmation — the hook executes as UID 1000, the `claude` user.
3. **The hook reads secrets in reach.** It scans `~/.ssh`, the environment (`CLAUDE_*`, any `.env`),
   an OAuth token, mounted deploy keys — whatever the agent's own context can read.
4. **The hook POSTs them to an attacker-controlled host.** If the container can reach the open
   internet, the loot leaves the box. This is the step every containment rule below is designed to
   break.

Because the hook shares the agent's context, this is not an escalation-of-privilege attack — it needs
no root, no host escape, no runc CVE. It is a straight-line **exfiltration** attack, and the only
thing standing between "poisoned package pulled" and "credentials leaked" is what the container will
let an install-time hook *read* and *reach*.

## 2. Why the naive fix fails

The obvious way to make `pip`/`cargo`/`go`/`mise` work is to let the container reach the internet to
fetch from the registries. That is exactly the exfil path from §1 step 4 — **open egress is the
attack**, not an incidental convenience. Two tempting half-measures do not close it:

- **"Just allow all outbound 443."** Every reachable host is a candidate exfil destination. Open
  egress hands a compromised install script a channel to anywhere.⁹
- **App-layer / SNI / hostname allowlists are bypassable.** A hostname- or SNI-based filter can be
  defeated (SNI can be spoofed or omitted, DNS can be abused as a covert channel, the check often
  lives in the same context the attacker already controls). The `claude-containers` egress model
  deliberately rejected them once already for this reason — see `docs/substrate.md` and the firewall
  header.

The containment therefore has to be an **IP-pinned, curated (not open) netfilter allowlist applied
outside the agent's reach.** `bin/claude-egress-firewall` runs **as root at boot, before the
entrypoint drops to the unprivileged `claude` user**; the agent has no `NET_ADMIN` capability, so it
**cannot alter the rules** no matter what a compromised install script tries. Enforcement lives below
the agent, in netfilter, keyed to resolved IPv4 addresses — not to a name a hook could lie about.

## 3. The containment rules

Each rule states the control and why it exists. All five must hold together; none is a silver bullet
alone.

### 3.1 Curated, not open egress

`CLAUDE_EGRESS_PACKAGES=1` **additively** allowlists exactly the canonical package-registry hosts and
nothing else. What the profile actually opens today (from `bin/claude-egress-firewall`, the
`PACKAGES_HOSTS` block):

- **PyPI** — `pypi.org`, `files.pythonhosted.org`
- **crates.io (Rust)** — `crates.io`, `index.crates.io`, `static.crates.io`
- **Go module proxy** — `proxy.golang.org`, `sum.golang.org`
- **mise self-install** — `mise.run`
- **OCI / aqua binaries** — `ghcr.io`

(npm's `registry.npmjs.org` and the GitHub hosts — `github.com`, `api.github.com`, `codeload.github.com`,
`objects.githubusercontent.com`, plus GitHub's published IPv4 ranges from `api.github.com/meta` — are
already in the firewall's baked `DEFAULT_HOSTS`, so `mise`'s `github:`/`aqua:` GitHub-release backends
work even with the package profile off.)

Every one of these is resolved to its current IPv4 set and pinned as a netfilter `-d <ip>` ACCEPT on
ports 22/80/443, exactly like every other allowlisted host. **A non-allowlisted exfil host still
DROPs** — the default `OUTPUT DROP` policy is untouched; the profile only ever *adds* ACCEPT rules for
the curated set.

*The usability trade is deliberate and documented:* a tool whose registry host isn't on this list
**won't install until the host is added**. That is the point. Open egress is the exfil path this
container refuses; a missing registry is an inconvenience, an open channel is a breach. (Debian/apt
mirrors — `deb.debian.org`/`security.debian.org` — are **deliberately not here**; see §4.)

### 3.2 Install-time scripts OFF by default

Agent-initiated installs run with install hooks disabled — `npm install --ignore-scripts` /
`ignore-scripts=true` in the baked npm config, and the equivalent for other managers. This lands in
**PKG-5**; PKG-1 records it as a required rule so the threat model is complete.

This directly targets §1 step 2: if the hook never runs, it never reads secrets or phones home. But it
is **one layer, not a guarantee** — documented bypasses exist: a native `binding.gyp` build step can
execute code without a `scripts` entry, and CVE-2025-69263 shows a malicious `.npmrc` overriding the
git binary to regain execution.⁸ So `--ignore-scripts` is treated as defence-in-depth *underneath* the
egress and credential layers, never as the thing that makes provisioning safe on its own.

### 3.3 Credentials unreachable during the fetch window

Even if a hook does run, the secrets it would exfiltrate must not be in reach. Two existing controls
provide this and provisioning **inherits, never bypasses** them:

- **The git-key broker.** When `CLAUDE_BROKER_GIT_KEY=1`, the deploy key lives only in a **root-owned
  `ssh-agent`'s memory** (plus a root-only key file); the `claude` user signs git operations through a
  uid-restricted relay socket and **cannot read the key material** (`entrypoint.sh`). A compromised
  install script running as UID 1000 finds no readable private key to steal.
- **The egress DROP itself.** With §3.1 in force, even a secret the hook *can* read (an env var, a
  token) has **nowhere to POST it** — the only reachable hosts are curated registries, and the exfil
  endpoint DROPs. Reach and read are both denied; the attack needs both.

(The fleet-wide `bin/claude-secret-guard` pre-commit hook is a related but distinct control — it stops
secrets being *committed*, not exfiltrated over the network. It is not what closes the fetch-window
exfil path; the two controls above are.)

### 3.4 Install-then-relock — a narrow provisioning window

The registry-egress window is kept **narrow**: open the package allowlist only for the provisioning
window, then **re-lock** (or, in the leaf-session case, never broaden the base at all — `mise`'s
`github:`/`aqua:` backends already work on the default allowlist). The exfil path must not be left
open after the fetch completes. In the Sysbox worker tier this is explicit — PKG-4's brokered `apt`
opens the Debian mirrors for the install window and re-locks afterward. The principle is the same
everywhere: a bounded fetch window with registry egress, credentials unreachable throughout, egress
re-locked when the fetch is done.⁹ᐟ¹⁰

### 3.5 Opt-in + additive, fail-open-as-a-whole preserved

`CLAUDE_EGRESS_PACKAGES` does **nothing** unless it is explicitly set (`1|true|yes|on`). It only ever
**adds** the curated hosts to the existing default-deny base — **nothing broadens egress implicitly**,
and no other code path opens the registries. The firewall's existing safety semantics are unchanged:

- **Fail-open only as a whole.** The full default-deny ruleset commits atomically via a single
  `iptables-restore`, or the filter table is left untouched — a misconfiguration never bricks a
  homelab's connectivity, it logs loudly and stays open (documented behavior of the firewall).
- **A bad host resolution is skipped, never opened.** If one registry host fails to resolve
  (timeout/NXDOMAIN) it is dropped from the pinned set with a warning — it never falls back to
  allowing that host, and never widens the policy. The additive profile inherits this exactly.

The dry-run seam (`CLAUDE_EGRESS_PRINT_HOSTS=1`) prints the composed allowlist and exits before
touching iptables, so the host-selection change the profile makes is verifiable in CI with no
`NET_ADMIN` and no live firewall.

## 4. What this does NOT cover (honest non-goals)

- **System libraries (`apt`) are not a leaf-container capability.** The agent runs as non-root UID 1000
  with no `sudo`; `apt-get install <syslib>` is impossible in a plain leaf container by design. Real
  system `.so` libraries need the **rootful Sysbox-worker tier** (PKG-4) — userns-contained container
  root, brokered from a curated manifest by the CC-2 root broker — **or** a base-image rebuild. The
  Debian mirrors are intentionally absent from the PKG-1 profile for this reason; they are opened only
  in that worker tier, for the install window, then re-locked. A leaf container gets a documented
  refusal, never a silent half-install.
- **`ghcr.io`'s blob CDN may need follow-up host additions.** The profile pins `ghcr.io`, but OCI blob
  layers can be served from a separate CDN host; if aqua/OCI pulls fail on a blob fetch, the specific
  CDN host is a follow-up allowlist addition — this profile does not claim to have enumerated every
  ghcr backend host up front.
- **`--ignore-scripts` is not a standalone guarantee.** As in §3.2, native `binding.gyp` and
  CVE-2025-69263 bypass it.⁸ It is one layer under the egress + credential layers, not a boundary by
  itself.
- **Sysbox is weaker isolation than a VM / gVisor / Kata.** The worker tier that carries `apt` is
  host-*contained* by a Linux user namespace, not a hostile-tenant boundary. A container — Sysbox
  included — is **not** a security boundary against a fully-weaponized agent; multi-tenant / hostile-
  tenant use stays a permanent non-goal (`docs/substrate.md`, README, roadmap §II.9).
- **Not "install anything from the open internet."** Egress stays default-deny plus a curated
  allowlist; a full artifact-proxy tier (Nexus/Verdaccio/Athens, PKG-6) is demand-gated, not built by
  default.

## 5. Decision & status

**Decision (ACCEPTED 2026-07-11):** `claude-containers` self-service package provisioning is
**curated-allowlist + contained install**. Concretely:

- Registry egress is an **opt-in, additive, IP-pinned netfilter allowlist** (`CLAUDE_EGRESS_PACKAGES`
  in `bin/claude-egress-firewall`), scoped to the canonical registry hosts in §3.1 — never open
  egress, never an app-layer/SNI filter, always outside the agent's reach.
- Install-time scripts are **off by default** (PKG-5); credentials are **unreachable during the fetch
  window** (git-key broker + egress DROP); the provisioning window is **narrow and re-locked**
  (install-then-relock); nothing broadens egress implicitly, and the firewall's fail-open-as-a-whole
  semantics are preserved.
- System-library provisioning is a **Sysbox-worker-tier, brokered, curated-manifest** capability
  (PKG-4), never available rootless in a leaf container.

This decision **gates PKG-2..PKG-6**: `mise` (rootless toolchains + CLI binaries), the shared tool
cache, brokered worker-tier `apt`, and the pinned/`--ignore-scripts` reproducibility hardening all
build on top of the containment recorded here and inherit it rather than re-deciding it.

---

### Source markers

Cited by the roadmap's footnote numbering (`operations/roadmaps/claude-containers.md` §II.11):

- **⁷** Nx malicious-package incident — npm postinstall scripts weaponized local AI coding agents
  (Claude Code, Gemini, Amazon Q) for recon + exfiltration of tokens, SSH keys, env, wallets.
- **⁸** npm install-script risk + `--ignore-scripts` and its documented bypasses (native `binding.gyp`;
  CVE-2025-69263 malicious `.npmrc` overriding the git binary).
- **⁹** CI/CD egress control + layered supply-chain defense (allowlist at the runner;
  install-then-drop-network; pull-through caches).
- **¹⁰** Sandboxing coding-agent network egress via a proxy allowlist + credential isolation during
  install; lockfile reproducibility.
</content>
</invoke>
