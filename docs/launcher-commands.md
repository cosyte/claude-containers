# Launcher commands

```
claude-launch <name> [--repo URL [--repo URL[#BRANCH]]... | --workspace PATH] [--branch B] [--depth N]
                      [--port N] [--model NAME] [--mcp NAME ...] [--browser|--no-browser]
                      [--gpu|--no-gpu]
                      [--extra-args "…"] [--expose H:C ...] [--dev-cmd "…"]
                      [--session "NAME [key=value ...]" ...] [--env KEY=VALUE ...]
                      [--image REF] [--cache VOLUME | --no-cache] [--accounts NAMES]
                      [--marketplace NAME=URL[#REF] ...] [--plugin PLUGIN[,...] ...] [--start-cmd "…"]
claude-tui                        interactive whiptail menu over the whole fleet: per-session
                                   (attach/start/stop/restart/logs/remove/launch), grouped by
                                   compose stack (bring up a dormant repo, switch a stack's auth
                                   account, regenerate its compose), plus an Accounts screen
                                   (view/log in named OAuth accounts) and disk maintenance.
                                   Discovers stacks live from `com.docker.compose.project`
                                   labels; set CLAUDE_TUI_STACKS to pre-seed one with no
                                   containers created yet. Wraps the commands below; no new logic.
claude-list                       table of all containers (SESSIONS = named sessions up, from the healthcheck)
claude-list --json                the same as one JSON array (needs jq)
claude-attach <name> [session]    attach to its live tmux session (local host), on a named
                                   session's window if given
claude-sessions -C <name> CMD     manage the sessions inside a container from the host
                                   (ls, new, start, stop, restart, send, ...; see below)
claude-stop  <name>               graceful stop (state preserved)
claude-rm    <name> [--yes] [--purge]   remove (+volumes with --purge)
claude-logs  <name> [-n LINES]    tail the entrypoint/sshd log
claude-disk-gc [--loop]           GC docker image/build-cache layers + trim the shared cache
claude-disk-verify                prove disk-hygiene logic (docker-free, safe anywhere)
claude-image-rebuild --check      JSON: the image's revision and CLI, and how far behind main
claude-image-rebuild [--dry-run]  pull main (clean checkout on main only), rebuild the image
```

`claude-image-rebuild` runs on the host in the checkout it lives in. `--check [--image TAG]`
fetches origin (30 s at most) and prints one line,
`{"image","revision","dirty","cli_version","main","behind","checkout_clean"}`, from the
image's provenance labels: `behind` is the commits on `origin/main` past the image's
revision, `null` when the image has no revision label (an older build) or the commit is not
in the checkout. Exit 2 when the image does not exist. The default refuses a checkout that
has changes or is not on `main` (exit 3), runs `git pull --ff-only`, then `make build`, or
`make build-browser` when the image is labelled `claude.browser=1`, for the same tag
(`--image`, default the Makefile's `CLAUDE_IMAGE`), and prints the old and new revision and
CLI version. It only builds: it never recreates or touches a container and never cleans up
images, so running sessions keep the old image until something recreates them. Run it when
you choose to; nothing schedules it.

`claude-list` ends with two columns on each container's image: IMAGE, the short
commit it was built from (`-dirty` when built from a checkout with changes,
`unknown` for an image without the labels), and BEHIND, how many commits
`origin/main` of the checkout `claude-list` runs from has past it, as last fetched
(it never fetches; `claude-image-rebuild --check` does). BEHIND is `?` for an
unlabelled image or a commit that checkout does not have. `--json` carries the
same as `image_revision`, `image_dirty`, `image_cli_version` and `behind_main`
(`null` where the table shows `?`; `"unknown"` for an unlabelled revision or CLI
version, as `claude-image-rebuild --check` prints them).

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
                   [--cpu REPO=N]... [--mem REPO=SIZE]... [--pids REPO=N]... [--model REPO=MODEL]...
                   [--browser REPOS]... [--gpu REPOS]...
                   [--group NAME=REPO[:BRANCH],REPO[:BRANCH],...]...
                   [--marketplace REPO=NAME=URL]... [--plugin REPO=PLUGIN[,...]]...
                   [--include GLOB] [--exclude GLOB] [--forks] [--archived]
                   [--scenario FILE] [--env-file FILE] [--port-base N] [--limit N]
                   [--all-dormant] [--network NAME] [--cache VOLUME | --no-cache]
                   [--mount REPO=VOLUME:/PATH[:ro]]... [--build-context DIR]
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

**Runtime plugin marketplaces.** `--marketplace REPO=NAME=URL[#REF]` and
`--plugin REPO=PLUGIN[,…]` write `CLAUDE_EXTRA_MARKETPLACES` /
`CLAUDE_EXTRA_PLUGINS` onto a service. The entrypoint merges these into
Claude Code's `settings.json` on every boot and installs the plugins before
any session starts: no image rebuild, no manual edit. A declared marketplace
replaces the `settings.json` entry of that name; for `enabledPlugins` an
existing value wins (a plugin you switched off stays off). Same syntax as the
single-container `claude-launch --marketplace` / `--plugin`, with a `REPO=`
prefix to say which service. With `--start-cmd` this is the kit hook: see
[Install a kit at session start](../README.md#install-a-kit-at-session-start).

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

### Flags not shown above

`claude-launch`:

- `--image REF`: the image to run, over `CLAUDE_IMAGE` (default `claude-code-box:latest`).
  It must exist locally; only the default image builds itself. E.g. `claude-code-box:browser`.
- `--cache VOLUME` / `--no-cache`: the shared tool cache volume at `/cache` (default
  `claude-cache`), or none. Private state is separate: `/state` is always this container's own.

`claude-compose-gen`:

- `--scenario FILE`: read flags from a scenario `.conf`, one `--flag value` per line
  (`scenarios/example.conf.example`); flags after it on the command line override or append.
- `--env-file FILE`: source this env on top of the repo `.env` while generating. Point it at the
  `.env` beside `--out`, so the generated file and `docker compose` read the same values.
- `--port-base N`: the first SSH host port (default `SSH_PORT_RANGE_START`).
- `--pids REPO=N`: the pids limit for one service, over `CLAUDE_PIDS_LIMIT`. Threads count as
  pids, so a service running several sessions and parallel test suites needs more.
- `--limit N`: how many repos `gh repo list` returns for `--org` (default 500).
- `--all-dormant`: put every service behind the dormant profile, so a plain `up -d` starts
  nothing. Do not combine it with `--active`: the named repos would still start.
- `--network NAME`: attach every service to an existing external network (create it first with
  `docker network create NAME`) instead of the stack's own `<project>_default`, so several
  stacks share one network.
- `--cache VOLUME` / `--no-cache`: as for `claude-launch`, one volume for the whole stack.
- `--mount REPO=VOLUME:/PATH[:ro]`: mount an existing named volume into one service, e.g.
  another stack's checkout read-only. The volume is declared external, so `down -v` never
  deletes it.
- `--build-context DIR`: `build.context` for every service (default: the checkout the generator
  runs from). Pin it when the deployment builds from a different clone.

### Removed flags

`--docker`, `--no-docker`, `--sysbox`, `--broker` and `--worker-tarball` were removed from both
launchers with the per-session Docker engine and the Sysbox worker broker. Each still exits with
an error that says so: see [legacy-sysbox-broker.md](legacy-sysbox-broker.md).
