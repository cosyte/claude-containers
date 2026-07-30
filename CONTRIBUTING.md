# Contributing to claude-containers

Thanks for considering a contribution. This is a small, opinionated stack built
for one job — running isolated, long-lived Claude Code sessions on a self-hosted
box — so the most useful contributions are usually a reproduction, a host/runtime
combination we have not tried, or a narrow fix.

Please read [SECURITY.md](./SECURITY.md) before filing anything
security-shaped. Several plausible reports are documented non-goals, and
vulnerabilities go through private reporting rather than an issue.

## Filing an issue

1. Search existing issues first.
2. Include your host OS, `docker version`, `runc --version`, and whether Sysbox
   is installed; a surprising number of failures here are host-runtime issues.
3. Include the exact `claude-launch` / `claude-compose-gen` command, the relevant
   env vars, and `docker logs <container>` around the failure.
4. **Redact before pasting.** Logs from this stack can contain tokens, OAuth
   credentials, and repo contents. `GH_TOKEN`, `.credentials.json` and SSH key
   material must never appear in an issue.
5. Say which mode you were in — interactive, autopilot, queue, or SCM observer.
   They fail differently.

## Opening a PR

1. Fork and branch from `main`.
2. **Run the gates locally before pushing:**
   ```bash
   make lint      # bash -n over every shell entrypoint
   npm test       # the unit suites (no Docker required)
   ```
   Both must be clean. CI runs exactly these.
3. `make smoke` builds the image and exercises a real container. It is **not** in
   CI — a hosted runner cannot build and run the image usefully — so run it
   yourself for anything touching the Dockerfile, the entrypoint, or launch.
4. Keep PRs focused: one logical change. Large reworks should start as an issue.
5. Imperative commit subjects (`fix(entrypoint): …`, `feat(launch): …`) are
   encouraged, not enforced. No Conventional-Commits tooling.
6. Update the docs in the same PR. `README.md` is **load-bearing operator
   documentation**: if a command in it fails on a fresh clone, that is a bug.

## What this repo is made of

Bash, `make`, and Docker. It ships no package and has **zero runtime
dependencies** — `package.json` exists only so CI and the unit suites have a
task runner. Do not add a dependency without a strong reason.

- `bin/` — the operator CLIs (`claude-launch`, `claude-compose-gen`,
  `claude-autopilot`, `claude-disk-gc`, …), sharing `bin/_common.sh`.
- `entrypoint.sh` — the container boot path, in numbered sections. Most behaviour
  lives here.
- `test/*.sh` — Docker-free unit suites, one per area, driven by `npm test`.
- `docs/` — architecture, provisioning, security, troubleshooting.

## Conventions that bite

- **Do not quote values in `.env`.** The file is read both by bash `source` and
  by `docker --env-file`; the latter keeps quotes literally, so a quoted value
  arrives with the quotes attached.
- **A removed flag must refuse, not silently no-op.** When something is deleted,
  the old flag stays as an error that names where it went. A silent no-op turns
  an operator's explicit request into nothing.
- **Fail closed on safety, fail open on connectivity.** Sysbox preflight and the
  credential guards refuse to boot rather than run degraded. Egress lockdown does
  the opposite on purpose: it logs loudly and leaves egress unrestricted rather
  than bricking a session.
- **Never add a log line carrying workspace or prompt content** to debug a
  failure. Assume anything logged may be read by someone who should not see the
  repo.
- **The Claude Code version pin is declared in several places and a unit suite
  enforces that they agree** (`test/cli-version-unit.sh`). Bump them together —
  and note that bumping it changes which *model* the `opus` alias resolves to,
  not just which CLI ships.

## Licence

By contributing you agree your contribution is licensed under the
[MIT License](./LICENSE) that covers this project.
