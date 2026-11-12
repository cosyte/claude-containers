---
id: run-containers-in-a-session
title: Run containers in a session
sidebar_label: Run containers in a session
description: "Let one session build images and run containers and compose stacks with rootless podman, keeping the session's hardening."
---

# Run containers in a session

A session cannot build or run containers by default. `--containers` gives one session rootless
podman, run by the `claude` user, with `docker` and `docker compose` driving it. It is opt-in per
session and off by default. Read the cost in [Containers in sessions](./containers-in-sessions.md)
before you turn it on: in such a session a bug in a root-side process is a host escape, not a
container escape.

## Check the host

`claude-launch --containers` refuses, and `claude-compose-gen` warns, when the host lacks one of
these:

- `/dev/net/tun` (the `tun` module);
- on Ubuntu 23.10 and later, `kernel.apparmor_restrict_unprivileged_userns=0`. Set it as root
  with `sysctl -w kernel.apparmor_restrict_unprivileged_userns=0`, and persist it in
  `/etc/sysctl.d/`. Debian hosts do not set it.

## Turn it on

For a standalone container:

```bash
claude-launch myproj --repo "<git URL of your repo>" --containers
```

An SSH URL authenticates with the git deploy key, an HTTPS URL to a private repo needs `GH_TOKEN`,
and a public repo clones over HTTPS with neither: [Which git URL to
give](./installation.md#which-git-url-to-give).

For one service of a stack:

```bash
claude-compose-gen --out /srv/claude/compose.yml --containers x me/x
```

The options are fixed when the container is created, so an existing container takes them only
when it is recreated.

## Use it inside the session

`podman`, `docker build`, `docker run` and `docker compose up` work as the agent. `DOCKER_HOST` is
`unix:///run/user/1000/podman/podman.sock` in every pane and SSH login, and the session's managed
memory carries a short note saying so. Short image names resolve on Docker Hub. A published port
(`-p 8080:80`) listens inside the session's network namespace.

The boot log's `Containers` line says whether the uid-map helper and the podman socket came up
within 10 seconds; their logs are in `/var/log/claude-containers/`.

## Free the image store

The image store is a volume, `claude-containers-<name>`, kept across restarts and neither sized
nor reaped. Run `podman system prune` inside the session, or remove the volume with
`claude-rm <name> --purge` (or `docker compose down -v` for a stack).

## Related

- [Containers in sessions](./containers-in-sessions.md): the options this adds, what each gives
  up, and the prototype it rests on.
- [Launcher commands](./launcher-commands.md) and [Volumes and mounts](./volumes-and-mounts.md).
