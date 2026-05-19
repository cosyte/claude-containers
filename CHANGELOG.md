# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Behaviour changes should add an entry under `## [Unreleased]` (see
`CONTRIBUTING.md`).

## [Unreleased]

### Added

- Optional GitHub PAT auth: set `GH_TOKEN` (or `GITHUB_TOKEN`) in the host
  environment or `.env` to authenticate the `gh` CLI and, via
  `gh auth setup-git`, git over HTTPS — private HTTPS clone/push and
  `gh pr create` now work without an SSH key. SSH remotes are unaffected and
  keep using `GIT_SSH_KEY`. Wired through `bin/claude-launch`,
  `docker-compose.yml`, and the multi-repo `bin/claude-compose-gen`
  generator. The token is read from the environment at use time and is never
  written to an image layer.
- `LICENSE` (MIT), `SECURITY.md` (private vulnerability reporting + the
  stack's security guarantees), and `CONTRIBUTING.md`.
- `.hadolint.yaml` with the deliberate, documented Dockerfile lint opt-outs.
- `CHANGELOG.md` (this file).
- Continuous integration: lint (bash -n + shellcheck + hadolint) and an
  image build on every push and pull request.

### Changed

- `make lint` now runs `bash -n` + `shellcheck --severity=warning` over all
  shell scripts (including `test/smoke.sh` and `bin/claude-compose-gen`) and
  `hadolint` on the `Dockerfile`, skipping any tool that is not installed.
  Previously it only ran `bash -n` on a partial file list.

## [0.1.0] - 2026-05-19

Initial release: a self-hosted Docker stack for running many isolated,
long-lived Claude Code sessions on one host, each reachable over SSH (a
persistent tmux session) and the Claude mobile app's Remote Control.

### Added

- Docker image (`node:24-bookworm-slim`): npm-pinned Claude Code, `uv`,
  `gh`, baked `pnpm`/`yarn`, build toolchain, hardened sshd, non-root
  `claude` user.
- `entrypoint.sh`: refuses `ANTHROPIC_API_KEY` (OAuth-only), persistent SSH
  host keys, runtime-mounted git/authorized keys, shared-credential
  reconcile loop, workspace-trust pre-acceptance, baked-in config merge
  (CLAUDE.md / settings / plugins / commands / skills), workspace
  use/clone, runtime MCP registration, tmux session under PID 1.
- Launcher scripts (`bin/claude-launch|list|stop|rm|logs`) over a shared
  `bin/_common.sh`, with auto SSH-port allocation and metadata labels.
- `bin/claude-compose-gen`: generates a multi-service compose file (one
  session per repo in a GitHub org or an explicit list) with stable SSH
  ports, `--active`/dormant Compose profiles for resource control, and
  `--expose`/`--dev-cmd` for browsable dev servers.
- Opt-in auto-start dev server (`CLAUDE_DEV_CMD` + a tmux `dev` window).
- One-container `docker-compose.yml`, `Makefile`, `.env.example`, automated
  `test/smoke.sh`, and `docs/` (architecture, customizing bake-ins,
  troubleshooting), plus an in-repo project skill.

### Fixed

- Remote Control: stopped setting `DISABLE_TELEMETRY` / `DO_NOT_TRACK` /
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, which short-circuited the
  GrowthBook fetch and made the `tengu_ccr_bridge` gate default false
  ("not yet enabled for your account"); the entrypoint also self-heals
  older config volumes.
- SSH authentication (`UsePAM`).
- BuildKit `COPY --from=` variable-expansion (via a named `uv` stage).

[Unreleased]: https://github.com/cosyte/claude-containers/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/cosyte/claude-containers/releases/tag/v0.1.0
