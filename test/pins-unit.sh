#!/usr/bin/env bash
# pins-unit.sh: the base image, uv and pnpm are pinned where Dependabot (or a reader) can bump
# them. Static: no docker, no network.
#   - both FROM lines are a literal tag plus @sha256 digest, never built from an ARG
#     (Dependabot cannot rewrite those, dependabot-core#2057);
#   - PNPM_VERSION is an exact version, and it is the pnpm the repositories pin in package.json's
#     `packageManager`, as test/lib/repos-package-manager records it: in the Dockerfile (the ARG
#     and the comment above it), Makefile, docker-compose.yml, claude-compose-gen and
#     .env.example, and in the two docs that state it (docs/environment-variables.md,
#     docs/toolchain-provisioning.md). A self-check on a copy moved to another version shows the
#     declarations agreeing with each other is not what passes;
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

# The expected pnpm: the repositories' `packageManager` value, kept in one file (its header says
# where it comes from and how to move it). The declarations agreeing with each other is not
# enough: moving every one of them to another version together would stay green.
EXPECT_FILE="test/lib/repos-package-manager"
pnpm="$(grep -E '^ARG PNPM_VERSION=' "$REPO_ROOT/Dockerfile" | cut -d= -f2-)"
if [[ "$pnpm" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then ok "PNPM_VERSION is exact ($pnpm)"
else bad "PNPM_VERSION is not an exact X.Y.Z (got '${pnpm:-<unset>}')"; fi
want=""
mapfile -t lines < <(grep -Ev '^[[:space:]]*(#|$)' "$REPO_ROOT/$EXPECT_FILE" 2>/dev/null)
if (( ${#lines[@]} == 1 )) && [[ "${lines[0]}" =~ ^pnpm@([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    want="${BASH_REMATCH[1]}"
    ok "$EXPECT_FILE: the repositories pin pnpm@$want"
else
    bad "$EXPECT_FILE: want exactly one non-comment line, pnpm@X.Y.Z (got ${#lines[@]}: ${lines[*]:-none})"
fi

# pnpm_decls <root> <version>: one line per pnpm declaration under <root>, "PASS <what>" when it
# says <version> and "FAIL <what>" when it does not.
pnpm_decls() {
    local root="$1" v="$2" got spec f re what
    local e="${v//./\\.}"
    got="$(grep -E '^ARG PNPM_VERSION=' "$root/Dockerfile" | cut -d= -f2-)"
    [[ "$got" == "$v" ]] && echo "PASS Dockerfile: ARG PNPM_VERSION is $v" \
        || echo "FAIL Dockerfile: ARG PNPM_VERSION is ${got:-<unset>}, not $v"
    for spec in "Dockerfile:^# $e is the version the repos these sessions work on pin" \
                "Makefile:^PNPM_VERSION +\?= $e$" \
                "docker-compose.yml:PNPM_VERSION: \\$\\{PNPM_VERSION:-$e\\}" \
                "bin/claude-compose-gen:PNPM_VERSION: \"\\\\\\$\\{PNPM_VERSION:-$e\\}\"" \
                ".env.example:^PNPM_VERSION=$e$" \
                "docs/environment-variables.md:^\\| \`PNPM_VERSION\` \\| \`$e\` \\|" \
                "docs/toolchain-provisioning.md:\`ARG PNPM_VERSION=$e\`"; do
        f="${spec%%:*}" re="${spec#*:}" what="${spec%%:*}"
        [[ "$re" == "^# "* ]] && what="$f (the comment above the ARG)"
        grep -Eq "$re" "$root/$f" && echo "PASS $what: pnpm is $v" || echo "FAIL $what: pnpm is not $v"
    done
}
PNPM_FILES=(Dockerfile Makefile docker-compose.yml bin/claude-compose-gen .env.example
            docs/environment-variables.md docs/toolchain-provisioning.md)

# Every declaration says the repositories' version (or, with no readable expectation, at least
# agrees with the Dockerfile's, so a broken expectation file still shows any drift).
while read -r verdict what; do
    if [[ "$verdict" == PASS ]]; then ok "$what"; else bad "$what"; fi
done < <(pnpm_decls "$REPO_ROOT" "${want:-$pnpm}")

# Self-check, on a copy: every declaration moved together to another version (12.14.0, what
# reverting the move to the repositories' pin did) agrees with itself, and is still refused.
if [[ -n "$want" ]]; then
    other=12.14.0; [[ "$want" == "$other" ]] && other=10.34.5
    COPY="$(mktemp -d)"
    for f in "${PNPM_FILES[@]}"; do
        mkdir -p "$COPY/$(dirname "$f")" && cp "$REPO_ROOT/$f" "$COPY/$f"
        sed -i "s/${want//./\\.}/$other/g" "$COPY/$f"
    done
    agree="$(pnpm_decls "$COPY" "$other" | grep -c '^FAIL')"
    refused="$(pnpm_decls "$COPY" "$want" | grep -c '^FAIL')"
    total="$(pnpm_decls "$COPY" "$want" | wc -l)"
    (( agree == 0 )) && ok "self-check: a copy moved to pnpm $other agrees with itself" \
        || bad "self-check: the copy moved to pnpm $other does not agree with itself ($agree mismatches)"
    (( refused == total )) && ok "self-check: every one of its $total declarations is refused against pnpm@$want" \
        || bad "self-check: only $refused of $total declarations in the copy at pnpm $other were refused"
    rm -rf "$COPY"
fi

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
