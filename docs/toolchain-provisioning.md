# claude-containers toolchain provisioning = baked `mise`, rootless, workspace-trusted

**Status:** ACCEPTED — 2026-07-11 (PKG-2). This is the design record for how a session provisions
language toolchains and prebuilt CLIs. It builds directly on the containment in
[`docs/package-provisioning-security.md`](package-provisioning-security.md) (PKG-1) and **inherits,
never re-decides, it**. The umbrella roadmap `operations/roadmaps/claude-containers.md` §II.8 tracks
this as PKG-2.

## What shipped

`mise` ([mise-en-place](https://mise.jdx.dev)) is baked into the image, pinned + checksummed, and
activated for the `claude` user. A session can then provision toolchains and CLI binaries **as UID
1000 with no root**:

```bash
mise use node@22            # language toolchains: node / python / go / rust / …
mise use python@3.12
mise use go@1.23
mise use aqua:BurntSushi/ripgrep    # arbitrary prebuilt CLIs (aqua registry)
mise use github:cli/cli             # …or straight from a GitHub release
```

Installed tools live under `~/.local/share/mise` (the `claude` user's home) and are on `PATH` for the
agent immediately — no `sudo`, no image rebuild.

## How it's wired

1. **Baked, pinned, checksummed in-repo.** This repo's whole thesis is supply-chain containment, so
   mise is **not** installed by piping a remotely-served `mise.run` script into a shell. The Dockerfile
   downloads the pinned mise release binary directly from GitHub releases (`v2026.7.5` at time of
   writing) and verifies its **SHA256 against a digest hardcoded in the Dockerfile** (`MISE_SHA256_AMD64`
   / `MISE_SHA256_ARM64`) before installing to a root-owned `/usr/local/bin/mise` — a tampered or
   wrong-served binary fails the build. Reproducible, not "latest". Bump `MISE_VERSION` **and both arch
   digests together**, from the release's published `SHASUMS256.txt` (the `-linux-x64` / `-linux-arm64`
   raw-binary rows).

2. **Activated two ways, for two shell kinds.**
   - **Interactive** (SSH logins, tmux panes): `~/.bashrc` runs `eval "$(mise activate bash)"` — full
     activation with the `cd`-hook and env management. `~/.bash_profile` sources `~/.bashrc`, so login
     shells reach it too.
   - **Non-interactive / agent** (`bash -c "…"`, the Claude Code process itself, which never sources
     `~/.bashrc`): the image prepends the **mise shims directory**
     (`/home/claude/.local/share/mise/shims`) to `PATH` via a Dockerfile `ENV`. Shims are the
     mise-recommended path for non-interactive use — a mise-installed `node`/`python`/CLI resolves
     with zero shell activation. The dir need not exist at build time; mise creates and populates it
     (as UID 1000) on the first `mise use` and reshims automatically.

3. **`pipx:` reuses the baked `uv`.** mise's `pipx.uvx` setting defaults **true** whenever `uv` is on
   `PATH` — and it is, baked in the layer above — so `mise use pipx:<tool>` installs via `uv`/`uvx`
   (much faster) with nothing extra to configure.

4. **Egress.** The egress firewall is **opt-in** (`CLAUDE_EGRESS_LOCKDOWN=1`); **by default it is off,
   and every `mise use …` reaches the internet normally.** Under lockdown the allowlist is default-deny
   and what works splits by *where mise fetches from* — this is the one subtlety worth internalizing:
   - **Prebuilt CLIs — `github:` / `aqua:`.** Fetch from GitHub releases (aqua also resolves its
     registry from GitHub), all on the baked **base** allowlist → work under lockdown with the package
     profile **off**. If a particular tool's aqua metadata happens to dial a host outside the allowlist,
     add it with `CLAUDE_EGRESS_EXTRA_HOSTS`.
   - **Registry backends — `pipx:` / `cargo:` / `go:`.** Install tool binaries from PyPI / crates.io /
     the Go module proxy → need `CLAUDE_EGRESS_PACKAGES=1` (PKG-1's opt-in, IP-pinned **registry**
     allowlist). `pipx:` reuses the baked `uv` (point 3).
   - **Language toolchains — `node@` / `go@` / `rust`.** Download the *runtime* from the vendor's own
     hosts (`nodejs.org`, `go.dev`, `static.rust-lang.org`), which are **not** on the current allowlist.
     Under lockdown these need those hosts added via `CLAUDE_EGRESS_EXTRA_HOSTS` (a candidate firewall
     follow-up) — or just run with lockdown off. **`python@` is the exception:** mise installs it from
     the GitHub-released python-build-standalone, which is on the base allowlist, so it works under
     lockdown as-is.

   System `.so` libraries are **out of scope** entirely — that gap is the Sysbox-worker apt tier
   (PKG-4), never rootless in a leaf container.

## The deliberate trust decision — `trusted_config_paths = /workspace`, not `/`

mise reads a repo's `mise.toml` to know which toolchain to apply. By default it **prompts** before
trusting an unseen config — but the agent runs non-interactively, where a prompt is effectively a
refusal, so an untrusted `mise.toml` would simply **not** auto-apply (fail-safe: it never silently
runs).

To make the sanctioned workflow work, the image sets `MISE_TRUSTED_CONFIG_PATHS=/workspace` — a
**deliberately scoped** trust: mise auto-trusts a `mise.toml` **only** under `/workspace`, the repo the
agent was launched to work on. This is a documented supply-chain trade:

- **Chosen:** `/workspace` — the one tree the session already operates on with full read/write. A
  `mise.toml` committed to that repo auto-applies its toolchain, which is the whole point.
- **Refused:** a blanket `["/"]`. That would auto-trust a `mise.toml` **anywhere** the agent can reach
  — a downloaded tarball, a `/tmp` scratch dir, a transitively-cloned dependency — turning "read a
  config" into "auto-run whatever any config on the filesystem declares". That is exactly the implicit-
  trust surface the PKG-1 threat model refuses, so we do not open it.
- **Still fail-safe outside `/workspace`:** a `mise.toml` anywhere else is untrusted → not auto-applied
  → no silent install. And trust is **not** execution: mise `[tasks]` still only run on an explicit
  `mise run`; auto-trust governs tool/env resolution, not arbitrary code execution. The egress DROP +
  git-key broker + (PKG-5) `--ignore-scripts` layers from the PKG-1 model all still apply underneath.

## Verification

CI runs `test/mise-unit.sh` — a docker-free, network-free static gate asserting the security-relevant
wiring is present and correctly scoped: the install is version-pinned **and SHA256-verified in-repo**
(no `curl | sh`), the shims dir is on `PATH` for non-interactive shells, interactive activation is
**appended** to the stock `~/.bashrc` and interactive-guarded, and `trusted_config_paths` is **exactly
`/workspace`** — never a blanket `/` or `~`. (Same split as PKG-1: the composition/scoping is proven in
CI; the live behavior is the on-host smoke gate below.)

The live proof needs a full image build and is a local/manual gate (like `make smoke`). In a plain leaf
container (egress lockdown **off** by default, so the runtime downloads reach their vendor hosts), as
UID 1000, with no `sudo`:

```bash
# language toolchain — works out of the box with the firewall off (its default)
mise use node@22 && node --version

# prebuilt CLI from a GitHub release — also works under lockdown on the base allowlist
mise use aqua:BurntSushi/ripgrep && rg --version

# fail-safe: an untrusted mise.toml OUTSIDE /workspace does not auto-apply
mkdir -p /tmp/evil && printf '[tools]\nnode = "18"\n' > /tmp/evil/mise.toml
( cd /tmp/evil && mise ls )   # must NOT silently install node@18; /workspace would
```

Under `CLAUDE_EGRESS_LOCKDOWN=1` the split in "How it's wired" §4 applies: `github:`/`aqua:` and
`python@` work as-is; `pipx:`/`cargo:`/`go:` need `CLAUDE_EGRESS_PACKAGES=1`; `node@`/`go@`/`rust`
additionally need their vendor hosts via `CLAUDE_EGRESS_EXTRA_HOSTS`.

All three must hold: the language install and the CLI install both succeed with no `sudo`, and the
out-of-workspace config does not silently provision.

## Non-goals (inherited + new)

- **No system `.so` libraries.** mise provisions binaries and language toolchains, not arbitrary
  system libraries — those are the Sysbox-worker apt tier (PKG-4) or a base-image rebuild. (roadmap
  §II.9)
- **No blanket config trust.** `/workspace` only; never `/`. See above.
- **Language toolchains are not reachable under egress lockdown yet.** `node@`/`go@`/`rust` fetch their
  runtimes from vendor hosts (`nodejs.org`, `go.dev`, `static.rust-lang.org`) not on the current
  allowlist, so under `CLAUDE_EGRESS_LOCKDOWN=1` they need those hosts added (`CLAUDE_EGRESS_EXTRA_HOSTS`)
  — a candidate firewall follow-up, deliberately not bundled into PKG-2's scope. Default (lockdown off)
  and `python@`/`github:`/`aqua:` under lockdown are unaffected. (How it's wired §4.)
- **`mise use` is not a security boundary on its own.** It sits on top of the PKG-1 containment
  (curated egress, credentials-unreachable-during-fetch, install-then-relock) and the PKG-5 script
  hardening — it does not replace them.
