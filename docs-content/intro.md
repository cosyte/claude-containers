---
id: intro
title: Claude containers
sidebar_label: Overview
description: "A self-hosted Docker image and launchers that run isolated, long-lived Claude Code sessions, reachable over SSH and from the Claude app."
---

# Claude containers

claude-containers is a self-hosted Docker image, with the host launchers and in-container tools
around it, for running several isolated, long-lived Claude Code sessions on one machine. One
container is one project: its own git workspace, its own Claude Code configuration and history,
and a session that keeps running whether or not anyone is connected. Each session is reachable
two ways at once: SSH into its persistent tmux session, and Remote Control from the Claude app's
Code tab.

It is bash, `make` and Docker. There is no package to install and no runtime dependency: you
clone the repository, build the image and run the scripts in `bin/`.

## Who it is for

- Someone who runs Claude Code for hours or days on a home server or a workstation, and wants each
  project's session to survive a closed laptop, a dropped SSH connection or a reboot.
- Someone who runs several projects in parallel and wants each one isolated from the others and
  from the host: its own filesystem, a non-root user, resource limits and dropped capabilities.
- Someone who drives sessions from a phone, through the Claude app's Remote Control.

## What it gives a session

- **One login for every container.** Authentication is your Claude subscription through OAuth,
  logged in once and shared by every container. There are no API keys: the entrypoint refuses to
  start when `ANTHROPIC_API_KEY` is set, so a session never bills per token by accident.
- **Resume without loss.** Stopping and starting a container keeps its workspace and its
  conversation history.
- **Several sessions, several repos.** One container can hold several sessions, each with its own
  Remote Control link, and several repos side by side, or an umbrella repo with its submodules.
- **Containment by default.** The git key is brokered so the agent can sign with it but never read
  it, policy settings are written where the agent cannot rewrite them, and egress can be locked
  down to an allowlist.
- **Optional extras.** A browser image for frontend debugging, NVIDIA GPU access, rootless
  containers inside a session, toolchains on demand with `mise`, and an unattended mode.

## What it is not

- **Not an official Anthropic project.** It is not affiliated with, endorsed by or supported by
  Anthropic. "Claude" and "Claude Code" are Anthropic's trademarks and are used here only to say
  what this runs. It installs the published `@anthropic-ai/claude-code` CLI, and your use of
  Claude Code and of your subscription stays subject to Anthropic's own terms. Report Claude Code
  bugs to Anthropic.
- **Not a security boundary against a fully weaponized agent.** The containment shrinks what a
  compromised session can reach; it does not make a container safe for untrusted, multi-tenant
  input. [The security model](./security-model.md) says what it does and does not cover.
- **Not a hosted service, and not supported software.** It is self-hosted infrastructure published
  as it is. Issues are read, but there is no service level and no release cadence: `main` is the
  version.

## Where to go next

- [Installation](./installation.md): what the host needs, and building the image.
- [Quickstart](./quickstart.md): your first container, from nothing to a live session.
- [Architecture and design decisions](./architecture.md): how the pieces fit, and why.
