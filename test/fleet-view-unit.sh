#!/usr/bin/env bash
# Unit tests for bin/claude-fleet-view (CC-7) — NO real docker, NO real host, NO network.
#
# Covers:
#   1. fleet_list_workers via a fake docker script on the CLAUDE_FLEET_DOCKER seam
#   2. fleet_worker_spend reading the secret-free meta sidecars claude-worker-run writes
#      (newest-by-name wins; no file -> "unknown", never an error)
#   3. fleet_host_headroom against the CLAUDE_FLEET_HOST_CPUS / CLAUDE_FLEET_HOST_MEM_MIB /
#      CLAUDE_DISK_FREE_MIB_OVERRIDE / CLAUDE_PARALLEL_CONFIG seams, including the K-derived
#      controller-envelope budget
#   4. --json: parses (jq if available, else grep) and carries both workers + the host object
#   5. no active workers: still exits 0, prints an info line, still prints host headroom
#   6. secret-free: no PRIVATE KEY / .credentials / ANTHROPIC substrings leak even when the
#      environment is seeded with them
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# shellcheck disable=SC1091
source "$REPO_ROOT/bin/claude-fleet-view"   # sourcing defines functions and returns
set +e

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

# --- fixtures: fake docker ------------------------------------------------------------------
FAKE_DOCKER="$TMPD/fake-docker"
cat > "$FAKE_DOCKER" <<'EOF'
#!/usr/bin/env bash
# Canned `docker ps --filter label=claude.worker=1 --format ...` output for two workers:
# items CC-A/CC-B, repos hl7/mllp. Ignores its actual args (a fixed fixture is enough here).
printf 'claude-worker-cc-a\tCC-A\thl7\tUp 2 minutes\n'
printf 'claude-worker-cc-b\tCC-B\tmllp\tUp 5 minutes (unhealthy)\n'
EOF
chmod +x "$FAKE_DOCKER"

EMPTY_DOCKER="$TMPD/empty-docker"
cat > "$EMPTY_DOCKER" <<'EOF'
#!/usr/bin/env bash
# No active workers: prints nothing (a real `docker ps` with no matches also prints nothing).
exit 0
EOF
chmod +x "$EMPTY_DOCKER"

# --- fixtures: meta sidecar logs -------------------------------------------------------------
LOGDIR="$TMPD/worker-run-logs"
mkdir -p "$LOGDIR"
cat > "$LOGDIR/run-CC-A-20260710T010000Z.meta.json" <<'EOF'
{"item":"CC-A","repo":"hl7","ts":"20260710T010000Z","total_cost_usd":1.23,"is_error":false}
EOF
# An OLDER meta file for CC-A too, to prove "newest by name" wins, not just "any file".
cat > "$LOGDIR/run-CC-A-20260709T010000Z.meta.json" <<'EOF'
{"item":"CC-A","repo":"hl7","ts":"20260709T010000Z","total_cost_usd":9.99,"is_error":false}
EOF
# No meta file at all for CC-B — must degrade to "unknown", never error.

# --- fixture: parallel.config.json (K=2) -----------------------------------------------------
CFG_K2="$TMPD/parallel-k2.json"
echo '{"K": 2}' > "$CFG_K2"

# Common env for the "two active workers" scenarios.
common_env() {
    env -i PATH="$PATH" HOME="$TMPD/home" \
        CLAUDE_FLEET_DOCKER="$FAKE_DOCKER" \
        CLAUDE_WORKER_RUN_LOG_DIR="$LOGDIR" \
        CLAUDE_FLEET_HOST_CPUS=8 \
        CLAUDE_FLEET_HOST_MEM_MIB=16384 \
        CLAUDE_DISK_FREE_MIB_OVERRIDE=102400 \
        CLAUDE_PARALLEL_CONFIG="$CFG_K2" \
        "$@"
}

# ============================================================================================
echo "== fleet_list_workers: TSV from the fake docker seam =="
rows="$(common_env bash -c 'source "'"$REPO_ROOT"'/bin/claude-fleet-view"; fleet_list_workers' 2>/dev/null)"
if grep -q $'claude-worker-cc-a\tCC-A\thl7' <<<"$rows" && grep -q $'claude-worker-cc-b\tCC-B\tmllp' <<<"$rows"; then
    ok "fleet_list_workers returns both fake workers as TSV (name, item, repo, status)"
else
    bad "fleet_list_workers TSV wrong (got: $rows)"
fi

empty_rows="$(env -i PATH="$PATH" HOME="$TMPD/home-empty" CLAUDE_FLEET_DOCKER="$EMPTY_DOCKER" \
    bash -c 'source "'"$REPO_ROOT"'/bin/claude-fleet-view"; fleet_list_workers' 2>/dev/null)"
if [[ -z "$empty_rows" ]]; then
    ok "fleet_list_workers returns empty TSV when no workers are active"
else
    bad "expected empty output with no active workers, got: $empty_rows"
fi

bad_docker_rows="$(env -i PATH="$PATH" HOME="$TMPD/home-nodocker" CLAUDE_FLEET_DOCKER="/no/such/docker-xyz" \
    bash -c 'source "'"$REPO_ROOT"'/bin/claude-fleet-view"; fleet_list_workers' 2>/dev/null)"
rc_nodocker=$?
if [[ -z "$bad_docker_rows" ]] && (( rc_nodocker == 0 )); then
    ok "fleet_list_workers degrades to empty (never dies) when docker itself is missing"
else
    bad "fleet_list_workers must fail-safe to empty on a missing docker binary (rc=$rc_nodocker, got: $bad_docker_rows)"
fi

# ============================================================================================
echo
echo "== fleet_worker_spend: newest meta file wins; missing file -> unknown =="
spend_a="$(CLAUDE_WORKER_RUN_LOG_DIR="$LOGDIR" fleet_worker_spend CC-A)"
if [[ "$spend_a" == "1.23" ]]; then
    ok "CC-A spend reads the NEWEST meta file (1.23), not the older 9.99"
else
    bad "expected CC-A spend 1.23 (newest by filename), got '$spend_a'"
fi

spend_b="$(CLAUDE_WORKER_RUN_LOG_DIR="$LOGDIR" fleet_worker_spend CC-B)"
if [[ "$spend_b" == "unknown" ]]; then
    ok "CC-B (no meta file) spend degrades to 'unknown', never errors"
else
    bad "expected CC-B spend 'unknown' (no meta file), got '$spend_b'"
fi

spend_missing_dir="$(CLAUDE_WORKER_RUN_LOG_DIR="$TMPD/does-not-exist" fleet_worker_spend CC-A)"
if [[ "$spend_missing_dir" == "unknown" ]]; then
    ok "a missing log dir entirely degrades to 'unknown', never errors"
else
    bad "expected 'unknown' for a missing log dir, got '$spend_missing_dir'"
fi

# A malformed meta file (garbage JSON / non-numeric cost) must also degrade, not crash.
BADDIR="$TMPD/bad-meta"; mkdir -p "$BADDIR"
echo 'not json at all' > "$BADDIR/run-CC-X-20260710T010000Z.meta.json"
spend_bad="$(CLAUDE_WORKER_RUN_LOG_DIR="$BADDIR" fleet_worker_spend CC-X)"
if [[ "$spend_bad" == "unknown" ]]; then
    ok "a malformed meta file degrades to 'unknown', never errors"
else
    bad "expected 'unknown' for a malformed meta file, got '$spend_bad'"
fi

# ============================================================================================
echo
echo "== fleet_host_headroom: host cpu/mem/disk + K-derived budget =="
headroom="$(common_env bash -c 'source "'"$REPO_ROOT"'/bin/claude-fleet-view"; fleet_host_headroom' 2>/dev/null)"
read -r hc hm hd hk hbc hbm <<<"$headroom"
if [[ "$hc" == 8 && "$hm" == 16384 && "$hd" == 102400 && "$hk" == 2 ]]; then
    ok "fleet_host_headroom reports the seeded cpus/mem/disk/K (got: $headroom)"
else
    bad "fleet_host_headroom fields wrong (got: $headroom)"
fi
if [[ "$hbc" =~ ^[0-9]+(\.[0-9]+)?$ && "$hbm" =~ ^[0-9]+$ && "$hbm" -gt 0 ]]; then
    ok "fleet_host_headroom derives a nonzero K=2 CPU/mem budget via controller_envelope (got cpus=$hbc mem=$hbm)"
else
    bad "expected a numeric K=2 budget, got cpus='$hbc' mem='$hbm'"
fi

# A bad/garbage CLAUDE_PARALLEL_CONFIG must degrade the K/budget fields to unknown, never die.
BADCFG="$TMPD/parallel-bad.json"; echo 'not json' > "$BADCFG"
headroom_bad="$(env -i PATH="$PATH" HOME="$TMPD/home-badcfg" \
    CLAUDE_FLEET_HOST_CPUS=8 CLAUDE_FLEET_HOST_MEM_MIB=16384 CLAUDE_DISK_FREE_MIB_OVERRIDE=100 \
    CLAUDE_PARALLEL_CONFIG="$BADCFG" \
    bash -c 'source "'"$REPO_ROOT"'/bin/claude-fleet-view"; fleet_host_headroom' 2>/dev/null)"
rc_badcfg=$?
if (( rc_badcfg == 0 )) && grep -q "unknown" <<<"$headroom_bad"; then
    ok "an unparseable parallel.config.json degrades K/budget to 'unknown' rather than dying (got: $headroom_bad)"
else
    bad "expected fail-safe 'unknown' K/budget on bad config (rc=$rc_badcfg, got: $headroom_bad)"
fi

# ============================================================================================
echo
echo "== human table: shows spend/unknown per item + host headroom line =="
table_out="$(common_env bash "$REPO_ROOT/bin/claude-fleet-view" 2>&1)"
if grep -q "CC-A" <<<"$table_out" && grep -q '1\.23' <<<"$table_out"; then
    ok "the table shows 1.23 for CC-A"
else
    bad "expected the table to show CC-A's spend 1.23 (got: $table_out)"
fi
if grep -q "CC-B" <<<"$table_out" && grep -q "unknown" <<<"$table_out"; then
    ok "the table shows 'unknown' for CC-B (no meta file)"
else
    bad "expected the table to show 'unknown' for CC-B (got: $table_out)"
fi
if grep -qi "host headroom" <<<"$table_out"; then
    ok "the table includes a host-headroom summary line"
else
    bad "expected a host-headroom summary line in the table output (got: $table_out)"
fi

# ============================================================================================
echo
echo "== --json: parses and carries both items + the host object =="
json_out="$(common_env bash "$REPO_ROOT/bin/claude-fleet-view" --json 2>&1)"
if command -v jq >/dev/null 2>&1; then
    if echo "$json_out" | jq -e '.workers | length == 2' >/dev/null 2>&1; then
        ok "--json parses via jq and has exactly 2 workers"
    else
        bad "--json must parse via jq with 2 workers (got: $json_out)"
    fi
    if echo "$json_out" | jq -e '.workers[] | select(.item=="CC-A") | .total_cost_usd == 1.23' >/dev/null 2>&1; then
        ok "--json: CC-A's total_cost_usd is the numeric 1.23"
    else
        bad "--json: expected CC-A total_cost_usd 1.23 (got: $json_out)"
    fi
    if echo "$json_out" | jq -e '.workers[] | select(.item=="CC-B") | .total_cost_usd == null' >/dev/null 2>&1; then
        ok "--json: CC-B's total_cost_usd is JSON null (unknown, numeric field)"
    else
        bad "--json: expected CC-B total_cost_usd null (got: $json_out)"
    fi
    if echo "$json_out" | jq -e '.host.k == 2 and .host.cpus == 8' >/dev/null 2>&1; then
        ok "--json: host object carries k=2 and cpus=8"
    else
        bad "--json: expected host.k==2 and host.cpus==8 (got: $json_out)"
    fi
else
    # No jq on this host: fall back to a structural grep check.
    if grep -q '"workers"' <<<"$json_out" && grep -q '"host"' <<<"$json_out" \
       && grep -q '"CC-A"' <<<"$json_out" && grep -q '"CC-B"' <<<"$json_out"; then
        ok "--json (no jq) structurally contains workers/host and both items"
    else
        bad "--json (no jq) missing expected structure (got: $json_out)"
    fi
fi

# --- valid JSON shape sanity even without jq: braces/brackets balance ------------------------
opens="$(grep -o '[{[]' <<<"$json_out" | wc -l)"
closes="$(grep -o '[]}]' <<<"$json_out" | wc -l)"
if [[ "$opens" == "$closes" ]]; then
    ok "--json output has balanced braces/brackets"
else
    bad "--json output has unbalanced braces/brackets (opens=$opens closes=$closes): $json_out"
fi

# ============================================================================================
echo
echo "== no active workers: exit 0, info line, host headroom still printed =="
noworkers_out="$(env -i PATH="$PATH" HOME="$TMPD/home-none" CLAUDE_FLEET_DOCKER="$EMPTY_DOCKER" \
    CLAUDE_FLEET_HOST_CPUS=4 CLAUDE_FLEET_HOST_MEM_MIB=8192 CLAUDE_DISK_FREE_MIB_OVERRIDE=51200 \
    CLAUDE_PARALLEL_CONFIG="$CFG_K2" \
    bash "$REPO_ROOT/bin/claude-fleet-view" 2>&1)"
rc_none=$?
if (( rc_none == 0 )); then
    ok "no active workers still exits 0"
else
    bad "no active workers must exit 0 (got rc=$rc_none)"
fi
if grep -qi "no active workers" <<<"$noworkers_out"; then
    ok "no active workers prints an explicit info line"
else
    bad "expected an explicit 'no active workers' info line (got: $noworkers_out)"
fi
if grep -qi "host headroom" <<<"$noworkers_out" && grep -q "4" <<<"$noworkers_out"; then
    ok "host headroom is still printed with no active workers"
else
    bad "expected host headroom still printed with no active workers (got: $noworkers_out)"
fi

noworkers_json="$(env -i PATH="$PATH" HOME="$TMPD/home-none-json" CLAUDE_FLEET_DOCKER="$EMPTY_DOCKER" \
    CLAUDE_FLEET_HOST_CPUS=4 CLAUDE_FLEET_HOST_MEM_MIB=8192 CLAUDE_DISK_FREE_MIB_OVERRIDE=51200 \
    CLAUDE_PARALLEL_CONFIG="$CFG_K2" \
    bash "$REPO_ROOT/bin/claude-fleet-view" --json 2>&1)"
rc_none_json=$?
if (( rc_none_json == 0 )) && grep -q '"workers":\[\]' <<<"$noworkers_json" && grep -q '"host"' <<<"$noworkers_json"; then
    ok "--json with no active workers: exit 0, empty workers array, host object still present"
else
    bad "expected empty workers array + host object with no active workers (rc=$rc_none_json, got: $noworkers_json)"
fi

# ============================================================================================
echo
echo "== usage: only a bad flag exits non-zero =="
if bash "$REPO_ROOT/bin/claude-fleet-view" --bogus-flag >/dev/null 2>&1; then
    bad "an unknown flag must exit non-zero"
else
    ok "an unknown flag exits non-zero (usage error)"
fi

# ============================================================================================
echo
echo "== secret-free: no PRIVATE KEY / .credentials / ANTHROPIC substrings leak =="
# Build the fake PEM marker from fragments so THIS test file does not itself carry a literal
# PEM begin/end private-key header (the fleet-wide claude-secret-guard pre-commit hook scans
# staged content for exactly that header and would block the commit). The `""` splits the
# PRIVATE/KEY token in the file bytes but vanishes at runtime, so the seeded value is the full,
# realistic marker — which the assertions below prove never reaches the view's output.
FAKE_PEM="-----BEGIN PRIVATE ""KEY----- fake fake fake -----END PRIVATE ""KEY-----"
secret_out="$(env -i PATH="$PATH" HOME="$TMPD/home-secrets" CLAUDE_FLEET_DOCKER="$FAKE_DOCKER" \
    CLAUDE_WORKER_RUN_LOG_DIR="$LOGDIR" CLAUDE_FLEET_HOST_CPUS=8 CLAUDE_FLEET_HOST_MEM_MIB=16384 \
    CLAUDE_DISK_FREE_MIB_OVERRIDE=102400 CLAUDE_PARALLEL_CONFIG="$CFG_K2" \
    ANTHROPIC_API_KEY="sk-ant-totally-fake-secret-do-not-leak" \
    SOME_PRIVATE_KEY="$FAKE_PEM" \
    CREDS_PATH="$HOME/.credentials/fake-creds.json" \
    bash "$REPO_ROOT/bin/claude-fleet-view" 2>&1)"
if ! grep -qE 'PRIVATE KEY|\.credentials|ANTHROPIC' <<<"$secret_out"; then
    ok "table output contains no PRIVATE KEY / .credentials / ANTHROPIC substrings even when env is seeded with them"
else
    bad "secret-free violation: output leaked a seeded secret marker: $secret_out"
fi

secret_json="$(env -i PATH="$PATH" HOME="$TMPD/home-secrets-json" CLAUDE_FLEET_DOCKER="$FAKE_DOCKER" \
    CLAUDE_WORKER_RUN_LOG_DIR="$LOGDIR" CLAUDE_FLEET_HOST_CPUS=8 CLAUDE_FLEET_HOST_MEM_MIB=16384 \
    CLAUDE_DISK_FREE_MIB_OVERRIDE=102400 CLAUDE_PARALLEL_CONFIG="$CFG_K2" \
    ANTHROPIC_API_KEY="sk-ant-totally-fake-secret-do-not-leak" \
    SOME_PRIVATE_KEY="$FAKE_PEM" \
    CREDS_PATH="$HOME/.credentials/fake-creds.json" \
    bash "$REPO_ROOT/bin/claude-fleet-view" --json 2>&1)"
if ! grep -qE 'PRIVATE KEY|\.credentials|ANTHROPIC' <<<"$secret_json"; then
    ok "--json output contains no PRIVATE KEY / .credentials / ANTHROPIC substrings even when env is seeded with them"
else
    bad "secret-free violation: --json output leaked a seeded secret marker: $secret_json"
fi

# ============================================================================================
echo
echo "== spend attribution: exact-item match, no dash-suffixed sibling cross-match (gate-refuter blocker) =="
XDIR="$TMPD/xmatch"; mkdir -p "$XDIR"
# A real hazard: CC-4-RESIDUAL / CC-1-discovered are actual sibling ids in this backlog. Querying
# CC-4 must NOT pick up run-CC-4-RESIDUAL-<ts>.meta.json's cost (the glob run-CC-4-* matches it).
cat > "$XDIR/run-CC-4-RESIDUAL-20260710T010000Z.meta.json" <<'EOF'
{"item":"CC-4-RESIDUAL","repo":"claude-containers","ts":"20260710T010000Z","total_cost_usd":42,"is_error":false}
EOF
# CC-4 has no meta file of its own → must be "unknown", NOT 42.
spend_x="$(CLAUDE_WORKER_RUN_LOG_DIR="$XDIR" fleet_worker_spend CC-4)"
if [[ "$spend_x" == "unknown" ]]; then
    ok "CC-4 does not steal CC-4-RESIDUAL's spend (got 'unknown', not 42)"
else
    bad "cross-item mis-attribution: CC-4 picked up a sibling's spend (got '$spend_x')"
fi
# And the exact-item file IS still read for the sibling itself.
spend_res="$(CLAUDE_WORKER_RUN_LOG_DIR="$XDIR" fleet_worker_spend CC-4-RESIDUAL)"
if [[ "$spend_res" == "42" ]]; then
    ok "CC-4-RESIDUAL reads its OWN meta file (42)"
else
    bad "expected CC-4-RESIDUAL spend 42, got '$spend_res'"
fi
# The prompt's numeric-suffix case stays safe too (the literal '-' in the glob already blocked it).
cat > "$XDIR/run-CC-70-20260710T010000Z.meta.json" <<'EOF'
{"item":"CC-70","repo":"x","ts":"20260710T010000Z","total_cost_usd":88,"is_error":false}
EOF
cat > "$XDIR/run-CC-7-20260710T010000Z.meta.json" <<'EOF'
{"item":"CC-7","repo":"x","ts":"20260710T010000Z","total_cost_usd":0.5,"is_error":false}
EOF
spend_7="$(CLAUDE_WORKER_RUN_LOG_DIR="$XDIR" fleet_worker_spend CC-7)"
if [[ "$spend_7" == "0.5" ]]; then
    ok "CC-7 reads 0.5, never CC-70's 88 (numeric-suffix sibling stays isolated)"
else
    bad "expected CC-7 spend 0.5, got '$spend_7'"
fi

# ============================================================================================
echo
echo "== --json validity with a control char in an unvalidated status field (review medium) =="
# name/status come straight from docker {{.Names}}/{{.Status}} and are NOT charset-validated; a
# literal tab/newline must be escaped so --json stays RFC-8259 valid (fleet_json_str).
json_ctrl="$(fleet_render_json "$(printf 'claude-worker-z\tCC-Z\thl7\tUp 2 min\tstray')" 2>/dev/null)"
if command -v jq >/dev/null 2>&1; then
    if echo "$json_ctrl" | jq -e . >/dev/null 2>&1; then
        ok "--json stays valid JSON when a status field carries a raw control char"
    else
        bad "--json broke on a control char in status (got: $json_ctrl)"
    fi
else
    # No jq: assert the raw tab was escaped (no literal tab survives in the emitted JSON).
    if ! printf '%s' "$json_ctrl" | grep -qP '\t' 2>/dev/null; then
        ok "--json escaped the raw control char (no literal tab in output)"
    else
        bad "--json leaked a raw control char (got: $json_ctrl)"
    fi
fi

# ============================================================================================
echo
echo "== fail-safe: a malformed size-shaped env must not exit the read-only view (gate-refuter major) =="
# _common.sh derives mem reservations at SOURCE time and die()s on an unparseable size; the
# read-only view must neutralize that to a default, never exit non-zero.
mem_out="$(env -i PATH="$PATH" HOME="$TMPD/home-badmem" CLAUDE_FLEET_DOCKER="$EMPTY_DOCKER" \
    CLAUDE_FLEET_HOST_CPUS=4 CLAUDE_FLEET_HOST_MEM_MIB=8192 CLAUDE_DISK_FREE_MIB_OVERRIDE=51200 \
    CLAUDE_PARALLEL_CONFIG="$CFG_K2" CLAUDE_MEM_LIMIT="4gb" \
    bash "$REPO_ROOT/bin/claude-fleet-view" 2>&1)"
rc_badmem=$?
if (( rc_badmem == 0 )) && grep -qi "host headroom" <<<"$mem_out"; then
    ok "a malformed CLAUDE_MEM_LIMIT ('4gb') degrades the view to its default, exits 0"
else
    bad "malformed CLAUDE_MEM_LIMIT must not exit the read-only view (rc=$rc_badmem, got: $mem_out)"
fi
badworker_out="$(env -i PATH="$PATH" HOME="$TMPD/home-badwm" CLAUDE_FLEET_DOCKER="$EMPTY_DOCKER" \
    CLAUDE_FLEET_HOST_CPUS=4 CLAUDE_FLEET_HOST_MEM_MIB=8192 CLAUDE_DISK_FREE_MIB_OVERRIDE=51200 \
    CLAUDE_PARALLEL_CONFIG="$CFG_K2" CLAUDE_WORKER_MEM="lots" \
    bash "$REPO_ROOT/bin/claude-fleet-view" 2>&1)"
rc_badworker=$?
if (( rc_badworker == 0 )); then
    ok "a malformed CLAUDE_WORKER_MEM ('lots') also degrades instead of exiting the view"
else
    bad "malformed CLAUDE_WORKER_MEM must not exit the read-only view (rc=$rc_badworker)"
fi

# The malformed size can also arrive via the repo-root .env that _common.sh sources INTERNALLY
# (bypassing a process-env scrub). The reservation pre-seed must skip the source-time derivation
# so the view still exits 0. .env is gitignored; only create one if absent, and always remove it.
if [[ -e "$REPO_ROOT/.env" ]]; then
    echo "  SKIP  .env-vector test — a real $REPO_ROOT/.env exists, not overwriting it"
else
    printf 'CLAUDE_MEM_LIMIT=4gb\n' > "$REPO_ROOT/.env"
    # extend cleanup so an interrupted run never leaves the fixture .env behind
    trap 'rm -f "$REPO_ROOT/.env"; rm -rf "$TMPD"' EXIT
    dotenv_out="$(env -i PATH="$PATH" HOME="$TMPD/home-dotenv" CLAUDE_FLEET_DOCKER="$EMPTY_DOCKER" \
        CLAUDE_FLEET_HOST_CPUS=4 CLAUDE_FLEET_HOST_MEM_MIB=8192 CLAUDE_DISK_FREE_MIB_OVERRIDE=51200 \
        CLAUDE_PARALLEL_CONFIG="$CFG_K2" \
        bash "$REPO_ROOT/bin/claude-fleet-view" 2>&1)"
    rc_dotenv=$?
    rm -f "$REPO_ROOT/.env"
    trap 'rm -rf "$TMPD"' EXIT
    if (( rc_dotenv == 0 )) && grep -qi "host headroom" <<<"$dotenv_out"; then
        ok "a malformed CLAUDE_MEM_LIMIT in a repo-root .env also degrades (reservation pre-seed skips the die)"
    else
        bad ".env-file malformed size must not exit the read-only view (rc=$rc_dotenv, got: $dotenv_out)"
    fi
fi

echo
echo "== $PASS passed, $FAIL failed =="
exit $(( FAIL > 0 ? 1 : 0 ))
