# claude-containers package provisioning = curated-allowlist + contained install

**Status:** ACCEPTED — 2026-07-11 (PKG-1). This document is both the **threat model** and the
**decision record** for self-service package provisioning in `claude-containers`. The repo keeps no
formal `decisions/` directory, so this doc *is* the record. (The `PKG-*` identifiers come from the
maintainer's private planning repo, which tracks this as the ADR "claude-containers package
provisioning = curated-allowlist + contained install"; that repo is not public and nothing here
requires it — the decisions are stated in full below.) It **gates PKG-2/PKG-3/PKG-5** — nothing
that lets the agent fetch packages builds until the containment described here is in place.
(§3.4 and §3.7 below are **RETIRED** — they documented PKG-4's worker-tier `apt` and PKG-6's
pull-through cache proxy, both retired in SC-5 along with the Sysbox nested-worker-broker substrate
they were scoped to — see [docs/legacy-sysbox-broker.md](legacy-sysbox-broker.md). Read §3.1, §3.2,
§3.3, §3.5 and §3.6 as the live containment rules.)

**Scope of what shipped in PKG-1:** the opt-in `CLAUDE_EGRESS_PACKAGES` profile in
`bin/claude-egress-firewall` (an additive, IP-pinned registry allowlist) plus this threat model.
Everything downstream — `mise` (PKG-2), the shared cache (PKG-3),
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
  deliberately rejected them once already for this reason — see `bin/claude-egress-firewall`'s own
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

### 3.4 Install-then-relock — a narrow provisioning window — RETIRED (SC-5)

**This rule no longer holds and nothing on `main` implements it.** It described PKG-4's brokered
`apt`, which opened the Debian mirrors for the install window and re-locked egress afterward
(`bin/claude-apt-provision` + `CLAUDE_EGRESS_APT`). PKG-4 and PKG-6 were retired with the
Sysbox/broker substrate in `SC-5` (§3.7), and with them the only code that ever opened and
re-locked a window. `grep -rn -i 'relock\|re-lock' bin/ entrypoint.sh` now returns nothing.

**The true posture on `main`:** `bin/claude-egress-firewall` is a **one-shot boot script** — it runs
once, as root, before the privilege drop, and never re-locks. `CLAUDE_EGRESS_PACKAGES=1` therefore
allowlists the curated **registry** hosts (§3.1) for the container's **entire lifetime**, not for a
bounded window. Do not read this section as a live bound on exposure. What actually contains a
poisoned package under `CLAUDE_EGRESS_PACKAGES=1` is the *curated* (never open) allowlist (§3.1),
scripts-off-by-default (§3.2), and credential unreachability (§3.3) — not a relock.

Recorded here rather than deleted because §5's decision record cites this rule; see
[docs/legacy-sysbox-broker.md](legacy-sysbox-broker.md) for the frozen implementation.⁹ᐟ¹⁰

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

### 3.7 Worker-tier curated `apt` and the pull-through cache proxy — RETIRED (SC-5)

Two further containment tiers used to build on top of the above: a worker-tier curated `apt`
(PKG-4, `bin/claude-apt-provision` + `claude-config/apt-manifest.txt`) that closed the system-`.so`-library
gap `mise` can't fill, in the Sysbox nested-worker tier only; and a controller-side pull-through
package cache (PKG-6, `bin/claude-cache-proxy`) that collapsed all package egress to one audited
proxy host. Both were retired in SC-5 along with the Sysbox nested-worker-broker substrate they
were scoped to — see [docs/legacy-sysbox-broker.md](legacy-sysbox-broker.md) for the frozen
implementation. System `.so` libraries currently have **no** self-service provisioning path in this
repo (a documented non-goal — see §4); a plain leaf container never had `apt` access, and now
neither does anything else.

## 4. What this does NOT cover (honest non-goals)

- **System libraries (`apt`) are not a self-service capability at all.** The agent runs as non-root
  UID 1000 with no `sudo`; `apt-get install <syslib>` is impossible in a plain container by design.
  A worker-tier `apt` path used to close this gap (PKG-4, §3.7) but was retired in SC-5 along with the
  Sysbox substrate it depended on. The Debian mirrors are intentionally absent from the PKG-1 profile
  for this reason. Getting a system library today means a base-image rebuild (add it to the Dockerfile)
  — there is no in-session provisioning path, and none is planned unless the Sysbox substrate returns.
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
- **Not "install anything from the open internet."** Egress stays default-deny plus a curated
  allowlist — never open, never an app-layer/SNI filter.

## 5. Decision & status

**Decision (ACCEPTED 2026-07-11):** `claude-containers` self-service package provisioning is
**curated-allowlist + contained install**. Concretely:

- Registry egress is an **opt-in, additive, IP-pinned netfilter allowlist** (`CLAUDE_EGRESS_PACKAGES`
  in `bin/claude-egress-firewall`), scoped to the canonical registry hosts in §3.1 — never open
  egress, never an app-layer/SNI filter, always outside the agent's reach.
- Install-time scripts are **off by default** (PKG-5); credentials are **unreachable during the fetch
  window** (git-key broker + egress DROP); nothing broadens egress implicitly, and the firewall's
  fail-open-as-a-whole semantics are preserved.
- System-library provisioning has **no self-service path** (§3.7/§4) — a base-image rebuild only.

> **Amended by `SC-5` (2026-07-12).** The **install-then-relock** window (§3.4) was PKG-4's
> mechanism: `bin/claude-apt-provision` opened `deb.debian.org` egress for the install and
> re-locked it. PKG-4 and PKG-6 were **retired with the Sysbox/broker substrate** (§3.7), so
> there is no longer any in-session system-package install path to contain — which is why the
> bullet above states there is no self-service path at all. The surviving containment is the
> curated **registry** allowlist (§3.1), scripts-off-by-default (§3.2), credential
> unreachability (§3.3), and pinned manifests (§3.6). See `docs/legacy-sysbox-broker.md`.

This decision **gates PKG-2/PKG-3/PKG-5**: `mise` (rootless toolchains + CLI binaries), the shared
tool cache, and the pinned/`--ignore-scripts` reproducibility hardening all build on top of the
containment recorded here and inherit it rather than re-deciding it.

---

### Source markers

Footnote numbering carried over from the maintainer's private planning notes; the sources
themselves are public:

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
