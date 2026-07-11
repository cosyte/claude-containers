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

# --- mise: rootless polyglot toolchain + CLI-binary provisioning (PKG-2) -------
# Bake `mise` so a session can provision language toolchains and prebuilt CLIs
# as UID 1000 with NO root:
#   mise use node@22 / python@3.12 / go@1.23 / rust      (language toolchains)
#   mise use aqua:owner/tool | github:owner/tool         (arbitrary prebuilt CLIs)
# `pipx:` CLIs reuse the baked `uv` automatically — mise's `pipx.uvx` defaults
# true whenever `uv` is on PATH (it is, baked above). System `.so` libraries are
# NOT in scope for mise — those are the Sysbox-worker apt tier (PKG-4).
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
# Image-capability label: bin/claude-launch reads this to fail early (loud,
# actionable) if --browser is requested against a non-browser image. (The
# in-container entrypoint can't read its own image labels, so it auto-detects
# the variant by probing the baked binaries on PATH instead.)
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
COPY bin/claude-egress-firewall /usr/local/bin/claude-egress-firewall
COPY bin/claude-secret-guard /usr/local/bin/claude-secret-guard
COPY bin/claude-rc-watchdog /usr/local/bin/claude-rc-watchdog
COPY bin/claude-healthcheck /usr/local/bin/claude-healthcheck
# Worker broker (CC-2): _common.sh rides along because the broker sources it for
# the shared Sysbox version-floor check — ONE floor definition, host and container.
COPY bin/_common.sh /usr/local/bin/_common.sh
COPY bin/claude-worker-broker /usr/local/bin/claude-worker-broker
COPY bin/claude-worker-request /usr/local/bin/claude-worker-request
# Worker lifecycle (CC-4): claude-worker-run is the broker's default worker command
# (runs INSIDE each ephemeral worker); claude-reaper runs alongside the broker in
# controller mode (entrypoint.sh §5b) to mop up unclean-exit residue + spool litter.
COPY bin/claude-worker-run /usr/local/bin/claude-worker-run
COPY bin/claude-reaper /usr/local/bin/claude-reaper
# Storage/disk safety (CC-5): claude-disk-gc runs alongside the broker + reaper in
# controller mode (entrypoint.sh §5b), scheduled GC of the inner daemon's image/
# container/build-cache layers so nested workers don't fill the host.
COPY bin/claude-disk-gc /usr/local/bin/claude-disk-gc
# Controller mode (CC-6): wires this substrate to the umbrella PAR-* lease/scheduler/
# bump-worker. slots==1 collapses to claude-autopilot (byte-identical); slots>1 is the
# built-but-gated K>1 loop (CLAUDE_CONTROLLER_MAX_SLOTS defaults to 1 — never auto-ramps).
COPY bin/claude-controller /usr/local/bin/claude-controller
COPY bash_profile /home/${CLAUDE_USER}/.bash_profile
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/claude-session \
        /usr/local/bin/claude-dev /usr/local/bin/claude-autopilot \
        /usr/local/bin/claude-enqueue /usr/local/bin/claude-scm-observer \
        /usr/local/bin/claude-egress-firewall \
        /usr/local/bin/claude-secret-guard \
        /usr/local/bin/claude-rc-watchdog \
        /usr/local/bin/claude-healthcheck \
        /usr/local/bin/claude-worker-broker \
        /usr/local/bin/claude-worker-request \
        /usr/local/bin/claude-worker-run \
        /usr/local/bin/claude-reaper \
        /usr/local/bin/claude-disk-gc \
        /usr/local/bin/claude-controller \
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
      'command -v mise >/dev/null 2>&1 && eval "$(mise activate bash)"' \
      >> /home/${CLAUDE_USER}/.bashrc \
    && chown ${CLAUDE_UID}:${CLAUDE_GID} /home/${CLAUDE_USER}/.bashrc

# --- Environment --------------------------------------------------------------
# Do NOT set DISABLE_TELEMETRY / DO_NOT_TRACK / CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:
# they short-circuit Claude Code's GrowthBook feature-flag fetch, so the
# `tengu_ccr_bridge` gate falls back to its `false` default and Remote Control
# reports "not yet enabled for your account" — even on an eligible account.
# Remote Control is the whole point of this image, so telemetry stays on.
# DISABLE_AUTOUPDATER is unrelated to the flag fetch and is kept (pinned version).
#
# mise (PKG-2):
#  - PATH: prepend the mise shims dir so NON-interactive / agent shells
#    (`bash -c "…"`, the Claude Code process) resolve mise-installed tools with
#    no shell activation. Interactive shells get full `mise activate` via
#    ~/.bashrc; this covers everything else. The dir need not exist yet — mise
#    creates + populates it (as UID 1000) on the first `mise use`.
#  - MISE_TRUSTED_CONFIG_PATHS: auto-trust a `mise.toml` ONLY under /workspace
#    (the repo the agent is working on), a DELIBERATE, scoped supply-chain trade
#    — NOT a blanket "/" — so the agent's own repo toolchain auto-applies while
#    any config outside /workspace still refuses to auto-run. See
#    docs/toolchain-provisioning.md.
ENV CLAUDE_USER=${CLAUDE_USER} \
    CLAUDE_CONFIG_DIR=/home/${CLAUDE_USER}/.claude \
    CLAUDE_RC_DEBUG_LOG=/tmp/claude-rc-debug.log \
    DISABLE_AUTOUPDATER=1 \
    NODE_NO_WARNINGS=1 \
    MISE_TRUSTED_CONFIG_PATHS=/workspace \
    PATH=/home/${CLAUDE_USER}/.local/share/mise/shims:${PATH}

EXPOSE 22

# Healthcheck: liveness (sshd, tmux, the `claude --remote-control` process)
# plus Remote Control link state read from the RC debug log — so a silently
# dropped RC link shows as `unhealthy` in `docker ps` / `claude-list`, not
# just an outright crash. The RC watchdog handles recovery; this is the
# sensor. start-period covers the git clone + first Claude launch.
HEALTHCHECK --interval=60s --timeout=15s --start-period=120s --retries=3 \
    CMD ["/usr/local/bin/claude-healthcheck"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
