# Volume / mount reference

| Path in container | Source | Scope | Holds |
|---|---|---|---|
| `/auth` | `claude-auth` volume | shared | `.credentials.json` (OAuth) |
| `/etc/ssh/host-keys` | `claude-sshkeys` volume | shared | SSH host keys (stable fingerprint) |
| `/home/claude/.claude` | `claude-config-<proj>` volume | per container | Sessions, history, merged config, plugins |
| `/workspace` | `claude-ws-<proj>` volume *or* `--workspace` bind | per container | The git repo |
| `/scratch` | `claude-scratch-<proj>` volume; a RAM tmpfs on `--browser` and `--gpu` services | per container | **`TMPDIR`**: disk-backed temp. Cleared on every boot; `claude-rm --purge` deletes it |
| `/state` | `claude-state-<proj>` volume | per container, mounted in no other | **Private state** (`CLAUDE_STATE_DIR`): an app's databases, keys and tokens, under `/state/<app>`. Mode 700. `claude-rm --purge` and `compose down -v` delete it |
| `/cache` | `claude-cache` volume | shared, readable from every container | Tool installs and package caches (mise, cargo, go, npm, uv, pip) and the pinned Blender (`/cache/blender`). Never private state |
| `/tmp` | tmpfs (**RAM**, 1 GB) | per container | Small temp only. Charged to the memory cgroup: big writes belong in `/scratch` |
| `/etc/claude/authorized_keys` | host `SSH_AUTHORIZED_KEYS` | read-only, in root-only `/etc/claude` | Who may SSH in: the owner's login keys, never the git key |
| `/etc/claude/git-key` | host `GIT_SSH_KEY` | read-only, in root-only `/etc/claude` | Git push key: brokered, and refused for SSH logins (`/etc/ssh/revoked_keys`) |
| `/opt/claude-config` | baked into image | image | Bake-in template merged on start |

Anything baked in is overridable by mounting onto the target path (e.g. mount
your own `CLAUDE.md` onto `/home/claude/.claude/CLAUDE.md`).

## Private state

`/cache` is one volume shared by every container on the host, and every container runs as
the same user (UID 1000). Whatever one container keeps there, every other container can read:
that is the point for a toolchain or a package archive, and a leak for a database, a key or
a token. Keep those in `/state`, the container's own `claude-state-<proj>` volume:

- `claude-launch` and `claude-compose-gen` mount it at `/state` in that container only and
  set `CLAUDE_STATE_DIR=/state`; `~/.bash_profile` exports it for SSH logins too.
- `claude-compose-gen --mount` refuses another container's `claude-state-*` (or
  `claude-config-*`) volume, so one container's state is never mounted into another.
- The entrypoint keeps it owned by the agent user, mode 700, and logs at boot whether it
  is a volume. A container created before `/state` existed (an older compose file, or a
  `claude-launch` container that was only restarted) has no volume there: regenerate and
  recreate it, or `claude-rm` and relaunch.
- An app should keep its files in `$CLAUDE_STATE_DIR/<app>` and fall back to its old path
  only when `CLAUDE_STATE_DIR` is unset.

### Moving state out of `/cache`

At every boot the entrypoint looks for files that look like a database or a key
(`*.db`, `*.sqlite*`, `*.key`, `*.pem`, `*token*`, `*credential*`) under
`/cache/<app>/<container name>/`, the layout apps used before `/state`, and names them in
`docker logs` with a `PRIVATE STATE IN THE SHARED CACHE` banner. It never moves them: the
app would not know the new place and would start an empty one at the old path. Move them
yourself, while no process has them open:

```bash
# 1. Give the app its new place (its own setting, e.g. a line
#    `--env <svc>=APP_HOME=/state/<app>` in the scenario .conf) and regenerate the stack.
claude-compose-gen --scenario <stack>/<stack>.conf

# 2. Stop the service, then recreate it from the new compose WITHOUT starting it: this
#    creates claude-state-<svc>, and nothing writes the old files while they are copied.
docker compose -f <stack>/docker-compose.yml stop <svc>
docker compose -f <stack>/docker-compose.yml up --no-start --force-recreate <svc>

# 3. Copy the app's folder into the state volume, owner and modes kept. The helper is the
#    only other container that ever mounts this state volume, and it is removed at exit.
docker run --rm --user 0 --entrypoint bash \
  -v claude-cache:/cache -v claude-state-<svc>:/state claude-code-box:latest \
  -c 'mkdir -p /state/<app> && cp -a /cache/<app>/<svc>/. /state/<app>/ && chown -R 1000:1000 /state/<app>'

# 4. Start it and check the app works from its new place.
docker compose -f <stack>/docker-compose.yml start <svc>

# 5. Only then delete the old copy, which every container can still read:
docker run --rm --user 0 --entrypoint bash -v claude-cache:/cache claude-code-box:latest \
  -c 'rm -rf /cache/<app>/<svc>'
```
