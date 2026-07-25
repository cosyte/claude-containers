# syntax=docker/dockerfile:1

# Global ARGs (usable in FROM lines). Node 24 ("Krypton") is the active LTS as
# of 2026 and matches a verified-working Claude Code host; override with
# --build-arg NODE_VERSION=22 if needed. uv: pin a real version (e.g. 0.8.4)
# for reproducible builds; "latest" works but isn't reproducible.
ARG NODE_VERSION=24
ARG UV_VERSION=latest

# Throwaway stage: just re-exports the uv/uvx binaries (BuildKit forbids
# variable expansion directly in COPY --from=, so it goes through a stage).
FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv

# --- Base image ---------------------------------------------------------------
FROM node:${NODE_VERSION}-bookworm-slim

# --- Build-time configuration -------------------------------------------------
# CLAUDE_CODE_VERSION: pinned npm version. Minimum 2.1.52 for Remote Control.
#
# 2.1.220 (npm `latest` on 2026-07-25) is verified to support the exact launch this
# image makes — `claude --dangerously-skip-permissions --remote-control <name>`
# (bin/claude-session) — with both flags accepted TOGETHER and no interlock between
# them. That combination is the reason this ARG is pinned at all; re-verify it on any
# future bump (test/cli-version-unit.sh asserts the pin is consistent; the live
# --remote-control handshake is the on-host check, CC-CLAUDE-CODE-UPGRADE-SMOKE).
#
# ⚠️ WHAT THE 2.1.207 -> 2.1.220 BUMP CHANGES ABOUT THE MODEL. CLI 2.1.219 introduced
# Claude Opus 5 (`claude-opus-5`, 1M context) as the NEW DEFAULT Opus. The `opus` alias
# this image passes resolves to the LATEST Opus, so the fleet moves Opus 4.8 -> Opus 5
# on this bump. That is an UPGRADE and clears ADR 0009, but it is a real behavior change
# (different model, far larger context) and not a no-op — it is the headline reason to
# re-verify rather than assume. Pin CLAUDE_MODEL=claude-opus-4-8 on a container that
# must stay on 4.8. Note 2.1.219 also dropped Opus 4.7 from fast mode.
#
# WHY THE FLOOR EXISTS (CC-CLAUDE-CODE-UPGRADE): the `opus` alias resolves to the LATEST
# Opus, and Opus 4.8 shipped in CLI 2.1.154 — so the old 2.1.145 pin silently resolved
# `--model opus` (this image's default) to Opus 4.7, quietly downgrading every gate
# agent below what ADR 0009 requires. The >=2.1.154 floor below is what makes that
# downgrade impossible; it stays a floor, not an equality, and 2.1.220 clears it.
#
# Landed between 2.1.207 and 2.1.220, and relevant to this image:
#   - 2.1.211: parallel sessions no longer all log out simultaneously on wake, and
#     2.1.214 fixed feature flags going stale after a token rotation. Both are upstream
#     fixes for the exact fleet-wide auth/Remote-Control failure mode this repo worked
#     around in entrypoint.sh's reconcile guard + watchdog (PR #36). Keep the guard —
#     it covers the OAuth-credential expiry, which is a different trigger.
#   - 2.1.216: worktree-isolated subagents no longer redirect git at the shared
#     checkout. This repo replaced the retired Sysbox broker with subagents in git
#     worktrees, so that bug hit our primary parallelism path directly.
#   - 2.1.212/2.1.217/2.1.219: subagent limits moved repeatedly — a per-session spawn
#     cap (200), then a concurrency cap (20) with nesting OFF by default, then nesting
#     re-enabled to depth 3. Anything that fans out subagents should not assume the
#     2.1.207 behavior.
#   - 2.1.214: `docker` daemon-redirect flags now prompt for permission. Harmless here
#     (sessions run bypassPermissions) but it is the kind of change that would bite a
#     --docker container running a stricter permission mode.
#
# Carried forward from the 2.1.145 -> 2.1.207 bump, still accounted for here:
#   - 2.1.197: Sonnet 5 became Claude Code's OWN default model. Harmless for us only
#     because entrypoint.sh always exports CLAUDE_MODEL (default `opus`) and both
#     claude-session and claude-autopilot pass `--model` explicitly. Do not remove
#     that default without re-reading this note.
#   - 2.1.200: the `default` permission mode was renamed `Manual`; `--help` on 2.1.207 now
#     lists only acceptEdits/auto/bypassPermissions/manual/dontAsk/plan. The choice set IS
#     enforced (a bogus value is rejected), but `--permission-mode default` was verified to
#     still be ACCEPTED against the built 2.1.207 image — so existing .env files that set
#     CLAUDE_PERMISSION_MODE=default keep working. It is undocumented upstream now, so the
#     README steers operators to `manual`. Re-check this on the next bump: if `default` is
#     ever dropped, claude-session/claude-autopilot pass it straight through and the main
#     tmux pane would die on an invalid-choice refusal.
#   - 2.1.198: Remote Control is disabled when ANTHROPIC_BASE_URL points at a
#     non-Anthropic host. This image never sets it (and §1 refuses API-key auth).
ARG CLAUDE_CODE_VERSION=2.1.220
# PNPM_VERSION: pnpm baked into the image. "latest" works but isn't
# reproducible — pin a real version (e.g. 10.4.1), same as UV_VERSION.
ARG PNPM_VERSION=latest
ARG CLAUDE_USER=claude
ARG CLAUDE_UID=1000
ARG CLAUDE_GID=1000

ENV DEBIAN_FRONTEND=noninteractive

# --- System packages ----------------------------------------------------------
# build-essential/python are kept in the final image on purpose (spec requires
# them for in-container builds), which is why a separate builder stage would not
# meaningfully shrink the result — see docs/architecture.md.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg \
        git openssh-server tmux \
        ripgrep fzf jq gettext-base \
        build-essential python3 python3-venv python3-pip \
        iptables socat \
        gosu less nano vim-tiny procps; \
    # GitHub CLI from the official apt repo
    mkdir -p -m 755 /etc/apt/keyrings; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends gh; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# --- uv / uvx (multi-arch via the official distroless image) ------------------
COPY --from=uv /uv /uvx /usr/local/bin/

# --- Claude Code (npm global, NOT the native installer) -----------------------
# The native installer auto-updates and has historically done an aggressive
# startup filesystem scan that OOM'd containers. The npm global package does
# neither, so the pinned version stays pinned.
RUN set -eu; \
    # --- GUARD 1: the effective version must clear the Opus-4.8 floor -------------
    # This is NOT hygiene. `--model opus` (this image's default) resolves to the LATEST
    # Opus, and Opus 4.8 arrived in CLI 2.1.154 — so ANY build below that floor silently
    # serves Opus 4.7 and quietly downgrades every gate agent below what ADR 0009 requires.
    #
    # The floor lives HERE, in the Dockerfile, because it is the ONLY choke point every
    # build path passes through (`make build`, `docker compose build`, a compose-gen'd
    # stack, a raw `docker build`). In particular the Makefile does `-include .env` BEFORE
    # `CLAUDE_CODE_VERSION ?= …`, so an operator's gitignored `.env` — which README tells
    # them to create from .env.example, and which on an existing host still says 2.1.145 —
    # OVERRIDES the repo's bumped default and is forwarded here as --build-arg. Without
    # this guard that host keeps building the old CLI, keeps getting Opus 4.7, and every
    # test stays green (the unit suite is static and never sees .env). Fail loudly instead.
    OPUS48_FLOOR=2.1.154; \
    # Format-check FIRST: `sort -V` ranks non-numeric strings (`latest`, `abc`, `v2.1.1`)
    # ABOVE the floor, so it would fail OPEN on them. That is a plausible operator mistake,
    # not a theoretical one — the same .env.example invites `latest` for UV_VERSION and
    # PNPM_VERSION. Reject anything that is not a plain dotted-numeric version, so the
    # failure names the real problem instead of misfiring later.
    case "${CLAUDE_CODE_VERSION}" in \
        ''|*[!0-9.]*|.*|*.) \
            echo "ERROR: CLAUDE_CODE_VERSION='${CLAUDE_CODE_VERSION}' is not a dotted-numeric version." >&2; \
            echo "       Pin an exact version (e.g. 2.1.220) — 'latest' is NOT supported here:" >&2; \
            echo "       the image must be reproducible, and a floating tag cannot be floor-checked." >&2; \
            exit 1 ;; \
    esac; \
    if [ "$(printf '%s\n%s\n' "$OPUS48_FLOOR" "${CLAUDE_CODE_VERSION}" | sort -V | head -1)" != "$OPUS48_FLOOR" ]; then \
        echo "ERROR: CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION} is below the Opus-4.8 floor ($OPUS48_FLOOR)." >&2; \
        echo "       '--model opus' would silently resolve to Opus 4.7, violating ADR 0009." >&2; \
        echo "       Most likely cause: a stale .env pinning an old CLAUDE_CODE_VERSION." >&2; \
        echo "       The Makefile's '-include .env' beats its own default AND the Dockerfile ARG." >&2; \
        echo "       Fix: update (or delete) CLAUDE_CODE_VERSION in your .env, then rebuild." >&2; \
        exit 1; \
    fi; \
    npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}; \
    npm cache clean --force; \
    # --- GUARD 2: the installed binary really IS the pinned version ---------------
    # Without this the pin is decorative: a RUN that resolved `@latest`, or an npm that
    # served something else, would go unnoticed (the old line ran `claude --version` but
    # compared it to nothing).
    installed="$(claude --version | awk '{print $1}')"; \
    if [ "$installed" != "${CLAUDE_CODE_VERSION}" ]; then \
        echo "ERROR: pinned CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION} but the installed CLI reports '$installed'." >&2; \
        exit 1; \
    fi; \
    echo "Claude Code $installed installed (>= $OPUS48_FLOOR, so '--model opus' resolves to Opus 4.8)"

# Bake pnpm + yarn at build time (registry reachable here) so JS dev servers
# never need a runtime corepack/registry fetch for the package-manager binary
# itself — that download is a 10s-timeout failure point in locked-down/flaky
# container networks. `manage-package-manager-versions=false` stops pnpm from
# trying to self-switch to a repo's pinned `packageManager` version at runtime
# (which would re-introduce the same fetch); the baked pnpm is used instead.
# yarn 1.x already ships in the base image; only pnpm needs baking.
RUN npm install -g pnpm@${PNPM_VERSION} \
    && npm cache clean --force \
    && printf 'manage-package-manager-versions=false\n' > /usr/local/etc/npmrc \
    && pnpm --version && yarn --version
# `manage-package-manager-versions=false` (pnpm setting; also via env so it
# holds for any user) stops pnpm self-switching to a repo's pinned
# `packageManager` version at runtime, which would re-trigger a registry fetch.
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    npm_config_manage_package_manager_versions=false

# --- mise: rootless polyglot toolchain + CLI-binary provisioning (PKG-2) -------
# Bake `mise` so a session can provision language toolchains and prebuilt CLIs
# as UID 1000 with NO root:
#   mise use node@22 / python@3.12 / go@1.23 / rust      (language toolchains)
#   mise use aqua:owner/tool | github:owner/tool         (arbitrary prebuilt CLIs)
# `pipx:` CLIs reuse the baked `uv` automatically — mise's `pipx.uvx` defaults
# true whenever `uv` is on PATH (it is, baked above). System `.so` libraries are
# NOT in scope for mise (the curated worker-apt tier that used to close that gap,
# PKG-4, was retired in SC-5 along with the Sysbox substrate it was scoped to —
# see docs/legacy-sysbox-broker.md).
#
# Pinned + checksummed IN-REPO: this repo's whole thesis is supply-chain
# containment, so mise is NOT installed by piping a remotely-served `mise.run`
# script into a shell. Instead we download the pinned release binary straight
# from GitHub releases (github.com is already on the egress allowlist) and
# verify its SHA256 against a digest hardcoded here BEFORE installing — a
# tampered/served-wrong binary fails the build. Reproducible, not "latest".
# Bump: change MISE_VERSION and BOTH digests together, from the release's
# published SHASUMS256.txt (the `-linux-x64` / `-linux-arm64` raw-binary rows).
ARG MISE_VERSION=v2026.7.5
ARG MISE_SHA256_AMD64=5f7ab76afdf0780d12edeaa67e908094e9ccf7924cfe203e415c1cfb87bbf778
ARG MISE_SHA256_ARM64=41fcf744050bfa27f9871e2151ac6f44b5ce2741424b3d5282b92becc71e6bc4
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) misearch=x64;   sha="${MISE_SHA256_AMD64}" ;; \
      arm64) misearch=arm64; sha="${MISE_SHA256_ARM64}" ;; \
      *) echo "mise: unsupported arch '$arch'" >&2; exit 1 ;; \
    esac; \
    curl -fsSL \
      "https://github.com/jdx/mise/releases/download/${MISE_VERSION}/mise-${MISE_VERSION}-linux-${misearch}" \
      -o /tmp/mise; \
    echo "${sha}  /tmp/mise" | sha256sum -c -; \
    install -m 0755 /tmp/mise /usr/local/bin/mise; \
    rm -f /tmp/mise; \
    mise --version

# --- Shared, persistent tool cache (PKG-3) -----------------------------------
# One shared /cache tree holds mise's install store + the language package-manager
# caches, so a toolchain/CLI provisioned once is reused across container restarts
# AND across parallel workers (the ENV block below points MISE_DATA_DIR + CARGO_HOME
# + GOPATH/GOMODCACHE + the npm/uv/pip caches here). claude-launch / claude-compose-gen
# mount a SHARED named volume (default `claude-cache`) at /cache; because every
# container runs THIS image (same OS/arch), mise's cross-machine store caveat does not
# apply, so the install store is safe to share.
#
# Baked here, owned by the claude user, so the design is FAIL-SAFE by construction:
#   - Volume mounted  → docker seeds the fresh named volume from these dirs (ownership
#     preserved), and all workers share it.
#   - No volume       → /cache is just this image-layer dir: provisioning still works,
#     writes land in the container's own layer (per-container, ephemeral) — a missing
#     cache never errors a launch, it only forgoes the cross-container hit.
# Version SELECTION stays per-container (mise reads /workspace/mise.toml, a per-container
# mount), so the shared store is read-mostly: installs are content-addressed by version
# and each tool (mise/cargo/go/npm) locks its own writes — concurrent workers append to
# the shared store without corrupting each other. The re-fetchable download sub-caches
# are what claude-disk-gc --cache trims when the volume exceeds CLAUDE_CACHE_MAX_MIB;
# the installed toolchains are kept.
RUN set -eux; \
    mkdir -p /cache/mise /cache/cargo /cache/go/pkg/mod /cache/go/bin \
             /cache/npm /cache/uv /cache/pip; \
    chown -R ${CLAUDE_UID}:${CLAUDE_GID} /cache

# --- Optional: headless Chromium + chrome-devtools-mcp (frontend debugging) --
# Build with `--build-arg WITH_BROWSER=1` (or `make build-browser`) to bake a
# headless Chromium and the official Chrome DevTools MCP server. A session on
# this variant AUTO-ENABLES the chrome-devtools MCP — no second flag needed:
# the entrypoint (§10b) detects the baked binaries on PATH and registers it, so
# the agent can drive, inspect, and debug any frontend (navigate, evaluate,
# console, network, Lighthouse, screenshots, perf traces, heap snapshots — 55+
# tools). `CLAUDE_BROWSER=1`/`--browser` still force it (and fail loud on a lean
# image); `CLAUDE_BROWSER=0`/`--no-browser` opts out. Default is OFF: the lean
# image is unchanged unless you opt in. ~200 MB delta when on.
ARG WITH_BROWSER=0
# Pin to the latest verified release. Bump via the build arg.
# NOTE: must be >=1.0 — §10b passes --chromeArg=--no-sandbox, and 0.x has no
# --chromeArg option. yargs SILENTLY IGNORES unknown flags, so on 0.x the
# sandbox flag vanished and every Chrome launch died with "No usable sandbox!",
# surfacing to the agent as "Target closed" on the first tool call. The
# --help assertion below fails the build if the pin ever regresses.
ARG CHROME_DEVTOOLS_MCP_VERSION=1.6.0
RUN set -eux; \
    if [ "$WITH_BROWSER" = "1" ]; then \
        apt-get update; \
        # Debian's `chromium` package is multi-arch (amd64+arm64) and pulls in
        # every headless lib (nss, fontconfig, dbus, etc.) we'd otherwise have
        # to enumerate. The smaller `chromium-driver` (chromedriver) is not
        # needed — chrome-devtools-mcp drives Chrome via CDP directly.
        apt-get install -y --no-install-recommends chromium fonts-liberation; \
        apt-get clean; \
        rm -rf /var/lib/apt/lists/*; \
        npm install -g "chrome-devtools-mcp@${CHROME_DEVTOOLS_MCP_VERSION}"; \
        npm cache clean --force; \
        chromium --version; \
        chrome-devtools-mcp --help >/dev/null; \
        # Assert the pinned MCP actually SUPPORTS --chromeArg. Without this the
        # failure is invisible at build time (yargs drops unknown flags without
        # complaint) and only shows up as a dead browser at agent runtime.
        if ! chrome-devtools-mcp --help 2>&1 | grep -q -- '--chromeArg'; then \
            echo "FATAL: chrome-devtools-mcp@${CHROME_DEVTOOLS_MCP_VERSION} has no --chromeArg option;" >&2; \
            echo "       entrypoint.sh §10b needs it to pass --no-sandbox. Pin >=1.0." >&2; \
            exit 1; \
        fi; \
    else \
        echo "WITH_BROWSER=0 — skipping Chromium + chrome-devtools-mcp"; \
    fi
# Image-capability label: bin/claude-launch reads this to fail early (loud,
# actionable) if --browser is requested against a non-browser image. (The
# in-container entrypoint can't read its own image labels, so it auto-detects
# the variant by probing the baked binaries on PATH instead.)
LABEL claude.browser="${WITH_BROWSER}"

# --- Optional: Docker engine (the :docker image variant) -----------------------
# Build with `--build-arg WITH_DOCKER=1` (or `make build-docker`) to bake the Docker
# Engine into the image, so a session can BUILD IMAGES AND RUN CONTAINERS — Dockerfiles,
# compose stacks, testcontainers — as part of its normal work. ~400 MB delta; default OFF.
#
# History, because this ARG existed twice before under a different name: it originally
# hosted the Sysbox nested-worker-BROKER substrate (retired in SC-5), then CC-BINS deleted
# it outright, correctly observing that nothing started dockerd and nothing *could* — the
# launchers grant no --privileged and mount no docker socket, so the baked engine was
# unreachable. This variant is NOT that comeback: there is no broker, no worker plane, no
# spool. What changed is the missing piece CC-BINS named. The container now runs under
# `--runtime=sysbox-runc`, which puts the inner daemon in a USER NAMESPACE (container-root
# → an unprivileged host uid), so nested Docker needs neither --privileged nor a host
# socket mount — both remain FORBIDDEN, and both would hand a prompt-injectable agent the
# host. entrypoint.sh §5a starts the daemon; bin/claude-launch --docker selects the runtime.
#
# The broker never needed to *compose* anything, so it installed neither plugin. A session
# testing container workflows needs both, plus buildx for a modern `docker build`.
ARG WITH_DOCKER=0
RUN set -eux; \
    if [ "$WITH_DOCKER" = "1" ]; then \
        install -m 0755 -d /etc/apt/keyrings; \
        curl -fsSL https://download.docker.com/linux/debian/gpg \
            -o /etc/apt/keyrings/docker.asc; \
        chmod a+r /etc/apt/keyrings/docker.asc; \
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
            > /etc/apt/sources.list.d/docker.list; \
        apt-get update; \
        apt-get install -y --no-install-recommends \
            docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin; \
        apt-get clean; \
        rm -rf /var/lib/apt/lists/*; \
        # Prove the whole surface a session actually uses is present; the entrypoint (§5a)
        # starts dockerd. `docker compose`/`buildx` are plugins — a missing plugin is a
        # silent "unknown command" at runtime, so assert them at BUILD time instead.
        dockerd --version; docker --version; containerd --version; \
        docker buildx version; docker compose version; \
    else \
        echo "WITH_DOCKER=0 — skipping the Docker engine (lean session image)"; \
    fi
# Image-capability label: bin/claude-launch reads this to fail early (loud, actionable)
# when --docker targets an image with no engine. Orthogonal to claude.browser — both ARGs
# can be set in one build (make build-docker-browser) and each label is checked on its own.
# (The in-container entrypoint can't read its own image labels, so §5a probes PATH instead.)
LABEL claude.docker="${WITH_DOCKER}"

# --- Non-root user ------------------------------------------------------------
# The entrypoint starts as root (sshd, volume chown) then drops to this user
# for the Claude Code process via gosu.
# The node:*-slim base ships a `node` user/group at 1000:1000, so reuse
# (rename) whatever owns the requested UID/GID rather than failing on collision.
RUN set -eux; \
    if getent group "${CLAUDE_GID}" >/dev/null; then \
        groupmod -n "${CLAUDE_USER}" "$(getent group ${CLAUDE_GID} | cut -d: -f1)"; \
    else \
        groupadd -g "${CLAUDE_GID}" "${CLAUDE_USER}"; \
    fi; \
    if getent passwd "${CLAUDE_UID}" >/dev/null; then \
        old="$(getent passwd ${CLAUDE_UID} | cut -d: -f1)"; \
        usermod -l "${CLAUDE_USER}" -d /home/${CLAUDE_USER} -m \
                -s /bin/bash -g "${CLAUDE_GID}" "$old"; \
    else \
        useradd -m -u "${CLAUDE_UID}" -g "${CLAUDE_GID}" -s /bin/bash "${CLAUDE_USER}"; \
    fi; \
    mkdir -p /home/${CLAUDE_USER}/.ssh /home/${CLAUDE_USER}/.claude /workspace \
             /etc/ssh/host-keys /opt/claude-config /run/sshd; \
    chown -R ${CLAUDE_UID}:${CLAUDE_GID} /home/${CLAUDE_USER} /workspace; \
    chmod 700 /home/${CLAUDE_USER}/.ssh

# --- sshd config --------------------------------------------------------------
COPY sshd_config /etc/ssh/sshd_config

# --- Baked-in Claude config + entrypoint --------------------------------------
COPY claude-config/ /opt/claude-config/
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY bin/claude-session /usr/local/bin/claude-session
COPY bin/claude-dev /usr/local/bin/claude-dev
COPY bin/claude-autopilot /usr/local/bin/claude-autopilot
COPY bin/claude-enqueue /usr/local/bin/claude-enqueue
COPY bin/claude-scm-observer /usr/local/bin/claude-scm-observer
COPY bin/claude-egress-firewall /usr/local/bin/claude-egress-firewall
COPY bin/claude-secret-guard /usr/local/bin/claude-secret-guard
COPY bin/claude-rc-watchdog /usr/local/bin/claude-rc-watchdog
COPY bin/claude-healthcheck /usr/local/bin/claude-healthcheck
# _common.sh rides along because claude-disk-gc sources it.
COPY bin/_common.sh /usr/local/bin/_common.sh
# Storage/disk safety: claude-disk-gc is a standalone maintenance tool (docker system +
# builder prune, plus the PKG-3 shared-cache trim) — run it manually or on your own
# cron/timer; no entrypoint path auto-starts it.
COPY bin/claude-disk-gc /usr/local/bin/claude-disk-gc
# Dependency manifest linter (PKG-5): warns on unpinned/`latest` specs in a repo's
# mise.toml / package.json (or refuses under --strict), so an agent-committed manifest
# stays reproducibly pinned. Advisory by default; never blocks a session.
COPY bin/claude-deps-check /usr/local/bin/claude-deps-check
# claude-reaper and claude-controller were REMOVED in CC-BINS: the reaper pruned a spool
# only the retired broker ever wrote to, and the controller had collapsed to a
# pass-through to claude-autopilot. See docs/legacy-sysbox-broker.md.
COPY bash_profile /home/${CLAUDE_USER}/.bash_profile
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/claude-session \
        /usr/local/bin/claude-dev /usr/local/bin/claude-autopilot \
        /usr/local/bin/claude-enqueue /usr/local/bin/claude-scm-observer \
        /usr/local/bin/claude-egress-firewall \
        /usr/local/bin/claude-secret-guard \
        /usr/local/bin/claude-rc-watchdog \
        /usr/local/bin/claude-healthcheck \
        /usr/local/bin/claude-disk-gc \
        /usr/local/bin/claude-deps-check \
    && chown -R ${CLAUDE_UID}:${CLAUDE_GID} /opt/claude-config \
                                            /home/${CLAUDE_USER}/.bash_profile

# mise interactive activation (PKG-2): APPEND to the user's stock ~/.bashrc
# (from /etc/skel via `useradd -m`) rather than overwriting it, so Debian's
# interactive aliases / history control / colored prompt survive for humans who
# SSH in to debug. A non-interactive shell already `return`s early in the stock
# file, and the guard below makes the snippet a no-op on its own too. Agent /
# non-interactive shells never source this — they resolve mise tools via the
# shims dir baked onto PATH (see the ENV block). bash_profile sources ~/.bashrc,
# so login shells reach it. `>>` create-or-append is correct whether or not the
# base image shipped a stock ~/.bashrc.
RUN printf '%s\n' \
      '' \
      '# mise (PKG-2): activate for INTERACTIVE shells only. Agent / non-interactive' \
      '# shells use the shims dir baked onto PATH (see the Dockerfile ENV), not this.' \
      '[[ $- == *i* ]] || return' \
      '# Shared tool cache (PKG-3): re-export the cache dirs so a fresh SSH shell that' \
      '# did NOT inherit the Dockerfile ENV (e.g. a non-tmux fallback shell) still' \
      "# activates mise against the SHARED store, not the home default. Agent shells get" \
      '# these from the Dockerfile ENV; this keeps interactive shells consistent.' \
      'export MISE_DATA_DIR="${MISE_DATA_DIR:-/cache/mise}"' \
      'export CARGO_HOME="${CARGO_HOME:-/cache/cargo}"' \
      'export GOPATH="${GOPATH:-/cache/go}"' \
      'export GOMODCACHE="${GOMODCACHE:-/cache/go/pkg/mod}"' \
      'export npm_config_cache="${npm_config_cache:-/cache/npm}"' \
      'export UV_CACHE_DIR="${UV_CACHE_DIR:-/cache/uv}"' \
      'export PIP_CACHE_DIR="${PIP_CACHE_DIR:-/cache/pip}"' \
      'command -v mise >/dev/null 2>&1 && eval "$(mise activate bash)"' \
      >> /home/${CLAUDE_USER}/.bashrc \
    && chown ${CLAUDE_UID}:${CLAUDE_GID} /home/${CLAUDE_USER}/.bashrc

# --- Reproducible manifest + install-script hardening (PKG-5) ------------------
# Two supply-chain hardenings for AGENT-initiated installs, both baked into the
# `claude` USER's config so the BUILD (root, above) is untouched — the pinned
# `npm install -g` layers ran before this and as root, so a tampered dependency's
# lifecycle script can't fire during image build either way.
#
# 1. ignore-scripts=true in ~/.npmrc — npm/pnpm/yarn(1.x) all read it, so an
#    agent-run `npm i` / `pnpm i` in /workspace does NOT execute a dependency's
#    pre/post-install lifecycle scripts (the Nx/Shai-Hulud weaponized-package
#    vector). This is NECESSARY BUT NOT SUFFICIENT — documented bypasses remain
#    (git-dependency `.npmrc` git-binary override runs even under ignore-scripts —
#    PackageGate GHSA-wr8v-3jqh-9x36; native `binding.gyp`/node-gyp builds still
#    compile; pnpm lockfile-integrity gaps for HTTP/git tarball deps — CVE-2025-69263).
#    The residual is contained by PKG-1 (curated egress + creds-unreachable-during-
#    fetch), not by this flag alone. See docs/package-provisioning-security.md.
#    ESCAPE HATCH (npm-native, no flag): a repo that genuinely needs install
#    scripts commits its own /workspace/.npmrc with `ignore-scripts=false` — a
#    project-level .npmrc overrides the user one, an explicit per-repo opt-in.
# 2. mise lockfile=true in the global mise config — makes a committed
#    /workspace/mise.lock authoritative: `mise install`/`use` records + reuses the
#    exact locked tool versions, so a pinned lock reinstalls identical versions
#    (from the PKG-3 shared cache) deterministically. Global config is always
#    trusted (it is mise's own, not a repo config), so it does not widen the
#    /workspace-only config-trust decision from PKG-2.
RUN set -eux; \
    printf 'ignore-scripts=true\n' > /home/${CLAUDE_USER}/.npmrc; \
    mkdir -p /home/${CLAUDE_USER}/.config/mise; \
    printf '[settings]\nlockfile = true\n' > /home/${CLAUDE_USER}/.config/mise/config.toml; \
    chown -R ${CLAUDE_UID}:${CLAUDE_GID} /home/${CLAUDE_USER}/.npmrc /home/${CLAUDE_USER}/.config

# --- Environment --------------------------------------------------------------
# Do NOT set DISABLE_TELEMETRY / DO_NOT_TRACK / CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:
# they short-circuit Claude Code's GrowthBook feature-flag fetch, so the
# `tengu_ccr_bridge` gate falls back to its `false` default and Remote Control
# reports "not yet enabled for your account" — even on an eligible account.
# Remote Control is the whole point of this image, so telemetry stays on.
# DISABLE_AUTOUPDATER is unrelated to the flag fetch and is kept (pinned version).
#
# mise (PKG-2) + shared tool cache (PKG-3):
#  - MISE_DATA_DIR + CARGO_HOME/GOPATH/GOMODCACHE + npm/uv/pip caches point at the
#    shared /cache tree (PKG-3), so a toolchain/CLI installed by one container is a
#    cache hit for the next and for parallel workers. With no cache volume mounted
#    /cache is a plain image-layer dir → per-container installs (fail-safe).
#  - PATH: prepend the mise shims dir (now /cache/mise/shims) so NON-interactive /
#    agent shells (`bash -c "…"`, the Claude Code process) resolve mise-installed
#    tools with no shell activation; also prepend cargo/go bin so `cargo install` /
#    `go install` CLIs resolve. Interactive shells get full `mise activate` via
#    ~/.bashrc (which re-exports these dirs — see the bashrc block). The dirs need
#    not be populated yet — mise creates + fills them (as UID 1000) on first `mise use`.
#  - MISE_TRUSTED_CONFIG_PATHS: auto-trust a `mise.toml` ONLY under /workspace
#    (the repo the agent is working on), a DELIBERATE, scoped supply-chain trade
#    — NOT a blanket "/" — so the agent's own repo toolchain auto-applies while
#    any config outside /workspace still refuses to auto-run. See
#    docs/toolchain-provisioning.md and docs/shared-tool-cache.md.
ENV CLAUDE_USER=${CLAUDE_USER} \
    CLAUDE_CONFIG_DIR=/home/${CLAUDE_USER}/.claude \
    CLAUDE_RC_DEBUG_LOG=/tmp/claude-rc-debug.log \
    DISABLE_AUTOUPDATER=1 \
    NODE_NO_WARNINGS=1 \
    MISE_TRUSTED_CONFIG_PATHS=/workspace \
    MISE_DATA_DIR=/cache/mise \
    CARGO_HOME=/cache/cargo \
    GOPATH=/cache/go \
    GOMODCACHE=/cache/go/pkg/mod \
    npm_config_cache=/cache/npm \
    UV_CACHE_DIR=/cache/uv \
    PIP_CACHE_DIR=/cache/pip \
    PATH=/cache/mise/shims:/cache/cargo/bin:/cache/go/bin:${PATH}

EXPOSE 22

# Healthcheck: liveness (sshd, tmux, the `claude --remote-control` process)
# plus Remote Control link state read from the RC debug log — so a silently
# dropped RC link shows as `unhealthy` in `docker ps` / `claude-list`, not
# just an outright crash. The RC watchdog handles recovery; this is the
# sensor. start-period covers the git clone + first Claude launch.
HEALTHCHECK --interval=60s --timeout=15s --start-period=120s --retries=3 \
    CMD ["/usr/local/bin/claude-healthcheck"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
