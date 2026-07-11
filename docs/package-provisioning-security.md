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

### 3.2 Install-time scripts OFF by default — **shipped (PKG-5)**

Agent-initiated installs run with lifecycle hooks disabled. **PKG-5 bakes `ignore-scripts=true` into
the `claude` user's `~/.npmrc`** — npm, pnpm, and yarn(1.x) all read it, so an agent-run `npm i` /
`pnpm i` in `/workspace` does not execute a dependency's pre/post-install scripts. It is scoped to the
**user** config on purpose: the image's own pinned `npm install -g` layers run **as root, before** this,
so a build-time dependency's hook can't fire during the image build either, and the runtime hardening
doesn't have to weaken the build. An escape hatch stays npm-native: a repo that genuinely needs install
scripts commits its own `/workspace/.npmrc` with `ignore-scripts=false` — a project-level `.npmrc`
overrides the user one, an explicit per-repo opt-in.

This directly targets §1 step 2: if the hook never runs, it never reads secrets or phones home. But it
is **one layer, not a guarantee** — documented bypasses remain, so it is defence-in-depth *underneath*
the egress and credential layers, never the thing that makes provisioning safe on its own:⁸
- **Native builds.** A `binding.gyp` / node-gyp native compile still runs — `ignore-scripts` governs
  lifecycle scripts, not gyp builds.
- **Git-dependency `.npmrc` override (PackageGate, GHSA-wr8v-3jqh-9x36).** When npm installs a git
  dependency, a malicious `.npmrc` inside it can override the git binary path and gain execution **even
  with `ignore-scripts=true`**; npm declined to fix it (deemed a vetting responsibility). Under our
  curated egress (§3.1) a git dep can't reach an arbitrary host, which is what actually contains this.
- **Lockfile integrity gaps (CVE-2025-69263).** pnpm (≤10.26.2) stored HTTP-tarball / git-tarball deps
  in the lockfile **without** integrity hashes, so a committed lock did not prevent a remote from
  serving different bytes per install. Prefer registry deps (which carry integrity hashes) and keep
  pnpm patched; a lock alone is not tamper-proof for those dep types (see §3.6).

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

### 3.6 Reproducible, pinned manifests — **shipped (PKG-5)**

Non-reproducible installs are their own supply-chain risk: an unpinned `latest` resolves to whatever
the registry serves *now* (possibly a freshly-compromised release), and a manifest without a lockfile
can drift between the agent's install and a later one. PKG-5 adds two reproducibility controls:

- **mise lockfile determinism.** The image bakes `lockfile = true` into the **global** mise config
  (`~/.config/mise/config.toml`), so a committed `/workspace/mise.lock` is authoritative: `mise
  install`/`use` records and reuses the exact locked tool versions, and a pinned lock reinstalls
  identical versions — offline, from the PKG-3 shared cache, with no registry round-trip. Global config
  is always trusted (it is mise's own, not a repo `mise.toml`), so this does **not** widen the
  `/workspace`-only config-trust decision from PKG-2.
- **`claude-deps-check` — an advisory pin linter.** Scans a repo's `mise.toml` (`[tools]`) and
  `package.json` dependency maps for unpinned / `latest` / wildcard / mutable-tag-alias specs (a
  prerelease pin like `1.2.3-rc.0` is correctly treated as pinned). Advisory by default (warns, exit 0 —
  never blocks a session); `--strict` additionally treats npm caret/tilde ranges as unpinned and
  **refuses** (exit 1), the form a pre-commit / CI gate calls. It reads manifests only — no install, no
  network, no mutation — and is fail-safe: a missing or unparseable manifest is a clean no-op. It
  classifies **semver** specs; it does **not** resolve git-dependency (`github:org/repo`,
  `git+https://…`) or raw-tarball-URL forms — those can still float on a branch/mutable URL, so pin a
  `#<sha>` or prefer an integrity-hashed registry dep (the CVE-2025-69263 caveat in §3.2).

Neither is tamper-proof on its own (see the CVE-2025-69263 lockfile-integrity caveat in §3.2); they
reduce the *drift* and *unpinned-resolution* surface, and compose with the egress + scripts-off layers.

### 3.7 Worker-tier curated `apt` — **shipped (PKG-4)**

The syslib gap `mise` can't fill: some worker workloads need a Debian **system** library (a `.so`) that
rootless `mise` toolchains cannot provide. PKG-4 fills it in the **Sysbox worker tier only**, with the
same containment posture as the rest of this document — `bin/claude-apt-provision`, invoked by the
worker entrypoint as root *before* the agent starts (`CLAUDE_APT_PROVISION=1`, passed in by the CC-2
broker):

- **Worker-only (host-safe root).** It installs **only** when it is root mapped to a **non-root host
  uid** — the Sysbox userns worker (root inside → unprivileged on host⁴), exactly what
  `claude-sysbox-verify` §3a proves. A plain **leaf** container (agent runs unprivileged; or a runc-root
  container whose root maps to host root) gets the **documented refusal** — *"no root — use `mise` /
  static binaries, or rebuild the base image"* — never a silent partial. The same self-gate means
  setting the flag on a leaf is a logged no-op, not a half-install.
- **Curated, not open.** Only packages in the committed, declarative
  `claude-config/apt-manifest.txt` install; the default manifest is **empty** (curation is a deliberate,
  reviewed act). Package specs are strictly validated (lowercase alnum + `+ . -`, optional exact-version
  pin) — a malformed entry fails the **whole** apply closed. Arbitrary agent-driven `apt` of untrusted
  repos is **refused**; a request for a package *not* in the manifest is refused, and a request for one
  that *is* resolves to the manifest's **own** pinned spec (a request can't smuggle a different version).
- **Install-then-relock (§3.4), all-or-refuse.** The provisioner opens `deb.debian.org` /
  `security.debian.org` for the install window via the firewall's opt-in `CLAUDE_EGRESS_APT` profile
  (additive + IP-pinned like `CLAUDE_EGRESS_PACKAGES`, off by default, absent from the leaf/base
  allowlist), runs `apt-get install --no-install-recommends`, then **re-locks** to the default-deny base.
  The relock runs on **every** exit path — including a failed or refused install — so no path leaves a
  half-provisioned *or* egress-open worker. As a final backstop the entrypoint re-runs the general egress
  lockdown *after* provisioning, so the seal never depends on the relock alone.

The live proof (a manifest package installs in a real Sysbox worker **and** `id` shows root→non-root
host uid; a leaf refuses; an out-of-manifest request refuses; egress re-locked after the window) needs a
Sysbox host and is the on-host gate. The provisioner's logic — tier gate, validator, curated resolution,
and the open→install→relock order — is proven in CI via seams (`test/apt-provision-unit.sh`) with no
root, apt, or iptables.

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
- **`--ignore-scripts` is not a standalone guarantee.** As in §3.2, native `binding.gyp` builds run
  regardless, a git-dependency `.npmrc` can override the git binary to execute under it (PackageGate,
  GHSA-wr8v-3jqh-9x36), and pnpm lockfile-integrity gaps (CVE-2025-69263) mean a lock isn't tamper-proof
  for HTTP/git tarball deps.⁸ It is one layer under the egress + credential layers, not a boundary by
  itself.
- **No registry min-release-age / age-gating.** `claude-deps-check` flags *unpinned* specs, but PKG-5
  does **not** query registries to reject too-new releases (a "wait N days before trusting a version"
  control). That needs live registry egress on every check, which cuts against the offline/locked
  posture; it stays a possible future control, deliberately not built here.
- **The apt window pins Debian's CDN to point-in-time IPs (PKG-4).** `deb.debian.org` /
  `security.debian.org` are Fastly-backed and rotate; the firewall pins the IPs resolved when the window
  opens, so an `apt` connection that reconnects to a *different* CDN IP mid-install can be dropped by
  default-deny and fail the install (rc 5, the worker boots without the package). This is the same
  IP-pinning tradeoff the whole firewall makes for every CDN-backed host (npm, ghcr); the window is
  short so fresh IPs usually hold, but a rotation-timing failure is a known reliability limit, not a
  containment hole (a dropped connection fails *closed*). A pull-through apt proxy (PKG-6) is the durable
  fix; it is demand-gated, not built here.
- **PKG-4 relock inherits the firewall's fail-**open**.** If the relock's `iptables` apply fails, the
  firewall fails **open** (egress unrestricted) exactly as its base contract says — the provisioner logs
  an ERROR and returns non-zero, and the entrypoint's general lockdown re-seals afterward, so the worker
  is not left open on the entrypoint path. A **standalone** `claude-apt-provision` invocation (not via
  the entrypoint) has no such final seal and must re-lock egress itself. PKG-4 does not change the
  fail-open contract; a fail-*closed* firewall is a separate, deliberate non-decision (it would let a
  misconfig brick a homelab's connectivity).
- **`CLAUDE_APT_PROVISION=1` with egress lockdown OFF runs `apt` over open egress.** With no
  `CLAUDE_EGRESS_LOCKDOWN=1` there is no scoped `deb.debian.org` window and no relock — `apt` fetches
  over the container's default (open) egress. The entrypoint **warns** on this incoherent combination;
  it is a config choice, not silent. The contained install window exists only under egress lockdown.
- **Under lockdown, provisioning re-applies the firewall up to three times at boot** (open-with-apt →
  relock → the entrypoint's general lockdown), each a full re-resolution of the allowlist — tens of
  seconds on a worker with both flags on. The redundancy is deliberate (the general lockdown is the
  authoritative final seal, and the provisioner's own relock covers standalone use); an incremental
  "add two hosts to the live ruleset" fast path is a possible future optimization, not built here.
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
- **⁸** npm install-script risk + `--ignore-scripts` and its documented bypasses: native `binding.gyp`
  builds run regardless; a git-dependency `.npmrc` can override the git binary to execute even under
  `--ignore-scripts` (Google "PackageGate", GHSA-wr8v-3jqh-9x36; npm declined to fix); and pnpm
  lockfile-integrity gaps for HTTP/git tarball deps (CVE-2025-69263, patched pnpm > 10.26.2).
- **⁹** CI/CD egress control + layered supply-chain defense (allowlist at the runner;
  install-then-drop-network; pull-through caches).
- **¹⁰** Sandboxing coding-agent network egress via a proxy allowlist + credential isolation during
  install; lockfile reproducibility.
