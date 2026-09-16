## Toolchains on demand (`mise`)

The image bakes [`mise`](https://mise.jdx.dev) so a session can provision language
toolchains and prebuilt CLIs **as the unprivileged `claude` user, with no `sudo`
and no image rebuild**:

```bash
mise use node@22            # languages: node / python / go / rust / …
mise use python@3.12
mise use aqua:BurntSushi/ripgrep   # arbitrary prebuilt CLIs (aqua registry)
mise use github:cli/cli            # …or straight from a GitHub release
```

Installed tools land in the shared **`/cache`** tree (see below) and are on
`PATH` for the agent immediately (via mise's shims dir, baked onto `PATH` for
non-interactive shells; interactive SSH/tmux shells get full `mise activate`).
mise is **pinned + SHA256-verified in the Dockerfile** at build: the release
binary is downloaded from GitHub and checked against a hardcoded digest, no
`curl | sh` (bump `MISE_VERSION` + the two digests together). `pipx:` installs
reuse the baked `uv` automatically.

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
- **System libraries (`apt`) are not available**: the agent is rootless, and the
  worker-tier `apt` path that used to close that gap was retired along with the
  Sysbox worker-broker substrate it depended on (see
  [docs/legacy-sysbox-broker.md](legacy-sysbox-broker.md)). A system library
  needs a base-image rebuild today.
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
