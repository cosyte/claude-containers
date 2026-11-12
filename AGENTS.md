# AGENTS.md

The Docker image, host launchers, and in-container tools that run isolated, long-lived Claude Code
sessions. Bash, `make`, and Docker, with no runtime dependencies: `package.json` is only a task
runner, and the repository ships no package. `README.md` is the operator documentation.

## Build and test

Run `mise install` once, for the `shellcheck` and `hadolint` that the lint step needs (pinned in
`mise.toml`).

```sh
npm run lint   # bash -n, shellcheck -S warning, hadolint, then the dash check
npm test       # every unit suite in parallel, no Docker
make build     # build the image for the host and load it (Docker)
make smoke     # build the image, then run test/smoke.sh against it (Docker)
```

## The gate

Run `make gate-quick` from the repository root before you push: `make lint`, then
`scripts/check-no-emdash.sh` over every tracked file, then `test/run-all.sh`. A failing step stops
it. CI's required `ci` and `no-emdash` checks run the same. CI's `no-emdash-messages`, never a
required check, reads the pull request title, body, and commit messages, so check them first with
`bash scripts/check-no-emdash.sh --stdin "PR text"`. CI's `smoke` job runs on every pull request;
when one touches an image path (`scripts/smoke-needed.sh` decides), it builds the image and runs
`test/smoke.sh`, so wait for it as well. A change to
`.github/workflows/` also passes `actionlint`.

## Docs

`docs/` holds the operator documentation by topic, and the unit suites read it. `docs-content/`
holds the same material arranged for docs.cosyte.com: intro, installation, quickstart, how-to
guides, explanation, reference, troubleshooting, and the testing and performance pages, with
`docs-content/sidebars.json` listing each page once. A change to what a reader of `docs/` sees
goes into the matching `docs-content/` page in the same pull request. No em or en dash, and a
brace or an angle bracket outside code is written in code, since the site compiles each page as
MDX.

## Data

This repository is public. Use placeholder names only (`me/x`, `myproj`, `acme/*`, "the owner"):
never a person, a private repository, a host, an email address, a LAN address, or an internal
work-item ID. Real patient data and real credentials never enter a file, a fixture, a log, or an
issue.
