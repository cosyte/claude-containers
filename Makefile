# Claude Code container — build / auth / run helpers.
# Config comes from .env (if present) then the environment.

SHELL := /bin/bash
-include .env
export

CLAUDE_IMAGE        ?= claude-code-box:latest
CLAUDE_CODE_VERSION ?= 2.1.145
NODE_VERSION        ?= 24
UV_VERSION          ?= latest
PNPM_VERSION        ?= latest
CLAUDE_UID          ?= 1000
CLAUDE_GID          ?= 1000
CLAUDE_USER         ?= claude
AUTH_VOLUME         ?= claude-auth
PLATFORMS           ?= linux/amd64,linux/arm64
BUILDX_BUILDER      ?= claude-box
# Frontend-debugging variant: 1 bakes headless Chromium + chrome-devtools-mcp.
# Off by default (the lean image is unchanged). `make build-browser` flips it.
WITH_BROWSER        ?= 0

BUILD_ARGS = \
  --build-arg NODE_VERSION=$(NODE_VERSION) \
  --build-arg CLAUDE_CODE_VERSION=$(CLAUDE_CODE_VERSION) \
  --build-arg UV_VERSION=$(UV_VERSION) \
  --build-arg PNPM_VERSION=$(PNPM_VERSION) \
  --build-arg CLAUDE_UID=$(CLAUDE_UID) \
  --build-arg CLAUDE_GID=$(CLAUDE_GID) \
  --build-arg CLAUDE_USER=$(CLAUDE_USER) \
  --build-arg WITH_BROWSER=$(WITH_BROWSER)

.DEFAULT_GOAL := help
.PHONY: help builder build build-all build-browser push login launch list attach stop rm logs clean lint smoke

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

launch: ## make launch ARGS="myproj --repo git@github.com:me/x.git"
	@./bin/claude-launch $(ARGS)

list:  ## List all claude-* containers
	@./bin/claude-list
attach: ## make attach ARGS="myproj" — attach to a container's tmux session
	@./bin/claude-attach $(ARGS)
stop:  ## make stop ARGS="myproj"
	@./bin/claude-stop $(ARGS)
rm:    ## make rm ARGS="myproj --purge"
	@./bin/claude-rm $(ARGS)
logs:  ## make logs ARGS="myproj"
	@./bin/claude-logs $(ARGS)

lint: ## Shell-syntax check the scripts
	@for f in entrypoint.sh bin/_common.sh bin/claude-*; do bash -n $$f && echo "ok $$f"; done

smoke: build ## Build the image, then run the automated smoke test against it
	IMAGE=$(CLAUDE_IMAGE) test/smoke.sh

clean: ## Remove the image and the buildx builder (volumes are kept)
	-docker image rm $(CLAUDE_IMAGE) 2>/dev/null
	-docker buildx rm $(BUILDX_BUILDER) 2>/dev/null
	@echo "Volumes ($(AUTH_VOLUME), claude-ws-*, claude-config-*) left intact."
	@echo "Remove auth/login with: docker volume rm $(AUTH_VOLUME)"
