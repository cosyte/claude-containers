# claude-containers

The Docker image, its host launchers (`bin/claude-launch`, `bin/claude-compose-gen`) and the
in-container tools that run isolated, long-lived Claude Code sessions. Infrastructure, not a
library: bash, `make` and Docker, no runtime dependencies (`package.json` is only a task runner).
`README.md` is the operator's documentation, `docs/` holds the long sections, and `CARD.md` says
what this repo offers to sibling repos.

## Gate

From the repo root, in this order. The required checks `ci` and `no-emdash` run the same.

1. `mise install`: once, for the `shellcheck` and `hadolint` that `make lint` needs (`mise.toml`).
2. `npm run lint`: `make lint` (`bash -n`, `shellcheck -S warning`, `hadolint`), then
   `scripts/check-no-emdash.sh` over every tracked file.
3. `npm test`: `test/run-all.sh` runs every unit suite in parallel, no Docker.

`no-emdash` also reads the PR title, body and commit messages: before pushing, pipe them through
`bash scripts/check-no-emdash.sh --stdin "PR text"`.

CI's `smoke` job builds the image and runs `test/smoke.sh` when a PR touches an image path (the
list is in `.github/workflows/ci.yml`). Sessions have no Docker, so it runs only in CI: on such a
PR, wait for `smoke` to pass as well.

## Hazard

Every agent session on the owner's hosts runs in this image and boots through `entrypoint.sh`. A
bad image or entrypoint breaks all of them at once, and they stay broken until a fixed image is
built and they restart on it: one bad credential write in the entrypoint once took Remote Control
down in every container (#36). Treat a change to the `Dockerfile`, `entrypoint.sh`,
`entrypoint.d/`, `bin/` or `claude-config/` as a change to every session.

## Rules

- Public repo: placeholder names only (`me/x`, `myproj`, `acme/*`, "the owner"); never a person,
  a private repo, a host, an email, a LAN address or an internal work-item ID (#39, #41, #42).
- Root trusts nothing the agent can write: in agent-owned paths it writes a fresh `mktemp` file
  and renames it in with `mv -T`, never through a symlink, on a system-only PATH (#118, #120, #122).
- A new launcher flag or `CLAUDE_*`/`GIT_*` variable gets its docs in the same PR;
  `test/docs-unit.sh` fails without them (#93, after the docs had drifted from the code).
