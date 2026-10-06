# claude-containers card

For agents in sibling repos: what this repo offers, how to hand it work, and what it does not do.
The Docker image, launchers and session tools that run isolated Claude Code sessions.

## Offers

- The image: `Dockerfile` + `entrypoint.sh` (boot path, numbered sections); `make build`.
- Host CLIs in `bin/`: `claude-launch` (one container), `claude-compose-gen` (a stack from a
  scenario `.conf`), `claude-list`, `claude-attach`, `claude-stop`, `claude-rm`, `claude-logs`,
  `claude-account-login`, `claude-disk-gc`.
- In-container tools in `bin/`: `claude-sessions` (several sessions per container),
  `claude-kit` (installs a plugin marketplace at boot), `claude-gpu` + `claude-blender-install`
  (GPU guard), `claude-deps-check` (pin linter), `claude-autopilot` + `claude-enqueue`
  (unattended mode, its queue), `claude-egress-firewall`, `claude-secret-guard`.
- Baked-in config every session gets: `claude-config/` (global `CLAUDE.md`, `CLAUDE.gpu.md`,
  `settings.json`, `skills/`, `commands/`, `mcp/`, `plugins/`).
- Operator docs: `README.md` (load-bearing) and `docs/*.md`.

## Hand it work

`goals task add claude-containers "<title>" --project <id> --body-file <spec>`

A spec for this repo must contain:

- **Why**: the problem, in one or two lines.
- **Change**: the exact behaviour, flag, variable or file, with its name and default.
- **Surfaces**: which of image, `entrypoint.sh`, `bin/<tool>`, `claude-config/`, docs it touches.
- **Done when**: the observable result, and the unit suite (`test/<area>-unit.sh`) that proves it.
- **Compat**: what happens to existing containers and `.env` files (a removed flag must refuse).

```
Why: <problem>
Change: <flag/variable/file, name, default>
Surfaces: <image | entrypoint | bin/... | claude-config | docs>
Done when: <observable result>; test/<area>-unit.sh covers it
Compat: <old containers / .env behaviour>
```

## Interfaces

- Session spec `NAME [key=value ...]` (`CLAUDE_SESSIONS`, `--session`): `README.md`,
  Several sessions in one container.
- Kit hook `CLAUDE_EXTRA_MARKETPLACES` / `_PLUGINS` / `_START_CMD`: `README.md`,
  Install a kit at session start.
- Environment variables: `README.md` table, full list in `.env.example`.
- Scenario `.conf` format (one generator flag per line): `scenarios/example.conf.example`.
- Claude Code version pin: `Makefile` `CLAUDE_CODE_VERSION` and its other declarations, kept equal
  by `test/cli-version-unit.sh`.
- Baked global `CLAUDE.md` content contract: `test/pkg-install-guide-unit.sh`.
- Gate: `npm run lint` + `npm test` (CI checks `ci`, `no-emdash`); `make smoke` locally.

## Not here

- Goal programs, task queues and the planning harness: an outside kit, installed through the
  kit hook. Ask that repo.
- Project code, deployment scenario `.conf` files and stack `.env` files: the owner's deployment
  repos, never this public one.
- Reusable library code: the shared-code repo, not this one (bash + make + Docker, no deps).
