---
id: volumes-and-mounts
title: Volumes and mounts
sidebar_label: Volumes and mounts
description: "Every path a container mounts, its source and scope, and the rules for private state."
---

# Volumes and mounts

| Path in container | Source | Scope | Holds |
|---|---|---|---|
| `/auth` | `claude-auth` volume | shared | `.credentials.json` (OAuth) |
| `/etc/ssh/host-keys` | `claude-sshkeys` volume | shared | SSH host keys (stable fingerprint) |
| `/home/claude/.claude` | `claude-config-<proj>` volume | per container | Sessions, history, merged config, plugins |
| `/workspace` | `claude-ws-<proj>` volume *or* `--workspace` bind | per container | The git repo |
| `/scratch` | `claude-scratch-<proj>` volume; a RAM tmpfs on `--browser` and `--gpu` services | per container | **`TMPDIR`**: disk-backed temp. Cleared on every boot; `claude-rm --purge` deletes it |
| `/state` | `claude-state-<proj>` volume | per container, mounted in no other | **Private state** (`CLAUDE_STATE_DIR`): an app's databases, keys and tokens, under `/state/<app>`. Mode 700. `claude-rm --purge` and `compose down -v` delete it |
| `/home/claude/.local/share/containers` | `claude-containers-<proj>` volume, on `--containers` sessions only | per container | Rootless podman's images, containers and their volumes. Kept across restarts; `claude-rm --purge` and `compose down -v` delete it |
| `/cache` | `claude-cache` volume | shared, readable from every container | Tool installs and package caches (mise, cargo, go, npm, uv, pip) and the pinned Blender (`/cache/blender`). Never private state, and never a worktree, a clone or a working folder |
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
  is a volume. The boot owns `/state` and its top level only; the rest of the tree (the
  worktrees under `/state/wt`, say) is checked in the background once the sessions are up,
  as the workspace is, so a deep `/state` never holds the boot. Until that pass reaches it, a
  deeper file with a foreign owner is read-only to the agent. A container created before `/state` existed (an older compose file, or a
  `claude-launch` container that was only restarted) has no volume there: regenerate and
  recreate it, or `claude-rm` and relaunch.
- An app should keep its files in `$CLAUDE_STATE_DIR/<app>` and fall back to its old path
  only when `CLAUDE_STATE_DIR` is unset.

How to move an app's files, or a worktree, out of `/cache`:
[Move private state out of the shared cache](./move-private-state.md).
