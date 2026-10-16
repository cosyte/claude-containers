#!/usr/bin/env bash
# pins-unit.sh: the base image, uv and pnpm are pinned where Dependabot (or a reader) can bump
# them. Static: no docker, no network.
#   - both FROM lines are a literal tag plus @sha256 digest, never built from an ARG
#     (Dependabot cannot rewrite those, dependabot-core#2057);
#   - PNPM_VERSION is an exact version, the same in the Dockerfile, Makefile, docker-compose.yml,
#     claude-compose-gen and .env.example;
#   - the Makefile refuses NODE_VERSION / UV_VERSION from .env or the command line, and not from
#     the environment (every node image exports NODE_VERSION);
#   - the Dependabot docker entry ignores node majors.
# shellcheck source=test/lib/prelude.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/prelude.sh"
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

echo "pinned base image, uv and pnpm"

DIGEST='@sha256:[0-9a-f]{64}'
grep -Eq "^FROM ghcr\.io/astral-sh/uv:[0-9]+\.[0-9]+\.[0-9]+$DIGEST AS uv$" "$REPO_ROOT/Dockerfile" \
    && ok "uv stage: literal version + digest" || bad "uv FROM line is not ghcr.io/astral-sh/uv:X.Y.Z@sha256:<digest>"
grep -Eq "^FROM node:[0-9]+-trixie-slim$DIGEST$" "$REPO_ROOT/Dockerfile" \
    && ok "base image: literal node tag + digest" || bad "base FROM line is not node:<major>-trixie-slim@sha256:<digest>"
if grep -E '^FROM ' "$REPO_ROOT/Dockerfile" | grep -q '\$'; then
    bad "a FROM line expands a variable: Dependabot cannot bump it"
else
    ok "no FROM line expands a variable"
fi
if grep -Eq '^ARG (NODE_VERSION|UV_VERSION)' "$REPO_ROOT/Dockerfile"; then
    bad "Dockerfile still declares NODE_VERSION / UV_VERSION"
else
    ok "Dockerfile declares no NODE_VERSION / UV_VERSION"
fi

pnpm="$(grep -E '^ARG PNPM_VERSION=' "$REPO_ROOT/Dockerfile" | cut -d= -f2-)"
if [[ "$pnpm" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then ok "PNPM_VERSION is exact ($pnpm)"
else bad "PNPM_VERSION is not an exact X.Y.Z (got '${pnpm:-<unset>}')"; fi
for spec in "Makefile:^PNPM_VERSION +\?= $pnpm$" \
            "docker-compose.yml:PNPM_VERSION: \\$\\{PNPM_VERSION:-$pnpm\\}" \
            "bin/claude-compose-gen:PNPM_VERSION: \"\\\\\\$\\{PNPM_VERSION:-$pnpm\\}\"" \
            ".env.example:^PNPM_VERSION=$pnpm$"; do
    f="${spec%%:*}" re="${spec#*:}"
    grep -Eq "$re" "$REPO_ROOT/$f" && ok "$f: PNPM_VERSION default is $pnpm" || bad "$f: PNPM_VERSION default is not $pnpm"
done
if grep -Eq '(NODE_VERSION|UV_VERSION) *[:=]' "$REPO_ROOT/docker-compose.yml" "$REPO_ROOT/bin/claude-compose-gen" "$REPO_ROOT/.env.example"; then
    bad "compose / compose-gen / .env.example still pass NODE_VERSION or UV_VERSION"
else
    ok "compose / compose-gen / .env.example pass no NODE_VERSION / UV_VERSION"
fi

mk() { env -i PATH="$PATH" HOME="$HOME" "$@" make -s -C "$WORK" --no-print-directory help; }
WORK="$(mktemp -d)"
cp "$REPO_ROOT/Makefile" "$WORK/"
for v in NODE_VERSION UV_VERSION; do
    out="$(env -i PATH="$PATH" make -s -C "$WORK" help "$v=1" 2>&1)"
    [[ $? -ne 0 && "$out" == *"$v is no longer a build setting"*Dockerfile* ]] \
        && ok "make refuses $v on the command line" || bad "make did not refuse $v on the command line: $out"
    printf '%s=1\n' "$v" > "$WORK/.env"
    out="$(mk 2>&1)"
    [[ $? -ne 0 && "$out" == *"$v is no longer a build setting"* ]] \
        && ok "make refuses $v from .env" || bad "make did not refuse $v from .env: $out"
    rm -f "$WORK/.env"
    mk "$v=24.0.0" >/dev/null 2>&1 && ok "make accepts $v from the environment" \
        || bad "make refused $v from the environment (node images export NODE_VERSION)"
done

DB="$REPO_ROOT/.github/dependabot.yml"
awk '/package-ecosystem: docker/{d=1} d' "$DB" | grep -q "dependency-name: node" \
    && awk '/package-ecosystem: docker/{d=1} d' "$DB" | grep -q "version-update:semver-major" \
    && ok "dependabot docker entry ignores node majors" || bad "dependabot docker entry does not ignore node majors"

echo "pins: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
