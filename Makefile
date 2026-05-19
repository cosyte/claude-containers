# Claude Code container — build / auth / run helpers.
# Config comes from .env (if present) then the environment.

SHELL := /bin/bash
-include .env
export

CLAUDE_IMAGE        ?= claude-code-box:latest
CLAUDE_CODE_VERSION ?= 2.1.144
NODE_VERSION        ?= 24
UV_VERSION          ?= latest
CLAUDE_UID          ?= 1000
CLAUDE_GID          ?= 1000
CLAUDE_USER         ?= claude
AUTH_VOLUME         ?= claude-auth
PLATFORMS           ?= linux/amd64,linux/arm64
BUILDX_BUILDER      ?= claude-box

BUILD_ARGS = \
  --build-arg NODE_VERSION=$(NODE_VERSION) \
  --build-arg CLAUDE_CODE_VERSION=$(CLAUDE_CODE_VERSION) \
  --build-arg UV_VERSION=$(UV_VERSION) \
  --build-arg CLAUDE_UID=$(CLAUDE_UID) \
  --build-arg CLAUDE_GID=$(CLAUDE_GID) \
  --build-arg CLAUDE_USER=$(CLAUDE_USER)

SHELL_FILES := entrypoint.sh bin/_common.sh $(wildcard bin/claude-*) test/smoke.sh

.DEFAULT_GOAL := help
.PHONY: help build build-all push login launch list stop rm logs clean lint

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-12s\033[0m %s\n",$$1,$$2}'

builder: ## Ensure a buildx builder exists
	@docker buildx inspect $(BUILDX_BUILDER) >/dev/null 2>&1 \
	  || docker buildx create --name $(BUILDX_BUILDER) --driver docker-container >/dev/null
	@docker buildx use $(BUILDX_BUILDER)

build: builder ## Build the image for the host arch and load it locally
	docker buildx build $(BUILD_ARGS) --load -t $(CLAUDE_IMAGE) .
	@echo "Built $(CLAUDE_IMAGE) (host arch). For amd64+arm64 use 'make push'."

build-all: builder ## Build both linux/amd64 and linux/arm64 (no local load)
	docker buildx build $(BUILD_ARGS) --platform $(PLATFORMS) -t $(CLAUDE_IMAGE) .

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

launch: ## make launch ARGS="myproj --repo git@github.com:me/x.git"
	@./bin/claude-launch $(ARGS)

list:  ## List all claude-* containers
	@./bin/claude-list
stop:  ## make stop ARGS="myproj"
	@./bin/claude-stop $(ARGS)
rm:    ## make rm ARGS="myproj --purge"
	@./bin/claude-rm $(ARGS)
logs:  ## make logs ARGS="myproj"
	@./bin/claude-logs $(ARGS)

lint: ## Lint: bash -n + shellcheck (shell) + hadolint (Dockerfile); skips a missing tool
	@echo "==> bash -n"; \
	  for f in $(SHELL_FILES); do bash -n "$$f" && echo "  ok   $$f" || exit 1; done
	@if command -v shellcheck >/dev/null 2>&1; then \
	    echo "==> shellcheck --severity=warning"; \
	    shellcheck --severity=warning $(SHELL_FILES) && echo "  ok   shellcheck clean"; \
	  else echo "==> shellcheck: SKIP (not installed)"; fi
	@if command -v hadolint >/dev/null 2>&1; then \
	    echo "==> hadolint"; \
	    hadolint Dockerfile && echo "  ok   hadolint clean"; \
	  else echo "==> hadolint: SKIP (not installed)"; fi

clean: ## Remove the image and the buildx builder (volumes are kept)
	-docker image rm $(CLAUDE_IMAGE) 2>/dev/null
	-docker buildx rm $(BUILDX_BUILDER) 2>/dev/null
	@echo "Volumes ($(AUTH_VOLUME), claude-ws-*, claude-config-*) left intact."
	@echo "Remove auth/login with: docker volume rm $(AUTH_VOLUME)"
