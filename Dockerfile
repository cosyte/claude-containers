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
# CLAUDE_CODE_VERSION: pinned npm version. Minimum 2.1.52 for Remote Control;
# 2.1.145 is verified to support `--remote-control` + bypassPermissions together.
ARG CLAUDE_CODE_VERSION=2.1.145
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
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
    && npm cache clean --force \
    && claude --version

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

# --- Optional: headless Chromium + chrome-devtools-mcp (frontend debugging) --
# Build with `--build-arg WITH_BROWSER=1` (or `make build-browser`) to bake a
# headless Chromium and the official Chrome DevTools MCP server, so a session
# launched with `--browser` / `CLAUDE_BROWSER=1` can drive, inspect, and debug
# any frontend (navigate, evaluate, console, network, Lighthouse, screenshots,
# perf traces, heap snapshots — 55+ tools). Default is OFF: the lean image is
# unchanged unless you opt in. ~200 MB delta when on.
ARG WITH_BROWSER=0
# Pin to the latest verified release. Bump via the build arg.
ARG CHROME_DEVTOOLS_MCP_VERSION=0.7.0
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
    else \
        echo "WITH_BROWSER=0 — skipping Chromium + chrome-devtools-mcp"; \
    fi
# Image-capability label: bin/claude-launch checks this to warn early if
# --browser is requested against a non-browser image.
LABEL claude.browser="${WITH_BROWSER}"

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
COPY bin/claude-secret-guard /usr/local/bin/claude-secret-guard
COPY bin/claude-rc-watchdog /usr/local/bin/claude-rc-watchdog
COPY bin/claude-healthcheck /usr/local/bin/claude-healthcheck
COPY bash_profile /home/${CLAUDE_USER}/.bash_profile
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/claude-session \
        /usr/local/bin/claude-dev /usr/local/bin/claude-autopilot \
        /usr/local/bin/claude-enqueue /usr/local/bin/claude-scm-observer \
        /usr/local/bin/claude-secret-guard \
        /usr/local/bin/claude-rc-watchdog \
        /usr/local/bin/claude-healthcheck \
    && chown -R ${CLAUDE_UID}:${CLAUDE_GID} /opt/claude-config \
                                            /home/${CLAUDE_USER}/.bash_profile

# --- Environment --------------------------------------------------------------
# Do NOT set DISABLE_TELEMETRY / DO_NOT_TRACK / CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:
# they short-circuit Claude Code's GrowthBook feature-flag fetch, so the
# `tengu_ccr_bridge` gate falls back to its `false` default and Remote Control
# reports "not yet enabled for your account" — even on an eligible account.
# Remote Control is the whole point of this image, so telemetry stays on.
# DISABLE_AUTOUPDATER is unrelated to the flag fetch and is kept (pinned version).
ENV CLAUDE_USER=${CLAUDE_USER} \
    CLAUDE_CONFIG_DIR=/home/${CLAUDE_USER}/.claude \
    CLAUDE_RC_DEBUG_LOG=/tmp/claude-rc-debug.log \
    DISABLE_AUTOUPDATER=1 \
    NODE_NO_WARNINGS=1

EXPOSE 22

# Healthcheck: liveness (sshd, tmux, the `claude --remote-control` process)
# plus Remote Control link state read from the RC debug log — so a silently
# dropped RC link shows as `unhealthy` in `docker ps` / `claude-list`, not
# just an outright crash. The RC watchdog handles recovery; this is the
# sensor. start-period covers the git clone + first Claude launch.
HEALTHCHECK --interval=60s --timeout=15s --start-period=120s --retries=3 \
    CMD ["/usr/local/bin/claude-healthcheck"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
