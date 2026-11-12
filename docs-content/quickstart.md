---
id: quickstart
title: Quickstart
sidebar_label: Quickstart
description: "Launch a first container on a small local project, work with its session over SSH and the Claude app, stop it, resume it and remove it."
---

# Quickstart

In this tutorial we launch one container on a small project folder on the host, ask its Claude
session to change a file, stop and resume it without losing the conversation, and remove it. It
takes a few minutes once the image is built.

Before you start, finish [Installation](./installation.md): the image is built, `make login` is
done, and you are in the `claude-containers` checkout.

## 1. Make a project folder

The container works on one folder, its workspace. We make a small one on the host:

```bash
mkdir -p ~/first-project
printf '# First project\n' > ~/first-project/README.md
git -C ~/first-project init
```

A workspace must not be empty: an empty one with no repository to clone stops the container at
boot.

## 2. Launch the container

```bash
./bin/claude-launch first-project --workspace ~/first-project
```

`--workspace` bind-mounts the folder at `/workspace` in the container, so the session's changes
show on the host at once. The container runs as UID 1000, and the entrypoint gives that user the
folder's top level. To clone a repository into a volume instead, use `--repo` with its URL.

When the session is up, the launcher prints how to reach it:

```text
  SSH into the live tmux session:
      ssh -p 2200 claude@your-host

  ...or attach locally on this host (no SSH key needed):
      claude-attach first-project

  Claude mobile app: open the Code tab and look for the session named
      first-project   (green dot = online)
```

The port is the first free one from 2200 up, so yours may differ.

## 3. Talk to the session

Run the SSH line it printed, or `./bin/claude-attach first-project` on the host. Either lands you
in the running Claude Code session, inside tmux. Ask it:

```text
Add a line to README.md that says this project runs in a container.
```

When it is done, detach from tmux with `Ctrl-b d` and look at the file from the host:

```bash
cat ~/first-project/README.md
```

The line the session wrote is there.

## 4. Open it from the Claude app

Open the Claude app on your phone, go to the Code tab, and find `first-project` with a green dot.
It is the same session, with the same conversation: what you type there reaches the session you
just used over SSH.

## 5. Stop and resume

```bash
./bin/claude-stop first-project
./bin/claude-launch first-project
```

The second command takes no options: it starts the stopped container again, with the workspace and
the configuration it had. Attach again and the main session starts a fresh conversation, while the
earlier one stays in its history, where `/resume` finds it. To have the main session resume its
last conversation on every start, set `CLAUDE_MAIN_RESUME=1`.

## 6. Clean up

```bash
./bin/claude-rm first-project --purge
```

It asks before it deletes. `--purge` also deletes the container's own volumes: its configuration
and conversation history, its scratch space and its private state. The folder on the host is a bind
mount, not a volume, so `~/first-project` stays. The shared login volume stays too.

## Next

- Give a container [several repos](./run-several-repos.md) or
  [several sessions](./run-several-sessions.md).
- Let sessions push and open pull requests: [Set up the GitHub token](./set-up-the-github-token.md).
- Run many repos as one stack with `claude-compose-gen`: [Launcher commands](./launcher-commands.md).
- Every how-to guide is listed in the sidebar; [Troubleshooting](./troubleshooting.md) covers what
  goes wrong.
