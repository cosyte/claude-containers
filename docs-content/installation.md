---
id: installation
title: Installation
sidebar_label: Installation
description: "What the host needs, how to clone the repository and build the image, and the one-time login that every container shares."
---

# Installation

There is nothing to install from a registry: you clone the repository, build the image on the host
that runs the containers, and log in once.

## What the host needs

- **Linux on amd64 or arm64, with Docker Engine and the buildx plugin.** `make build` creates a
  buildx builder if there is none. The launchers warn when the host's runC is older than 1.2.8 or
  1.3.3, the releases that fixed the November 2025 container escapes; patch it first.
- **bash, git and make.** `jq` too, for `claude-list --json` and for listing an org's repos
  with `claude-compose-gen`.
- **A Claude subscription that includes Claude Code.** Sessions authenticate with it through
  OAuth; an API key is refused.
- **An SSH key pair you log in with.** Its public half goes in the file `SSH_AUTHORIZED_KEYS`
  names (default `~/.ssh/authorized_keys`). Without it the container starts with SSH disabled, and
  you reach the session with `claude-attach` on the host instead.
- **Optionally, a separate key for git.** `GIT_SSH_KEY` (default `~/.ssh/claude-git-key`) is the
  key sessions push with. Without it only public repositories, over HTTPS, can be cloned. Never use
  your login key for git: [The security model](./security-model.md) says why, and the launchers
  refuse it.

Optional features add their own host requirements: the NVIDIA Container Toolkit for
[GPU sessions](./give-a-session-the-gpu.md), and a kernel setting for
[containers in a session](./run-containers-in-a-session.md#check-the-host).

## Clone and configure

```bash
git clone https://github.com/cosyte/claude-containers.git
cd claude-containers
cp .env.example .env
```

The defaults in `.env` work as they are. The launchers read it on every run and pass it into each
container; a variable set in your shell overrides it. Write values without quotes: the file is
also read by `docker --env-file`, which keeps quotes literally. Every variable is listed in
[Environment variables](./environment-variables.md).

## Build the image

```bash
make build
```

This builds `claude-code-box:latest` (`CLAUDE_IMAGE`) for the host's architecture and loads it
into the local engine. `make build-all` builds amd64 and arm64 without loading, `make push` pushes
both to the registry `CLAUDE_IMAGE` names, and `make build-browser` builds the browser variant
described in [Debug a frontend from a session](./debug-a-frontend.md).

## Log in once

```bash
make login
```

It prints a URL. Open it in a browser on any machine, sign in, and paste the code back into the
terminal. The credentials land in the `claude-auth` volume, which every container mounts, so you
do this once per host, not once per container. `make login` builds the image first if it is not
there yet.

Put `bin/` on your `PATH` if you want to run the launchers without the `./bin/` prefix.

## Next

The [Quickstart](./quickstart.md) launches your first container. When the image falls behind
`main`, `claude-image-rebuild` pulls and rebuilds it ([Launcher commands](./launcher-commands.md)).
