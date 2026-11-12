---
id: testing-and-quality
title: Testing and quality
sidebar_label: Testing and quality
description: "How we test the image, the launchers and the entrypoint: lint, Docker-free unit suites, a smoke test of the built image, and what none of them can catch."
---

# Testing and quality

claude-containers is bash, `make` and Docker, so its tests are bash too. Every pull request runs
the gate below, and the image itself is built and tested whenever a change can affect it. Every
session on a host boots through the same entrypoint, so a bad change there breaks all of them at
once; the tests are weighted toward the boot path for that reason.

## What we check

- **Lint**, `make lint`: `bash -n` over every script, `shellcheck -S warning`, and `hadolint` over
  the Dockerfile, at the versions `mise.toml` pins.
- **No em or en dash** in any tracked file (`scripts/check-no-emdash.sh`), and, in a check that
  reports without blocking, in the pull request's title, body and commit messages.
- **The unit suites**, `test/unit.sh` and every `test/*-unit.sh`, run in parallel by
  `test/run-all.sh` with a time limit on each. They need no Docker: they run the launchers, the
  entrypoint's sections and the in-container tools against stubs and fakes, and assert what each
  would do. Several of them read the docs as well: a launcher flag or a `CLAUDE_*` variable with
  no documentation fails, and so does a relative link that names no file.
- **The smoke test**, `test/smoke.sh`, builds the image and runs real containers from it: the
  entrypoint's guards, the merge of the baked-in configuration, workspace trust, tmux, sshd and an
  SSH login, the git-key broker, egress lockdown over IPv4 and IPv6, managed settings, the
  browser variant, several repos in one workspace, the GPU-unusable path, and a `--containers`
  session that builds an image and brings up a compose stack. In CI it runs on every pull request
  that touches an image path, on every push to `main`, and nightly.
- **Workflows**: `actionlint` over every workflow file, CodeQL over the workflows (it has no bash
  analyser), and OpenSSF Scorecard weekly.
- **Pull request titles** follow Conventional Commits, since a squash merge makes the title the
  commit.

`make gate-quick` runs lint, the dash scan and the unit suites, the same as CI's `ci` job, and
needs no Docker. `make smoke` builds the image and runs the smoke test locally.

## What they cannot catch

- **The OAuth login and the Claude app.** `make login` is interactive, and whether a session shows
  in the app with a green dot depends on the account. The smoke test lists both as manual checks
  at its end.
- **A GPU that works.** CI runners have no NVIDIA GPU, so the smoke test proves the degraded path
  and skips the live one; the live check needs a host with the toolkit's CDI device.
- **The host it runs on.** A host kernel, Docker version, storage driver or runC release we have not
  tried can behave differently. The launchers check what they can (the runC version, the CDI
  device, the kernel setting `--containers` needs) and warn.
- **A new Claude Code release.** Each start installs npm's latest Claude Code unless
  `DISABLE_AUTOUPDATER=1`. The flags the image relies on are verified against the pinned version;
  a later release can change them before we re-verify.
- **What an agent does inside its container.** The tests prove the containment is in place, not
  that it holds against every attack: [The security model](./security-model.md) is explicit about
  that boundary.

## Current numbers

The numbers for this section are measured on `main` at each release and filled in when the release
is built. They are never typed by hand.
