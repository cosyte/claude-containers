# Claude Code container: build / auth / run helpers.
# Config comes from .env (if present) then the environment.

SHELL := /bin/bash
-include .env
export

CLAUDE_IMAGE        ?= claude-code-box:latest
CLAUDE_CODE_VERSION ?= 2.1.302
PNPM_VERSION        ?= 12.14.0
CLAUDE_UID          ?= 1000
CLAUDE_GID          ?= 1000
CLAUDE_USER         ?= claude
AUTH_VOLUME         ?= claude-auth
PLATFORMS           ?= linux/amd64,linux/arm64
BUILDX_BUILDER      ?= claude-box
# Frontend-debugging variant: 1 bakes headless Chromium + chrome-devtools-mcp.
# Off by default (the lean image is unchanged). `make build-browser` flips it.
WITH_BROWSER        ?= 0

# NODE_VERSION and UV_VERSION are gone: the base image and uv are pinned by tag and
# digest on the Dockerfile's FROM lines, where Dependabot can bump them. Refuse one set
# in .env or on the command line rather than silently ignoring it. The environment is
# exempt: every node image (this one included) exports NODE_VERSION, so refusing it there
# would break make inside the very containers this repo builds.
$(foreach v,NODE_VERSION UV_VERSION,$(if $(filter file command line,$(origin $(v))),\
  $(error $(v) is no longer a build setting: the version is pinned on a FROM line in the Dockerfile (node:24-trixie-slim@sha256:..., ghcr.io/astral-sh/uv:X.Y.Z@sha256:...); edit that line, and drop $(v) from your .env or make command)))

# Provenance labels (the end of the Dockerfile): the commit, whether the tree had
# changes git would show, and the build time in UTC. `unknown` outside a git checkout.
# Expanded once (`:=` under ifndef), not per reference: `export` above would otherwise
# rerun git for every recipe line, and BUILD_DATE could differ between two uses.
ifndef GIT_COMMIT
GIT_COMMIT := $(or $(shell git rev-parse HEAD 2>/dev/null),unknown)
endif
ifndef GIT_DIRTY
GIT_DIRTY := $(shell git rev-parse --git-dir >/dev/null 2>&1 \
               && { [[ -n "$$(git status --porcelain 2>/dev/null)" ]] && echo true || echo false; } \
               || echo unknown)
endif
ifndef BUILD_DATE
BUILD_DATE := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
endif

BUILD_ARGS = \
  --build-arg CLAUDE_CODE_VERSION=$(CLAUDE_CODE_VERSION) \
  --build-arg PNPM_VERSION=$(PNPM_VERSION) \
  --build-arg CLAUDE_UID=$(CLAUDE_UID) \
  --build-arg CLAUDE_GID=$(CLAUDE_GID) \
  --build-arg CLAUDE_USER=$(CLAUDE_USER) \
  --build-arg WITH_BROWSER=$(WITH_BROWSER) \
  --build-arg GIT_COMMIT=$(GIT_COMMIT) \
  --build-arg GIT_DIRTY=$(GIT_DIRTY) \
  --build-arg BUILD_DATE=$(BUILD_DATE)

.DEFAULT_GOAL := help
.PHONY: help builder build build-all build-browser push login accounts-login accounts-list launch list attach stop rm logs clean lint smoke

help: ## Show this help
	@# Grep only this Makefile, not all of MAKEFILE_LIST: `-include .env` adds
	@# .env there, and grep over >1 file prefixes "Makefile:" onto every match.
	@grep -E '^[a-zA-Z_-]+:.*## ' $(firstword $(MAKEFILE_LIST)) \
	  | awk 'BEGIN{FS=":.*## "}{printf "  \033[1m%-12s\033[0m %s\n",$$1,$$2}'

builder: ## Ensure a buildx builder exists
	@docker buildx inspect $(BUILDX_BUILDER) >/dev/null 2>&1 \
	  || docker buildx create --name $(BUILDX_BUILDER) --driver docker-container >/dev/null
	@docker buildx use $(BUILDX_BUILDER)

build: builder ## Build the image for the host arch and load it locally
	docker buildx build $(BUILD_ARGS) --load -t $(CLAUDE_IMAGE) .
	@echo "Built $(CLAUDE_IMAGE) (host arch). For amd64+arm64 use 'make push'."

build-all: builder ## Build both linux/amd64 and linux/arm64 (no local load)
	docker buildx build $(BUILD_ARGS) --platform $(PLATFORMS) -t $(CLAUDE_IMAGE) .

build-browser: ## Build the browser-enabled variant (Chromium + chrome-devtools-mcp), tag :browser
	@$(MAKE) build WITH_BROWSER=1 CLAUDE_IMAGE=$(or $(CLAUDE_IMAGE_BROWSER),claude-code-box:browser)
	@echo "Built browser variant. Launch with:  ./bin/claude-launch <name> --browser --workspace <path>"
	@echo "Or set CLAUDE_IMAGE=claude-code-box:browser in your .env so every launch uses it."

push: builder ## Build+push amd64+arm64 to the registry in CLAUDE_IMAGE
	docker buildx build $(BUILD_ARGS) --platform $(PLATFORMS) \
	  -t $(CLAUDE_IMAGE) --push .

login: ## One-time OAuth login; persists creds to the claude-auth volume
	@docker image inspect $(CLAUDE_IMAGE) >/dev/null 2>&1 || $(MAKE) build
	@echo "Opening Claude OAuth login. Use your Max subscription account."
	docker run --rm -it \
	  -e CLAUDE_LOGIN_MODE=1 \
	  -e ANTHROPIC_API_KEY= \
	  -v $(AUTH_VOLUME):/auth \
	  $(CLAUDE_IMAGE)
	@echo "Login complete. Credentials are in volume '$(AUTH_VOLUME)'."

accounts-login: ## make accounts-login ARGS="work2", OAuth login for a NAMED account (for --accounts rotation)
	@./bin/claude-account-login $(ARGS)
accounts-list: ## List every named account (claude-auth-*) and its token/email status
	@./bin/claude-account-list

launch: ## make launch ARGS="myproj --repo git@github.com:me/x.git"
	@./bin/claude-launch $(ARGS)

list:  ## List all claude-* containers
	@./bin/claude-list
attach: ## make attach ARGS="myproj", attach to a container's tmux session
	@./bin/claude-attach $(ARGS)
stop:  ## make stop ARGS="myproj"
	@./bin/claude-stop $(ARGS)
rm:    ## make rm ARGS="myproj --purge"
	@./bin/claude-rm $(ARGS)
logs:  ## make logs ARGS="myproj"
	@./bin/claude-logs $(ARGS)

LINT_SH := entrypoint.sh $(wildcard entrypoint.d/*.sh) bin/_common.sh bin/nproc $(wildcard bin/claude-*) $(wildcard scripts/*.sh) $(wildcard test/*.sh) $(wildcard test/lib/*.sh) bash_profile

lint: ## bash -n, then shellcheck -S warning over the scripts, then hadolint the Dockerfile (pinned in mise.toml)
	@fail=0; for f in $(LINT_SH); do \
	  if bash -n $$f; then echo "ok $$f"; else echo "SYNTAX ERROR $$f"; fail=1; fi; \
	done; exit $$fail
	@for t in shellcheck hadolint; do \
	  $$t --version >/dev/null 2>&1 || { echo "lint: $$t is missing; run 'mise install' in this repo (mise.toml pins it)" >&2; exit 1; }; \
	done
	shellcheck -S warning $(LINT_SH)
	hadolint Dockerfile

smoke: build ## Build the image, then run the automated smoke test against it
	IMAGE=$(CLAUDE_IMAGE) test/smoke.sh

clean: ## Remove the image and the buildx builder (volumes are kept)
	-docker image rm $(CLAUDE_IMAGE) 2>/dev/null
	-docker buildx rm $(BUILDX_BUILDER) 2>/dev/null
	@echo "Volumes ($(AUTH_VOLUME), claude-ws-*, claude-config-*, claude-state-*) left intact."
	@echo "Remove auth/login with: docker volume rm $(AUTH_VOLUME)"
