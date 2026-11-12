---
id: performance
title: Performance
sidebar_label: Performance
description: "What sets how fast a session works and how many fit on a host, how to size a container, and why we publish no benchmark for the image."
---

# Performance

The image runs Claude Code and the tools a session starts; it does little work of its own. How fast
a session works depends on the model, on the network, and on the CPU, memory and disk the container
is given, so we publish no benchmark for the image. What we can say is what each limit does and how
to size it.

## What sets a session's speed

- **CPU and memory limits**, `CLAUDE_CPU_LIMIT` and `CLAUDE_MEM_LIMIT` (2 CPUs and `4g` by
  default), with a memory reservation below the limit and a pids limit. Builds and tests the agent
  runs in `/workspace` share them with Claude Code itself.
- **Several sessions in one container share those limits.** The boot log's `Capacity:` line says
  what each session gets and warns under 1 GiB each; a Claude process alone uses a few hundred MiB.
  Raise the memory and pids limits with the session count:
  [Run several sessions in one container](./run-several-sessions.md).
- **Thread pools are capped per process** (`CLAUDE_THREADS_PER_PROCESS`, 4 by default), because
  libraries size them to the host rather than to the container. The image's `nproc` prints the
  container's CPU quota for the same reason, and Gradle gets a share of it.
- **Temp space.** `/tmp` is a 1 GB RAM tmpfs charged to the memory limit, so large temp writes go
  to `/scratch`, on disk by default: [Temp space on /scratch, not /tmp](./temp-space.md).
- **The shared tool cache.** A toolchain one container installed is a cache hit for every other
  container on the host, so the second install of the same version downloads nothing:
  [The shared tool cache](./shared-tool-cache.md).

## What sets the boot time

- The entrypoint owns the top level of the workspace and `/state` before the sessions start, and
  walks the rest of the tree in the background afterwards, so a large workspace does not hold the
  boot.
- Each start installs npm's latest Claude Code before any session runs, unless
  `DISABLE_AUTOUPDATER=1`.
- Egress lockdown resolves its allowlist at boot and adds about ten seconds.
- An umbrella workspace fetches the submodules not checked out yet, each bounded by
  `GIT_SUBMODULE_TIMEOUT`.

## How to size a container

Start from the defaults, then watch `docker stats` and the boot log while the session does its
usual work. Raise `CLAUDE_MEM_LIMIT` (or `--mem` for one service of a stack) when a container runs
several sessions, renders, or keeps `/scratch` in RAM, and raise `CLAUDE_CPU_LIMIT` (or `--cpu`)
when builds are slow. A container that is out of memory is in
[Troubleshooting](./troubleshooting.md#performance--oom).

## Current numbers

The numbers for this section are measured on `main` at each release and filled in when the release
is built. They are never typed by hand.
