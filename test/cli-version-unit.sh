#!/usr/bin/env bash
# cli-version-unit.sh: the Claude Code CLI pin is CONSISTENT and above its capability floors.
# Pure-static: NO docker, NO network, NO build.
#
# Why this suite exists (CC-CLAUDE-CODE-UPGRADE, 2026-07-12):
#
#   1. THE PIN IS DECLARED IN SIX PLACES AND THEY CAN DISAGREE. `Makefile` passes
#      `--build-arg CLAUDE_CODE_VERSION=$(CLAUDE_CODE_VERSION)`, which OVERRIDES the
#      Dockerfile's `ARG` default. So bumping the Dockerfile alone is a NO-OP for
#      `make build`: the image would silently keep the old CLI. Before this suite the
#      repo had already drifted: Dockerfile/Makefile said 2.1.145 while compose-gen and
#      the README said 2.1.144.
#
#   2. THE VERSION SILENTLY SELECTS THE MODEL. This image launches with `--model opus`
#      (entrypoint exports CLAUDE_MODEL=opus by default), and the `opus` alias resolves
#      to the LATEST Opus. Opus 4.8 arrived in CLI 2.1.154, so any pin BELOW that
#      silently resolves `opus` to Opus 4.7, quietly downgrading every gate agent below
#      what ADR 0009 requires. A version floor is therefore a correctness gate, not
#      hygiene: a downgrade must FAIL here, loudly, not degrade in production.
#
#   3. TWO UPSTREAM CHANGES MAKE THE LAUNCH FLAGS LOAD-BEARING. CLI 2.1.197 made Sonnet 5
#      Claude Code's own default model (so dropping our explicit `--model` would silently
#      switch models), and the whole reason the CLI is pinned is that
#      `--dangerously-skip-permissions` + `--remote-control` must combine. Both are
#      asserted below so a refactor cannot quietly remove them.
#
# This suite is PURE-STATIC by design, which means it has a blind spot it cannot close:
# it reads repo files and never the built image, and never `.env`. The Makefile does
# `-include .env` BEFORE `CLAUDE_CODE_VERSION ?= …`, so an operator's gitignored `.env`
# overrides the repo's pin and is forwarded as `--build-arg`, beating the Dockerfile ARG.
# A host with a stale `.env` therefore keeps building an OLD CLI while every check here
# stays green. Two other gates close that hole, and they must keep existing:
#   - Dockerfile: a hard build-time floor (>= 2.1.154) + an assertion that the INSTALLED
#     binary equals the pin. Every build path passes through it, so a stale .env now
#     FAILS THE BUILD loudly instead of silently serving Opus 4.7.
#   - test/smoke.sh: asserts the RUNNING IMAGE reports the pinned version and clears the
#     floor.
# The live Remote Control handshake stays on the on-host item CC-CLAUDE-CODE-UPGRADE-SMOKE.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source FIRST, then define ok/bad: bin/_common.sh exports its own ok() logger, so
# sourcing it after these definitions would silently clobber them (and the suite would
# report "0 passed, 0 failed" while appearing to run).
# shellcheck disable=SC1091
source "$REPO_ROOT/bin/_common.sh"   # version_ge (numeric, fail-closed on garbage)

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

# Capability floors. Raise these ONLY with a reason.
RC_FLOOR=2.1.52     # Remote Control exists at all
OPUS48_FLOOR=2.1.154 # `opus` alias resolves to Opus 4.8 (below this it silently means 4.7)

echo "== the pinned version is the single source of truth (Dockerfile ARG) =="

PINNED="$(sed -n 's/^ARG CLAUDE_CODE_VERSION=\(.*\)$/\1/p' "$REPO_ROOT/Dockerfile")"
if [[ -n "$PINNED" ]]; then
    ok "Dockerfile pins CLAUDE_CODE_VERSION=$PINNED"
else
    bad "could not read 'ARG CLAUDE_CODE_VERSION=' from the Dockerfile"
    echo; echo "== $PASS passed, $FAIL failed =="; exit 1
fi

echo
echo "== every other declaration agrees (a disagreement means the build silently ships a different CLI) =="

# Makefile: THE decisive one, it is passed as --build-arg and OVERRIDES the Dockerfile ARG.
mk="$(sed -n 's/^CLAUDE_CODE_VERSION ?= \(.*\)$/\1/p' "$REPO_ROOT/Makefile")"
[[ "$mk" == "$PINNED" ]] \
    && ok  "Makefile default ($mk) == Dockerfile ARG: 'make build' really builds the pinned CLI" \
    || bad "Makefile says '$mk' but Dockerfile ARG says '$PINNED'. The Makefile passes --build-arg, so it WINS: 'make build' would ship '$mk' and the Dockerfile bump would be a NO-OP."

# The Makefile must actually forward it, or the ARG default silently applies instead.
grep -q -- '--build-arg CLAUDE_CODE_VERSION=$(CLAUDE_CODE_VERSION)' "$REPO_ROOT/Makefile" \
    && ok  "Makefile forwards CLAUDE_CODE_VERSION as a --build-arg" \
    || bad "Makefile no longer forwards --build-arg CLAUDE_CODE_VERSION (the pin plumbing changed, re-check which value the build actually uses)"

dc="$(sed -n 's/.*CLAUDE_CODE_VERSION: \${CLAUDE_CODE_VERSION:-\([^}]*\)}.*/\1/p' "$REPO_ROOT/docker-compose.yml")"
[[ "$dc" == "$PINNED" ]] \
    && ok  "docker-compose.yml default ($dc) == the pin" \
    || bad "docker-compose.yml says '$dc', expected '$PINNED'"

cg="$(sed -n 's/.*CLAUDE_CODE_VERSION: "\\\${CLAUDE_CODE_VERSION:-\([^}]*\)}".*/\1/p' "$REPO_ROOT/bin/claude-compose-gen")"
[[ "$cg" == "$PINNED" ]] \
    && ok  "bin/claude-compose-gen emits the pin ($cg) into generated compose files" \
    || bad "bin/claude-compose-gen emits '$cg', expected '$PINNED': generated stacks would build a different CLI"

ee="$(sed -n 's/^CLAUDE_CODE_VERSION=\(.*\)$/\1/p' "$REPO_ROOT/.env.example")"
[[ "$ee" == "$PINNED" ]] \
    && ok  ".env.example ($ee) == the pin" \
    || bad ".env.example says '$ee', expected '$PINNED': a fresh copy would pin operators to the wrong CLI"

grep -q "| \`CLAUDE_CODE_VERSION\` | \`$PINNED\`" "$REPO_ROOT/README.md" \
    && ok  "README documents the pin as $PINNED" \
    || bad "README's CLAUDE_CODE_VERSION row does not document '$PINNED'"

grep -q "Pinned/verified Claude Code: \*\*$PINNED\*\*" "$REPO_ROOT/.claude/skills/claude-containers/SKILL.md" \
    && ok  "SKILL.md documents the pin as $PINNED" \
    || bad "SKILL.md does not document the pin as '$PINNED'"

echo
echo "== the pin is actually CONSUMED (else it is decorative) =="

# A RUN that resolved `@latest` (or dropped the ARG) would leave all the checks above
# green while the image shipped whatever npm served that day.
grep -q 'npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}' "$REPO_ROOT/Dockerfile" \
    && ok  "Dockerfile installs @anthropic-ai/claude-code@\${CLAUDE_CODE_VERSION} (the pin is used, not decorative)" \
    || bad "Dockerfile no longer installs the pinned version: the ARG is decorative and the image could ship any version"

# The build-time guards are what make a stale, gitignored .env fail loudly instead of
# silently building an old CLI (the Makefile's `-include .env` beats both `?=` and the ARG).
grep -q 'OPUS48_FLOOR=2.1.154' "$REPO_ROOT/Dockerfile" \
    && ok  "Dockerfile enforces the Opus-4.8 floor at BUILD time (a stale .env fails the build)" \
    || bad "Dockerfile lost its build-time Opus-4.8 floor: a stale .env would silently build a pre-4.8 CLI and every test would stay green"

grep -q 'installed CLI reports' "$REPO_ROOT/Dockerfile" \
    && ok  "Dockerfile asserts the INSTALLED binary equals the pin" \
    || bad "Dockerfile no longer asserts the installed binary matches the pin"

grep -q 'image ships the pinned Claude Code CLI' "$REPO_ROOT/test/smoke.sh" \
    && ok  "smoke.sh checks the RUNNING IMAGE against the pin (the live half this static suite cannot do)" \
    || bad "smoke.sh no longer checks the running image against the pin: nothing proves the built image ships it"

echo
echo "== capability floors (a DOWNGRADE below these degrades behavior silently, it must fail loudly here) =="

if version_ge "$PINNED" "$RC_FLOOR"; then
    ok "$PINNED >= $RC_FLOOR: Remote Control is supported"
else
    bad "$PINNED < $RC_FLOOR: Remote Control does not exist in this CLI; the image's whole point breaks"
fi

if version_ge "$PINNED" "$OPUS48_FLOOR"; then
    ok "$PINNED >= $OPUS48_FLOOR: '--model opus' resolves to Opus 4.8 (ADR 0009)"
else
    bad "$PINNED < $OPUS48_FLOOR: '--model opus' would SILENTLY resolve to Opus 4.7, downgrading every gate agent below what ADR 0009 requires. This is exactly the defect CC-CLAUDE-CODE-UPGRADE fixed; do not re-introduce it."
fi

echo
echo "== the launch flags the pin exists to protect are still passed =="

# CLI 2.1.197 made Sonnet 5 Claude Code's OWN default. We are only insulated from that
# because the entrypoint always exports a model and both launchers pass --model.
grep -q 'export CLAUDE_MODEL="${CLAUDE_MODEL:-opus}"' "$REPO_ROOT/entrypoint.sh" \
    && ok  "entrypoint defaults CLAUDE_MODEL=opus (without this, CLI >=2.1.197 would silently run Sonnet 5)" \
    || bad "entrypoint no longer defaults CLAUDE_MODEL=opus: CLI >=2.1.197 defaults to Sonnet 5, so the fleet would silently switch models"

# Assert the DEFAULT, not merely that the string '--model' appears somewhere. Both scripts
# are reachable with CLAUDE_MODEL unset (a `docker exec`, or any sshd-originated shell, the
# entrypoint bridges only SSH_AUTH_SOCK into /etc/profile.d, and claude-launch passes a
# literal empty `-e CLAUDE_MODEL=`). If either falls back to "" it emits NO --model, and
# post-2.1.197 that silently means Sonnet 5. A bare grep for '--model' would pass in exactly
# that broken state, so it is not a gate.
for f in bin/claude-session bin/claude-autopilot; do
    if grep -qE '^MODEL="\$\{CLAUDE_MODEL:-opus\}"$' "$REPO_ROOT/$f"; then
        ok "$f defaults MODEL to opus when CLAUDE_MODEL is unset (so it can never silently run Sonnet 5)"
    else
        bad "$f does not default MODEL to opus: with CLAUDE_MODEL unset it would pass NO --model, and CLI >=2.1.197 defaults to Sonnet 5"
    fi
    grep -q -- '--model' "$REPO_ROOT/$f" \
        && ok  "$f passes --model to the CLI" \
        || bad "$f no longer passes --model at all"
done

# The pin's raison d'être: these two must combine in the interactive launch.
if grep -q -- '--dangerously-skip-permissions' "$REPO_ROOT/bin/claude-session" \
   && grep -q -- '--remote-control' "$REPO_ROOT/bin/claude-session"; then
    ok "claude-session still combines --dangerously-skip-permissions + --remote-control (the reason the CLI is pinned)"
else
    bad "claude-session no longer combines --dangerously-skip-permissions + --remote-control, that combination is the reason this CLI version is pinned"
fi

echo
echo "== $PASS passed, $FAIL failed =="
exit $(( FAIL > 0 ? 1 : 0 ))
