# Toolchains on demand (`mise`)

The image bakes [`mise`](https://mise.jdx.dev) so a session can provision language
toolchains and prebuilt CLIs **as the unprivileged `claude` user, with no `sudo`
and no image rebuild**:

```bash
mise use node@22            # languages: node / python / go / rust / …
mise use python@3.12
mise use aqua:BurntSushi/ripgrep   # arbitrary prebuilt CLIs (aqua registry)
mise use github:cli/cli            # …or straight from a GitHub release
```

Installed tools land in the shared **`/cache`** tree (see below). Run
`claude-mise-shims` after a `mise use` to put the new tool on `PATH` for the agent
(interactive SSH/tmux shells get full `mise activate` and see it at once).
mise is **pinned + SHA256-verified in the Dockerfile** at build: the release
binary is downloaded from GitHub and checked against a hardcoded digest, no
`curl | sh` (bump `MISE_VERSION` + the two digests together). `pipx:` installs
reuse the baked `uv` automatically.

**This container's shims.** mise's shims dir (`/cache/mise/shims`) is shared by every
container, so it holds a shim for every tool any container ever installed, and a shim for a
tool with no version set here still answers `command -v`, then fails with "No version is set
for shim". So `PATH` holds a per-container view instead: `$CLAUDE_STATE_DIR/mise-shims`
(`~/.local/share/claude-mise-shims` without `CLAUDE_STATE_DIR`), holding a link to the shared
shim of each tool `mise` resolves in this container, from the global config and every mise
config under `/workspace`. The shared dir is not on `PATH`, so a tool with no version reads
"command not found". The entrypoint builds the view at every start (it logs how many
shims it linked), and `claude-mise-shims` rebuilds it on demand. Neither ever changes the
shared dir: other containers resolve other versions from it. A tool `mise` resolves only
inside one repo is linked for the whole container; outside that repo its shim falls through
to the next one on `PATH` (a system `python3`, say), as before.

**Shared, persistent tool cache.** mise's install store **and** the
`cargo`/`go`/`npm`/`uv`/`pip` caches live on **one shared docker volume**
(`claude-cache`) mounted at `/cache`, so a toolchain or CLI provisioned by one
container is a **cache hit** for the next launch of that project and for every
other container sharing the volume: no re-download. It's **on by default**;
`claude-launch --no-cache` (or `claude-compose-gen --no-cache`) opts out, and a
**missing cache never errors a launch**: it degrades to per-container installs
(fail-safe). The volume is bounded by `claude-disk-gc`: over `CLAUDE_CACHE_MAX_MIB`
it trims only the re-fetchable download caches (installed toolchains kept),
idle-only and fail-safe. Full design + verification:
[docs/shared-tool-cache.md](shared-tool-cache.md).

- **Egress lockdown is opt-in** (`CLAUDE_EGRESS_LOCKDOWN=1`); **off by default,
  where every `mise use …` just works.** Under lockdown: `github:`/`aqua:` and
  `python@` work on the **base** allowlist; `pip`/`cargo`/`go` registry backends
  need `CLAUDE_EGRESS_PACKAGES=1`; and the `node@`/`go@`/`rust` toolchains pull
  their runtime from vendor hosts (nodejs.org, go.dev, static.rust-lang.org) not
  yet on the allowlist, so they need those hosts via `CLAUDE_EGRESS_EXTRA_HOSTS`.
- **System libraries (`apt`) are not available**: the agent is rootless. A system
  library needs a base-image rebuild.
- The image sets `trusted_config_paths` to **`/workspace` only**: a deliberately
  scoped supply-chain trade so a repo's own `mise.toml` auto-applies while a config
  anywhere else stays untrusted (never a blanket `/`). Full design + verification:
  [docs/toolchain-provisioning.md](toolchain-provisioning.md).
- **Reproducible + script-hardened installs.** Agent-initiated `npm`/`pnpm`
  installs run with **`ignore-scripts=true`** (baked into the `claude` user's
  `~/.npmrc`, so build-time root installs are untouched; a repo opts back in with its
  own `/workspace/.npmrc`). mise **`lockfile=true`** makes a committed
  `mise.lock` reinstall identical versions offline from the shared cache. `claude-deps-check`
  flags `latest`/unpinned specs in `mise.toml`/`package.json` (advisory; `--strict`
  refuses). Threat model + bypasses: [docs/package-provisioning-security.md](package-provisioning-security.md).
