# Contributing

Thanks for considering a contribution. This is a small, focused project — a
self-hosted Docker stack for isolated Claude Code sessions — so the bar is
"keep it simple, keep it reviewable."

## Development setup

You need Docker (with Buildx) and GNU Make. Everything else lives in the image.

```bash
cp .env.example .env     # tweak if you want; defaults are sane
make build               # build the image for your host arch
make login               # one-time OAuth (Claude Max subscription, no API key)
./bin/claude-launch demo --repo git@github.com:you/demo.git
```

See [`docs/architecture.md`](docs/architecture.md) for how the pieces fit
together and *why* the non-obvious decisions were made, and
[`docs/customizing-bakeins.md`](docs/customizing-bakeins.md) for the baked-in
config layout.

## Before you open a PR

Run the linters — CI runs the same checks and will block on them:

```bash
make lint                # bash -n + shellcheck + hadolint (auto-skips a missing tool)
```

If you changed runtime behavior (entrypoint, config merge, workspace clone,
auth), run the smoke test against a freshly built image:

```bash
make build
IMAGE=claude-code-box:latest test/smoke.sh
```

The smoke test needs Docker and a logged-in `claude-auth` volume; the final
SSH/Remote-Control checks are manual and called out in the script. There is no
automated end-to-end test for the mobile app — that part is verified by hand.

## Conventions

- **Commits**: `area: imperative summary`, lower-case area, no trailing period
  (e.g. `entrypoint: converge credentials atomically`,
  `docs: clarify telemetry rationale`). Small, self-contained commits.
- **Branches**: work on a topic branch; never push directly to `main`.
- **Shell**: `#!/usr/bin/env bash` and `set -euo pipefail`, *except* the two
  tmux-pane wrappers (`bin/claude-session`, `bin/claude-dev`), which
  deliberately omit `-e` so they can fall back to an interactive shell when the
  wrapped process exits — don't "fix" those. Reuse helpers from
  `bin/_common.sh`. Keep new scripts shellcheck-clean at `--severity=warning`;
  if a warning is intentional, suppress it inline with a
  `# shellcheck disable=SCxxxx` and a one-line reason.
- **Dockerfile**: stays hadolint-clean. The opt-outs in `.hadolint.yaml` are
  deliberate and documented there — extend that file (with a reason) rather
  than sprinkling inline ignores.
- **Docs**: behavior changes update the relevant file under `docs/` and, if
  user-visible, `README.md` and `CHANGELOG.md` (`## [Unreleased]`).

## Reporting bugs & security issues

Functional bugs: open a GitHub issue with the failing command, expected vs.
actual behavior, and relevant `./bin/claude-logs <name>` output.

Security vulnerabilities: **do not** open a public issue — follow
[`SECURITY.md`](SECURITY.md).
