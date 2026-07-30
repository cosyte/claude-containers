#!/usr/bin/env bash
# Unit tests for the baked install-guide — the "Installing packages"
# section of the baked global `claude-config/CLAUDE.md` that teaches an
# in-container Claude Code session the mise-first package-install pattern per
# ecosystem (Python / Node / Rust / Go), the PEP-668 dead-ends for the system
# Python 3.11 interpreter, the no-sudo/no-apt reality of a container (system
# libraries have no self-service path — the worker-tier apt path that used to
# provide one was retired with the substrate; see docs/legacy-sysbox-broker.md),
# the /cache shared cache, and the explicit refusal of sudo /
# --break-system-packages / edits to /etc,/opt,/usr.
#
# NO docker, NO sysbox. §8a of entrypoint.sh already installs the baked
# CLAUDE.md into the running container on first start (proven by
# test/unit.sh); this unit test is a **content contract** on the baked file
# itself — an in-repo regression guard that every mandatory phrase survives
# future edits, so an in-container agent that reads the file gets actionable
# guidance instead of flailing on a PEP-668 refusal, a sudo dead-end, or a
# break-system-packages footgun.
#
#   A. claude-config/CLAUDE.md — the "Installing packages" section exists,
#      names each ecosystem's mise-first invocation, calls out the PEP-668
#      externally-managed reality with every dead-end path (`--user`,
#      `--break-system-packages`, `uv pip install --system`), points at
#      `uv run --with` for a one-off script, wires Node/Rust/Go, states there
#      is no self-service path for system libraries, points at the shared cache's
#      `/cache` for the shared cache, and refuses `sudo` +
#      `--break-system-packages` + edits to `/etc`/`/opt`/`/usr`.
#   B. entrypoint.sh §8a — the baked CLAUDE.md install path is unchanged
#      (this item ships GUIDANCE, not new mechanism); the section is
#      surfaced through the same §8a "only fill what's absent" contract.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_MD="$REPO_ROOT/claude-config/CLAUDE.md"
ENTRY="$REPO_ROOT/entrypoint.sh"

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
has()  { grep -qF -- "$2" "$1"; }
hasE() { grep -qE -- "$2" "$1"; }

# ============================================================================================
echo "== A. claude-config/CLAUDE.md: the 'Installing packages' content contract =="
# ============================================================================================
[[ -f "$CLAUDE_MD" ]] && ok "claude-config/CLAUDE.md exists" \
    || { bad "claude-config/CLAUDE.md missing — nothing to gate on"; echo "FAIL"; exit 1; }

# A0. The section header itself.
if hasE "$CLAUDE_MD" '^## Installing packages$'; then
    ok "'## Installing packages' section header present"
else
    bad "expected a top-level section '## Installing packages'"
fi

# A1. mise is called out as an INTERPRETER/TOOLCHAIN provisioner, not a package one.
# This is the load-bearing conceptual point — mise use python@3.12 is step 1,
# `pip install` is step 2. Without this the agent thinks `mise` alone will do it.
if has "$CLAUDE_MD" 'mise' && has "$CLAUDE_MD" 'interpreters/toolchains'; then
    ok "section frames mise as an interpreters/toolchains provisioner (not a package one)"
else
    bad "section should explicitly say mise provisions 'interpreters/toolchains', not language packages"
fi
if hasE "$CLAUDE_MD" 'mise first,? then'; then
    ok "'mise first, then <language pm>' chain-of-command stated"
else
    bad "the 'mise first, then <language pm>' rule should be stated verbatim"
fi

# A2. (a) Python — mise use python@3.12 first, then pip install; PEP-668 dead-ends
#     for --user, --break-system-packages, uv pip install --system; uv run --with
#     for a one-off script.
if hasE "$CLAUDE_MD" 'mise use python@3\.12'; then
    ok "Python: 'mise use python@3.12' named as the first step"
else
    bad "Python: 'mise use python@3.12' MUST be the first invocation (not python@3, not 'mise use python')"
fi
if has "$CLAUDE_MD" 'PEP 668' || has "$CLAUDE_MD" 'PEP-668'; then
    ok "Python: PEP 668 named as the reason system python3 refuses"
else
    bad "Python: PEP 668 (externally-managed) MUST be named as the reason system python3 refuses"
fi
if has "$CLAUDE_MD" 'externally-managed'; then
    ok "Python: 'externally-managed' language used verbatim (PEP 668 terminology)"
else
    bad "Python: the phrase 'externally-managed' MUST appear (PEP 668's own terminology)"
fi
# All three dead-ends must be explicitly refuted — --user, --break-system-packages,
# uv pip install --system. If any is missing an agent will try it and fail confused.
if has "$CLAUDE_MD" '--user'; then
    ok "Python: '--user' called out as a dead-end against system python3"
else
    bad "Python: '--user' MUST be named as a dead-end (PEP 668 refuses it too)"
fi
if has "$CLAUDE_MD" '--break-system-packages'; then
    ok "Python: '--break-system-packages' called out as a dead-end"
else
    bad "Python: '--break-system-packages' MUST be named as a dead-end"
fi
if has "$CLAUDE_MD" 'uv pip install --system'; then
    ok "Python: 'uv pip install --system' called out as a dead-end"
else
    bad "Python: 'uv pip install --system' MUST be named as a dead-end (targets the same interpreter)"
fi
# One-off script → uv run --with
if hasE "$CLAUDE_MD" 'uv run --with'; then
    ok "Python: 'uv run --with <pkg>' named as the one-off ephemeral pattern"
else
    bad "Python: 'uv run --with' MUST be named as the one-off script pattern"
fi

# A3. (b) Node — mise use node@22 first, then pnpm/npm; ignore-scripts + per-repo opt-out.
if hasE "$CLAUDE_MD" 'mise use node@22'; then
    ok "Node: 'mise use node@22' named as the first step"
else
    bad "Node: 'mise use node@22' MUST be the first invocation"
fi
if has "$CLAUDE_MD" 'pnpm add' && (has "$CLAUDE_MD" 'npm install' || has "$CLAUDE_MD" 'npm i'); then
    ok "Node: pnpm add / npm install named as the second step"
else
    bad "Node: 'pnpm add' and 'npm install' MUST be named as the second step"
fi
if has "$CLAUDE_MD" 'ignore-scripts=true' && has "$CLAUDE_MD" '/workspace/.npmrc'; then
    ok "Node: ignore-scripts=true + per-repo /workspace/.npmrc opt-out both named"
else
    bad "Node: ignore-scripts=true (default) + per-repo /workspace/.npmrc opt-out MUST both be named"
fi

# A4. (c) Rust — mise use rust first, then cargo add.
if hasE "$CLAUDE_MD" 'mise use rust'; then
    ok "Rust: 'mise use rust' named as the first step"
else
    bad "Rust: 'mise use rust' MUST be the first invocation"
fi
if has "$CLAUDE_MD" 'cargo add'; then
    ok "Rust: 'cargo add' named as the second step"
else
    bad "Rust: 'cargo add' MUST be named as the second step"
fi

# A5. (d) Go — mise use go@1.23 first, then go install.
if hasE "$CLAUDE_MD" 'mise use go@1\.23'; then
    ok "Go: 'mise use go@1.23' named as the first step"
else
    bad "Go: 'mise use go@1.23' MUST be the first invocation"
fi
if has "$CLAUDE_MD" 'go install'; then
    ok "Go: 'go install' named as the second step"
else
    bad "Go: 'go install' MUST be named as the second step"
fi

# A6. (e) System libraries — no sudo, no self-service path (the Sysbox-worker
# apt tier was retired; see docs/legacy-sysbox-broker.md).
if has "$CLAUDE_MD" 'no `sudo`' \
   || has "$CLAUDE_MD" 'no sudo' \
   || has "$CLAUDE_MD" "**no \`sudo\`**"; then
    ok "System libs: 'no sudo' called out"
else
    bad "System libs: the phrase 'no sudo' MUST appear"
fi
if has "$CLAUDE_MD" 'no self-service path'; then
    ok "System libs: 'no self-service path' stated (no in-session apt mechanism)"
else
    bad "System libs: 'no self-service path' MUST be stated (there is no in-session apt mechanism)"
fi
if has "$CLAUDE_MD" 'base-image rebuild'; then
    ok "System libs: 'base-image rebuild' named as the only route to a new syslib"
else
    bad "System libs: 'base-image rebuild' MUST be named as the only route to a new syslib"
fi

# A7. (f) the shared cache — /cache is where everything lands.
if hasE "$CLAUDE_MD" '/cache' \
   && (has "$CLAUDE_MD" 'shared cache' || has "$CLAUDE_MD" 'Shared cache'); then
    ok "Cache: '/cache' named as the shared cache"
else
    bad "Cache: '/cache' as the shared cache MUST be named"
fi
if has "$CLAUDE_MD" 'cache hit' && has "$CLAUDE_MD" 'parallel workers'; then
    ok "Cache: 'cache hit for the next launch + parallel workers' benefit stated"
else
    bad "Cache: the 'cache hit for the next launch + parallel workers' payoff MUST be stated"
fi

# A8. (g) Explicit refusal — sudo, --break-system-packages, and edits to /etc,/opt,/usr.
# This is the belt-and-suspenders line: even if an agent misreads one of the ecosystem
# rows, the final refusal line should stop it from escalating.
if has "$CLAUDE_MD" 'Never `sudo`' \
   || has "$CLAUDE_MD" 'Never sudo' \
   || hasE "$CLAUDE_MD" 'Never .*sudo'; then
    ok "Refusal: 'Never sudo' stated verbatim"
else
    bad "Refusal: an explicit 'Never sudo' line MUST appear"
fi
if has "$CLAUDE_MD" '--break-system-packages'; then
    ok "Refusal: '--break-system-packages' explicitly refused"
else
    bad "Refusal: '--break-system-packages' MUST be explicitly refused"
fi
if has "$CLAUDE_MD" '/etc' && has "$CLAUDE_MD" '/opt' && has "$CLAUDE_MD" '/usr'; then
    ok "Refusal: '/etc', '/opt', '/usr' explicitly named as no-touch paths"
else
    bad "Refusal: '/etc' + '/opt' + '/usr' MUST all be named as no-touch paths"
fi

# ============================================================================================
echo "== B. entrypoint.sh §8a: baked CLAUDE.md install path unchanged (no new mechanism) =="
# ============================================================================================
bash -n "$ENTRY" && ok "entrypoint.sh parses (bash -n)" || bad "entrypoint.sh has a syntax error"

# Extract §8a so the assertion is scoped and cannot be masked by a lookalike elsewhere.
SEC8A="$(awk '/^# 8a\. Global CLAUDE.md/,/^# 8b\./' "$ENTRY")"
if grep -qF 'BAKE_DIR/CLAUDE.md' <<<"$SEC8A" \
   && grep -qF '! -e "$CLAUDE_CONFIG_DIR/CLAUDE.md"' <<<"$SEC8A" \
   && grep -qF 'install -o' <<<"$SEC8A"; then
    ok "§8a still installs BAKE_DIR/CLAUDE.md when target is absent (no-clobber, install -o)"
else
    bad "§8a's baked-CLAUDE.md install ('only fill what's absent') MUST be intact — no entrypoint change was expected for the install guide"
fi

# ============================================================================================
TOTAL=$((PASS+FAIL))
echo ""
echo "PASS=$PASS  FAIL=$FAIL  (of $TOTAL)"
[[ $FAIL -eq 0 ]] && echo "OK" || { echo "FAIL"; exit 1; }
