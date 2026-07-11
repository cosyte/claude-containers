#!/usr/bin/env bash
# cache-proxy-unit.sh — pure-logic tests for PKG-6: the controller-side pull-through cache.
# NO docker, NO network, NO real curl, NO root — safe for CI / scripts/verify.sh.
#
# PKG-6 turns the fleet's package egress into a single audited choke point: a root-owned
# pull-through cache on the controller's inner dockerd is the ONLY host that reaches the
# public registries; workers point their package managers at it and narrow their egress to
# just the proxy. The LIVE proof — stand up a real Nexus, install npm/pip/go through it, a
# second worker is a cache hit, egress narrowed to the proxy, proxy-down → provision refused
# — needs a Sysbox host + a running proxy and is the on-host manual gate (docs/caching-proxy.md).
# Here we drive the LOGIC through the script's seams: the fail-closed ready gate + client-apply
# refusal, the launch template, the single-choke-point egress composition, and the broker's
# worker wiring — a regression in any is a safety/supply-chain break that must gate in CI.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/bin/claude-cache-proxy"
FIREWALL="$REPO_ROOT/bin/claude-egress-firewall"
BROKER="$REPO_ROOT/bin/claude-worker-broker"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "PKG-6 controller-side caching proxy (claude-cache-proxy)"

# ---- sources cleanly as a library (test seam), defines cache_proxy_* and does NOT dispatch -------
# shellcheck disable=SC1090
if source "$SCRIPT" 2>/dev/null \
   && declare -F cache_proxy_ready >/dev/null \
   && declare -F cache_proxy_client_apply >/dev/null \
   && declare -F cache_proxy_template_args >/dev/null; then
    _src_ok=1
else
    _src_ok=0
fi
# Sourcing the script activated its `set -e` in THIS shell — a test must not inherit the
# SUT's errexit (a probe/assert returning non-zero is normal here, not a fatal error).
set +e

# Define ok/bad AFTER the source: _common.sh (sourced by the script) ships its own ok()
# and would otherwise shadow ours.
PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

if [[ "$_src_ok" == 1 ]]; then
    ok "sources as a library — cache_proxy_* defined, no dispatch on source"
else
    bad "sourcing the script failed or did not define the cache_proxy_* functions"
    echo "PKG-6: $PASS passed, $FAIL failed"; exit 1
fi

# ---- base URL + endpoint composition -------------------------------------------------------------
echo "== url + endpoint composition =="
got="$( cache_proxy_base_url )"
[[ "$got" == "http://claude-cache-proxy:8081" ]] && ok "default base url = http://<name>:8081" || bad "default base url wrong: $got"

got="$( CLAUDE_CACHE_PROXY_HOST=proxy.internal CLAUDE_CACHE_PROXY_PORT=9000 bash -c 'source "'"$SCRIPT"'"; cache_proxy_base_url' )"
[[ "$got" == "http://proxy.internal:9000" ]] && ok "HOST/PORT override composes the base url" || bad "HOST/PORT override wrong: $got"

got="$( CLAUDE_CACHE_PROXY_URL=https://cache.example.com/ bash -c 'source "'"$SCRIPT"'"; cache_proxy_base_url' )"
[[ "$got" == "https://cache.example.com" ]] && ok "explicit URL override wins, trailing slash stripped" || bad "URL override wrong: $got"

got="$( cache_proxy_endpoint "http://p:8081" "/repository/npm/" )"
[[ "$got" == "http://p:8081/repository/npm/" ]] && ok "endpoint join keeps one slash (leading path)" || bad "endpoint join wrong: $got"
got="$( cache_proxy_endpoint "http://p:8081/" "repository/pypi/simple" )"
[[ "$got" == "http://p:8081/repository/pypi/simple" ]] && ok "endpoint join adds the slash (no leading path)" || bad "endpoint join wrong: $got"

# ---- client-env: the fixed worker-consumption contract -------------------------------------------
echo "== client-env contract =="
env_out="$( cache_proxy_client_env )"
for kv in \
  "CLAUDE_CACHE_PROXY_URL=http://claude-cache-proxy:8081" \
  "CLAUDE_CACHE_PROXY_NPM_REGISTRY=http://claude-cache-proxy:8081/repository/npm/" \
  "CLAUDE_CACHE_PROXY_PIP_INDEX=http://claude-cache-proxy:8081/repository/pypi/simple" \
  "CLAUDE_CACHE_PROXY_GOPROXY=http://claude-cache-proxy:8081/repository/go/" \
  "CLAUDE_CACHE_PROXY_APT_MIRROR=http://claude-cache-proxy:8081/repository/apt/"; do
    grep -qxF "$kv" <<<"$env_out" && ok "client-env emits: $kv" || bad "client-env missing: $kv"
done

# ---- launch template ------------------------------------------------------------------------------
echo "== launch template =="
tmpl="$( cache_proxy_template_args )"
grep -qx 'run' <<<"$tmpl" && grep -qx '\-d' <<<"$tmpl" && ok "template is a detached docker run" || bad "template not a detached run"
grep -qx 'claude-cache-proxy' <<<"$tmpl" && ok "template names the proxy container" || bad "template missing the container name"
grep -qx 'claude.cacheproxy=1' <<<"$tmpl" && ok "template labels claude.cacheproxy=1 (NOT claude.worker — the reaper must not reap it)" || bad "template missing the cacheproxy label"
grep -qx 'claude.worker=1' <<<"$tmpl" && bad "template must NOT carry claude.worker=1 (the reaper would kill the proxy)" || ok "template carries no claude.worker label"
grep -qx 'no-new-privileges' <<<"$tmpl" && ok "template sets no-new-privileges" || bad "template missing no-new-privileges"
grep -q 'claude-cache-proxy-data:/nexus-data' <<<"$tmpl" && ok "template mounts the persistent cache volume" || bad "template missing the cache volume mount"
grep -qx 'sonatype/nexus3:latest' <<<"$tmpl" && ok "template uses the default Nexus image" || bad "template missing the default image"
grep -qx '\-\-publish' <<<"$tmpl" || grep -qx '\-p' <<<"$tmpl" && bad "template must NOT publish a host port (shared network is the reach path)" || ok "template publishes no host port (no widened surface)"
# image override + resources
tmpl2="$( CLAUDE_CACHE_PROXY_IMAGE=my/proxy:1 CLAUDE_CACHE_PROXY_MEM=4g CLAUDE_CACHE_PROXY_CPUS=4 bash -c 'source "'"$SCRIPT"'"; cache_proxy_template_args' )"
grep -qx 'my/proxy:1' <<<"$tmpl2" && grep -qx '4g' <<<"$tmpl2" && grep -qx '4' <<<"$tmpl2" && ok "image + resource overrides flow into the template" || bad "image/resource overrides did not flow"

# ---- fail-closed: require_root ---------------------------------------------------------------------
echo "== fail-closed: root requirement =="
# Override id() so the sourced function sees a non-root uid without needing a real one.
( id() { [[ "$1" == -u ]] && echo 1000 || command id "$@"; }
  cache_proxy_require_root start ) >/dev/null 2>&1 \
    && bad "require_root accepted a non-root uid" || ok "require_root refuses a non-root uid (fail closed)"
( id() { [[ "$1" == -u ]] && echo 0 || command id "$@"; }
  cache_proxy_require_root start ) >/dev/null 2>&1 \
    && ok "require_root accepts root" || bad "require_root rejected root"
# the test seam bypass
( id() { [[ "$1" == -u ]] && echo 1000 || command id "$@"; }
  CLAUDE_CACHE_PROXY_SKIP_ROOT=1 cache_proxy_require_root start ) >/dev/null 2>&1 \
    && ok "CLAUDE_CACHE_PROXY_SKIP_ROOT=1 bypasses the root check (test seam)" || bad "SKIP_ROOT seam did not bypass"

# ---- fail-closed: the ready gate never treats unknown as ready ------------------------------------
echo "== fail-closed: ready gate =="
# NB: the script freezes CP_READY_TIMEOUT from the env at SOURCE time (like the broker's frozen
# WORKER_* globals), so a per-call CLAUDE_* prefix wouldn't take — set the global directly in each
# subshell to bound the probe loop to a single iteration (no 120s real sleep in CI).
# curl stub yields a connect failure (000): ready must return non-zero within the bounded timeout.
( CP_READY_TIMEOUT=0; cache_proxy_curl() { echo 000; return 0; }; cache_proxy_ready ) >/dev/null 2>&1 \
    && bad "ready() returned success while the proxy was DOWN (000)" || ok "ready() FAILS when the proxy is unreachable (never 'unknown = ready')"
# curl stub yields 200: ready succeeds.
( CP_READY_TIMEOUT=0; cache_proxy_curl() { echo 200; return 0; }; cache_proxy_ready ) >/dev/null 2>&1 \
    && ok "ready() succeeds on HTTP 200" || bad "ready() failed on a 200 health response"
# a 503 (up but not serving) is NOT ready.
( CP_READY_TIMEOUT=0; cache_proxy_curl() { echo 503; return 0; }; cache_proxy_ready ) >/dev/null 2>&1 \
    && bad "ready() accepted a 5xx as ready" || ok "ready() rejects a 5xx (up but not serving)"
# a 302 (mid-startup redirect-to-login) is NOT ready — only 2xx counts (fail-closed tightening).
( CP_READY_TIMEOUT=0; cache_proxy_curl() { echo 302; return 0; }; cache_proxy_ready ) >/dev/null 2>&1 \
    && bad "ready() accepted a 3xx redirect as ready (would proceed against a not-yet-serving proxy)" || ok "ready() rejects a 3xx (only 2xx = serving)"
# a non-numeric timeout fails closed (die).
( CP_READY_TIMEOUT=abc; cache_proxy_curl() { echo 200; return 0; }; cache_proxy_ready ) >/dev/null 2>&1 \
    && bad "a bad READY_TIMEOUT did not fail closed" || ok "a non-numeric READY_TIMEOUT fails closed"

# ---- fail-closed: client-apply refuses when the proxy is down ------------------------------------
echo "== fail-closed: client-apply refuses on a down proxy =="
# Use a CLAUDE_USER absent from passwd so client-apply falls back to $HOME (our temp dir)
# rather than resolving the real user's home via getent — keeps the test hermetic.
FAKE_USER="cache-proxy-test-nobody"
home_down="$TMP/home-down"; mkdir -p "$home_down"
(
  export HOME="$home_down" CLAUDE_USER="$FAKE_USER"
  cache_proxy_ready() { return 1; }              # proxy DOWN
  cache_proxy_client_apply
) >/dev/null 2>&1 \
  && bad "client-apply proceeded while the proxy was DOWN (would open the fallback hole)" \
  || ok "client-apply REFUSES (dies) when the proxy is unreachable (no open-egress fallback)"
# and it wrote NOTHING (no half-applied config that a fallback could use)
[[ ! -e "$home_down/.npmrc" && ! -e "$home_down/.config/pip/pip.conf" ]] \
  && ok "client-apply wrote no package-manager config on the refusal path" \
  || bad "client-apply left partial config behind on the down-proxy path"

# ---- client-apply writes the right config when the proxy is up -----------------------------------
echo "== client-apply configures package managers when the proxy is ready =="
home_up="$TMP/home-up"; mkdir -p "$home_up"
(
  export HOME="$home_up" CLAUDE_USER="$FAKE_USER"
  cache_proxy_ready() { return 0; }              # proxy UP
  cache_proxy_client_apply
) >/dev/null 2>&1
grep -qxF "registry=http://claude-cache-proxy:8081/repository/npm/" "$home_up/.npmrc" 2>/dev/null \
  && ok "client-apply wrote the npm registry to ~/.npmrc" || bad "client-apply did not set the npm registry"
grep -q "index-url = http://claude-cache-proxy:8081/repository/pypi/simple" "$home_up/.config/pip/pip.conf" 2>/dev/null \
  && ok "client-apply wrote the pip index-url to pip.conf" || bad "client-apply did not set the pip index-url"
grep -q "trusted-host = claude-cache-proxy" "$home_up/.config/pip/pip.conf" 2>/dev/null \
  && ok "client-apply trusts the proxy host for pip (plain-HTTP internal endpoint)" || bad "client-apply did not trust the pip host"
grep -qxF "export GOPROXY=http://claude-cache-proxy:8081/repository/go/" "$home_up/.config/claude-cache-proxy.env" 2>/dev/null \
  && ok "client-apply wrote GOPROXY to the env profile" || bad "client-apply did not set GOPROXY"
# idempotent: a second apply does not duplicate the npm line
(
  export HOME="$home_up" CLAUDE_USER="$FAKE_USER"
  cache_proxy_ready() { return 0; }
  cache_proxy_client_apply
) >/dev/null 2>&1
n="$(grep -cxF "registry=http://claude-cache-proxy:8081/repository/npm/" "$home_up/.npmrc")"
[[ "$n" == 1 ]] && ok "client-apply is idempotent (npm registry line not duplicated)" || bad "client-apply duplicated the npm line ($n)"

# pip trusted-host derives from the DIALED host (URL wins), not $CP_HOST — else a URL override would
# trust the wrong host and pip would reject the plain-HTTP endpoint.
home_url="$TMP/home-url"; mkdir -p "$home_url"
(
  # cache_proxy_base_url reads CLAUDE_CACHE_PROXY_URL live, so no re-source needed — just set the env.
  export HOME="$home_url" CLAUDE_USER="$FAKE_USER" \
         CLAUDE_CACHE_PROXY_URL=http://urlhost.internal:8081/ CLAUDE_CACHE_PROXY_HOST=namehost
  cache_proxy_ready() { return 0; }
  cache_proxy_client_apply
) >/dev/null 2>&1
grep -q "index-url = http://urlhost.internal:8081/repository/pypi/simple" "$home_url/.config/pip/pip.conf" 2>/dev/null \
  && ok "client-apply pip index-url follows the URL override host" || bad "pip index-url did not follow the URL host"
grep -q "trusted-host = urlhost.internal" "$home_url/.config/pip/pip.conf" 2>/dev/null \
  && ok "client-apply pip trusted-host = the URL's host (not \$CP_HOST) — no host divergence" || bad "pip trusted-host diverged from the dialed host"

# ---- dispatch: unknown command + help --------------------------------------------------------------
echo "== dispatch =="
( cache_proxy_main bogus ) >/dev/null 2>&1 && bad "an unknown command did not fail" || ok "an unknown command fails (die)"
( cache_proxy_main --help ) >/dev/null 2>&1 && ok "--help exits 0" || bad "--help did not exit 0"

# ==================================================================================================
# Egress firewall: single-choke-point composition (PKG-6 change to bin/claude-egress-firewall)
# ==================================================================================================
echo "== egress firewall: single-choke-point host composition =="
hosts() { env "$@" CLAUDE_EGRESS_PRINT_HOSTS=1 bash "$FIREWALL" 2>/dev/null; }

# OFF (no proxy host) is byte-identical to before + still carries npmjs (regression guard).
OFF="$(hosts)"
grep -qxF "registry.npmjs.org" <<<"$OFF" && ok "proxy OFF: public npm registry still present (byte-identical base)" || bad "proxy OFF dropped npmjs"
grep -qxF "claude-cache-proxy" <<<"$OFF" && bad "proxy OFF leaked a proxy host into the allowlist" || ok "proxy OFF: no proxy host in the allowlist (nothing implicit)"

# ON: the proxy host is present, the public npm registry is DROPPED (single choke point).
ON="$(hosts CLAUDE_CACHE_PROXY_HOST=cache.internal)"
grep -qxF "cache.internal" <<<"$ON" && ok "proxy ON: the proxy host is in the allowlist" || bad "proxy ON: proxy host missing"
grep -qxF "registry.npmjs.org" <<<"$ON" && bad "proxy ON: public npm registry NOT dropped (choke point leaks)" || ok "proxy ON: public npm registry dropped (npm egress is the proxy only)"
# base infra hosts survive (the worker still needs Claude API + GitHub)
for h in api.anthropic.com github.com; do
  grep -qxF "$h" <<<"$ON" || bad "proxy ON dropped a required base host: $h"
done
ok "proxy ON: base infra hosts (Claude API / GitHub) survive"

# ON supersedes the curated package profile: pypi/apt public registries are NOT added even if requested.
ON_PKG="$(hosts CLAUDE_CACHE_PROXY_HOST=cache.internal CLAUDE_EGRESS_PACKAGES=1 CLAUDE_EGRESS_APT=1)"
leak=0
for h in pypi.org files.pythonhosted.org crates.io deb.debian.org security.debian.org; do
  grep -qxF "$h" <<<"$ON_PKG" && leak=1
done
[[ "$leak" -eq 0 ]] && ok "proxy ON supersedes CLAUDE_EGRESS_PACKAGES/_APT: no public registry appears (proxy is the sole egress)" \
                    || bad "proxy ON still leaked a public package/apt registry (choke point not single)"
grep -qxF "cache.internal" <<<"$ON_PKG" && ok "proxy ON (+PACKAGES/APT requested): only the proxy host is the package egress" || bad "proxy host missing in the combined case"

# EXTRA_HOSTS still composes in proxy mode (operator-added internal hosts survive).
ON_EXTRA="$(hosts CLAUDE_CACHE_PROXY_HOST=cache.internal CLAUDE_EGRESS_EXTRA_HOSTS=my.internal.host)"
grep -qxF "my.internal.host" <<<"$ON_EXTRA" && ok "proxy ON: CLAUDE_EGRESS_EXTRA_HOSTS still composes" || bad "proxy ON dropped EXTRA_HOSTS"

# ---- egress firewall: the proxy PORT punch-through (the gate-refuter BLOCKER) --------------------
echo "== egress firewall: proxy port punch-through =="
proxy_pin() { env "$@" CLAUDE_EGRESS_PRINT_PROXY=1 bash "$FIREWALL" 2>/dev/null; }
# OFF: empty pin (no port opened).
[[ -z "$(proxy_pin | tr -d ' ')" ]] && ok "proxy OFF: no proxy pin (no extra port opened)" || bad "proxy OFF emitted a proxy pin"
# HOST default → the proxy's own port 8081 is pinned (NOT just 22/80/443 — the BLOCKER).
[[ "$(proxy_pin CLAUDE_CACHE_PROXY_HOST=cache.internal)" == "cache.internal 8081" ]] \
    && ok "proxy ON (HOST): pins the proxy on its own port 8081 (lockdown'd worker can reach it)" \
    || bad "proxy ON (HOST): wrong pin — got '$(proxy_pin CLAUDE_CACHE_PROXY_HOST=cache.internal)'"
# explicit PORT override flows.
[[ "$(proxy_pin CLAUDE_CACHE_PROXY_HOST=cache.internal CLAUDE_CACHE_PROXY_PORT=9000)" == "cache.internal 9000" ]] \
    && ok "proxy ON: CLAUDE_CACHE_PROXY_PORT override is the pinned port" || bad "proxy ON: PORT override not pinned"
# URL wins: host AND port derived from the URL (the MAJOR — pin the host the worker actually dials).
[[ "$(proxy_pin CLAUDE_CACHE_PROXY_URL=http://cache.corp.example:8081/ CLAUDE_CACHE_PROXY_HOST=claude-cache-proxy)" == "cache.corp.example 8081" ]] \
    && ok "proxy ON (URL set): the firewall pins the URL's host, not the HOST default (no host/URL divergence)" \
    || bad "proxy ON (URL): firewall pinned the wrong host — got '$(proxy_pin CLAUDE_CACHE_PROXY_URL=http://cache.corp.example:8081/ CLAUDE_CACHE_PROXY_HOST=claude-cache-proxy)'"
# URL without an explicit port → scheme default (https→443, http→80).
[[ "$(proxy_pin CLAUDE_CACHE_PROXY_URL=https://cache.corp.example/)" == "cache.corp.example 443" ]] \
    && ok "proxy ON (https URL, no port): scheme-default port 443" || bad "proxy ON (https URL): wrong default port"
# URL-only (no HOST) still enters proxy mode and pins the URL host in the allowlist.
ON_URL="$(hosts CLAUDE_CACHE_PROXY_URL=http://cache.corp.example:8081/)"
grep -qxF "cache.corp.example" <<<"$ON_URL" && ok "proxy ON (URL only, no HOST): the URL host is in the allowlist" || bad "proxy ON (URL only): URL host not allowlisted"
grep -qxF "registry.npmjs.org" <<<"$ON_URL" && bad "proxy ON (URL only): public npm registry not dropped" || ok "proxy ON (URL only): public npm registry dropped (choke point holds)"

# ==================================================================================================
# Broker: worker wiring (PKG-6 change to bin/claude-worker-broker broker_template_args)
# ==================================================================================================
echo "== broker: worker wiring =="
# broker_template_args in a subshell so the broker's top-level resolve_parallel_k etc. don't
# disturb this test process; capture the argv it emits with/without the proxy flag.
tmpl_off="$( bash -c 'source "'"$BROKER"'" >/dev/null 2>&1; CLAUDE_CACHE_PROXY=0 broker_template_args hl7 HL7-Q' 2>/dev/null )"
grep -q 'CLAUDE_CACHE_PROXY' <<<"$tmpl_off" && bad "broker leaked cache-proxy env with the flag OFF" || ok "broker template: no cache-proxy env when the flag is OFF (additive, gated)"
grep -qx 'claude-cache-net' <<<"$tmpl_off" && bad "broker joined the proxy network with the flag OFF" || ok "broker template: no proxy network when the flag is OFF"

tmpl_on="$( bash -c 'source "'"$BROKER"'" >/dev/null 2>&1; CLAUDE_CACHE_PROXY=1 broker_template_args hl7 HL7-Q' 2>/dev/null )"
grep -qx 'claude-cache-net' <<<"$tmpl_on" && ok "broker ON: worker joins the shared proxy network" || bad "broker ON: worker did not join the proxy network"
grep -qx 'CLAUDE_CACHE_PROXY=1' <<<"$tmpl_on" && ok "broker ON: worker gets CLAUDE_CACHE_PROXY=1 (its entrypoint runs client-apply)" || bad "broker ON: worker missing CLAUDE_CACHE_PROXY"
grep -qx 'CLAUDE_CACHE_PROXY_HOST=claude-cache-proxy' <<<"$tmpl_on" && ok "broker ON: worker gets CLAUDE_CACHE_PROXY_HOST (its egress narrows to the proxy)" || bad "broker ON: worker missing CLAUDE_CACHE_PROXY_HOST"
# a custom host/net flows through
tmpl_cust="$( bash -c 'source "'"$BROKER"'" >/dev/null 2>&1; CLAUDE_CACHE_PROXY=1 CLAUDE_CACHE_PROXY_HOST=cache.internal CLAUDE_CACHE_PROXY_NET=mynet broker_template_args hl7 HL7-Q' 2>/dev/null )"
grep -qx 'CLAUDE_CACHE_PROXY_HOST=cache.internal' <<<"$tmpl_cust" && grep -qx 'mynet' <<<"$tmpl_cust" \
  && ok "broker ON: custom proxy host + network flow into the worker template" || bad "broker ON: custom host/net did not flow"

echo
echo "cache-proxy-unit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
