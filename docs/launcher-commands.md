## Launcher commands

```
claude-launch <name> [--repo URL | --workspace PATH] [--branch B] [--depth N]
                      [--port N] [--model NAME] [--mcp NAME ...] [--browser|--no-browser]
                      [--extra-args "…"] [--expose H:C ...] [--dev-cmd "…"]
claude-tui                        interactive whiptail menu over the whole fleet: per-session
                                   (attach/start/stop/restart/logs/remove/launch), grouped by
                                   compose stack (bring up a dormant repo, switch a stack's auth
                                   account, regenerate its compose), plus an Accounts screen
                                   (view/log in named OAuth accounts) and disk maintenance.
                                   Discovers stacks live from `com.docker.compose.project`
                                   labels; set CLAUDE_TUI_STACKS to pre-seed one with no
                                   containers created yet. Wraps the commands below; no new logic.
claude-list                       table of all sessions
claude-attach <name>              attach to its live tmux session (local host)
claude-stop  <name>               graceful stop (state preserved)
claude-rm    <name> [--yes] [--purge]   remove (+volumes with --purge)
claude-logs  <name> [-n LINES]    tail the entrypoint/sshd log
claude-disk-gc [--loop]           GC docker image/build-cache layers + trim the shared cache
claude-disk-verify                prove disk-hygiene logic (docker-free, safe anywhere)
```

`claude-launch --broker` used to spawn autonomous nested workers via a root-owned broker.
That substrate is retired: see [docs/legacy-sysbox-broker.md](legacy-sysbox-broker.md).
The flag now errors rather than silently doing nothing.

Inside an autopilot container (over SSH), `claude-enqueue "<prompt>"` adds a task
to the durable queue (`CLAUDE_AUTOPILOT_QUEUE=1`); `--priority N` orders it
(lower runs sooner), and a prompt can also be piped on stdin.

`--expose HOST:CONTAINER` publishes an extra port (e.g. a dev server) and
`--dev-cmd` auto-starts a command on boot in a tmux `dev` window: the
single-container equivalents of `claude-compose-gen`'s `--expose`/`--dev-cmd`.
Resuming a stopped container reuses its creation-time env, ports, and mounts,
so changed `.env` values or new launch options need a `claude-rm` + relaunch.

`make launch ARGS="…"`, `make stop ARGS="…"` etc. wrap these if you prefer Make.

### Many repos at once

`claude-compose-gen` writes a multi-service `docker-compose.yml` with one
session container per repo in a GitHub org:

```
claude-compose-gen --org ORG --out FILE [--active REPOS]... [--dormant-profile NAME]
                   [--expose REPO:HOSTPORT:CONTAINERPORT]...
                   [--dev-cmd REPO=COMMAND]...
                   [--cpu REPO=N]... [--mem REPO=SIZE]... [--model REPO=MODEL]...
                   [--browser REPOS]...
                   [--marketplace REPO=NAME=URL]... [--plugin REPO=PLUGIN[,...]]...
                   [--include GLOB] [--exclude GLOB] [--forks] [--archived]
claude-compose-gen --out FILE repo-a repo-b:dev      # explicit list, no gh needed
```

`--out` must be a path **outside this repo** (a deploy location); the
generator refuses to write inside the repo. **SSH ports are stable**: when
`--out` already exists each repo keeps its previously assigned port and only
new repos take the next free one, so adding a repo never reshuffles running
containers. `--expose` publishes a dev-server port for a repo; `--dev-cmd`
auto-starts that dev server on container boot in its own tmux `dev` window.

Two gotchas the example below handles (both bit us in practice):

- The dev server must bind **`0.0.0.0`**, not localhost, or the published
  port reaches nothing inside the container.
- `npm run <script>` needs `-- ` before forwarded flags; `pnpm`/`yarn`
  forward them **without** `--` (passing a literal `--` makes Astro/Vite
  ignore `--host` and silently bind localhost). So detect the package
  manager. `pnpm`/`yarn`/`npm` are baked into the image: no runtime
  package-manager download.

Verified working example (Astro/Vite/Next dev server, any package manager):

```
claude-compose-gen --org ORG --out FILE --active my-site \
  --expose my-site:4321:4321 \
  --dev-cmd 'my-site=if [ -f pnpm-lock.yaml ]; then PM=pnpm; SEP=; elif [ -f yarn.lock ]; then PM=yarn; SEP=; else PM=npm; SEP=--; fi; [ -d node_modules ] || $PM install; exec $PM run dev $SEP --host 0.0.0.0 --port 4321'
```

Then `http://<host>:4321` serves the live dev site; SSH in and
`tmux select-window -t claude:dev` to watch its output (`claude-dev` reruns
it).

**Runtime plugin marketplaces.** `--marketplace REPO=NAME=URL` and
`--plugin REPO=PLUGIN[,…]` write `CLAUDE_EXTRA_MARKETPLACES` /
`CLAUDE_EXTRA_PLUGINS` onto a service. The entrypoint merges these into
Claude Code's `settings.json` on every boot: no image rebuild, no manual
edit. Existing `settings.json` entries win on conflict (so per-container user
choices stick). Same syntax as the single-container `claude-launch
--marketplace` / `--plugin`, with a `REPO=` prefix to say which service:

```
./bin/claude-compose-gen --org ORG --out FILE --active site \
  --marketplace site=claude-skills=git@github.com:org/crew.git \
  --plugin 'site=software-engineering@claude-skills,data@claude-skills'
```

It enumerates via an authenticated `gh` (scopes `repo` + `read:org`) or takes
explicit `repo[:branch]` args, assigns stable SSH ports from the configured
range, shares `claude-auth`/`claude-sshkeys` with per-repo config/workspace
volumes, and labels services so they still show up in `claude-list`.

**Resource-conscious by default.** `--active` marks the repos that should
start with a plain `docker compose up -d`; every other repo is still defined
but placed behind a Compose profile (`dormant`), so it consumes zero
resources until you ask for it:

```
claude-compose-gen --org ORG --out FILE --active repo-a --active repo-b,repo-c
docker compose -f FILE up -d                       # just the active ones
docker compose -f FILE up -d repo-x                # one dormant repo, on demand
docker compose -f FILE --profile dormant up -d     # everything
docker compose -f FILE stop repo-a                 # free its resources
```

With no `--active`, all repos start (backward compatible). Regenerate any time
the repo or active set changes: ports stay stable (services sorted by name),
so a repo keeps its port whether active or dormant.
