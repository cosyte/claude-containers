---
id: move-private-state
title: Move private state out of the shared cache
sidebar_label: Move private state
description: "Move an app's database or keys, and a worktree or clone, from the shared /cache volume into the container's private /state."
---

# Move private state out of the shared cache

`/cache` is readable from every container on the host, so a database, a key, a token, a worktree
or a clone kept there is readable from all of them. `/state` is the container's own volume, which
no other container mounts. Why the two differ is in
[Volumes and mounts](./volumes-and-mounts.md#private-state). This page moves what is in the
wrong place.

## Move an app's files

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

## Move a worktree, a clone or a working folder

A worktree or a clone of a private repository, a planning folder, a key a test generated, a
term list kept out of git: each is as private as a database, and every container can read it
in `/cache`. Keep the ones that must last under `/state` (`/state/wt/<repo>/<branch>` for
worktrees, `/state/tmp` for working folders), and throwaway ones in `/scratch` (`TMPDIR`,
cleared at every boot). A tool, a skill or a repository's notes that tell sessions to work in
a folder under `/cache` is the leak: point it at `$CLAUDE_STATE_DIR` instead.

`git worktree move` cannot move a worktree to another volume (`rename` fails with "Invalid
cross-device link"). Copy it, then repair the link from the main repository:

```bash
# In the container, while no session works in that worktree.
mkdir -p /state/wt/<repo>
cp -a /cache/wt/<repo>/<branch> /state/wt/<repo>/
git -C /workspace/<repo> worktree repair /state/wt/<repo>/<branch>
git -C /state/wt/<repo>/<branch> status --short     # uncommitted changes came along
rm -rf /cache/wt/<repo>/<branch>
git -C /workspace/<repo> worktree prune
```

When the main repository moves too (a clone under `/cache` with worktrees), copy both, and
run the repair where the old copies cannot be seen (in a helper container that mounts only
the state volume): while the old main repository still exists, `repair` mends the old links
instead of the new ones.

## Reference

- [Volumes and mounts](./volumes-and-mounts.md)
- [Launcher commands](./launcher-commands.md)
