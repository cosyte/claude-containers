#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables set in subshells are read by the entrypoint block run with eval
# Unit tests for --kvm: NO docker daemon, NO KVM, NO root.
#
#   - claude-compose-gen --kvm: a KVM service gets /dev/kvm and CLAUDE_KVM=1 and nothing else
#     (no group_add); other services and a stack without --kvm are untouched; one devices:
#     list with --gpu and --containers; an unknown repo and a CLAUDE_KVM --env are refused;
#     the scenario and list forms; the host warning when there is no /dev/kvm
#   - entrypoint.sh §2e: the agent joins the device's group (an existing one, a new kvm, or
#     claude-kvm), never root's; a missing or unusable device degrades and never stops the
#     boot; off, it does nothing
#   - the docs: the flag, the variables and the section are documented
# shellcheck source=test/lib/prelude.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/prelude.sh"
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/lib/entrypoint.sh
source "$REPO_ROOT/test/lib/entrypoint.sh"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

GEN="$REPO_ROOT/bin/claude-compose-gen"

# A docker stub: the generator's read-only questions all answer "fine".
STUBD="$TMPD/stub"; mkdir -p "$STUBD"
printf '#!/bin/sh\nexit 0\n' > "$STUBD/docker"; chmod +x "$STUBD/docker"

# gen <args...>: the generator's output (stdout and stderr), its exit status as its own.
# The device check sees /dev/null (a character device) unless the caller sets CLAUDE_KVM_DEV.
gen() {
    PATH="$STUBD:$PATH" CLAUDE_PORTS_USED_OVERRIDE="" CLAUDE_KVM_DEV="${CLAUDE_KVM_DEV:-/dev/null}" \
        "$GEN" "$@" 2>&1
}

svc_block() {  # svc_block <file> <service>: that service's YAML only
    awk -v s="  $2:" 'index($0,s)==1{f=1;next} f && /^  [a-z0-9-]+:$/{exit} f{print}' "$1"
}

# ======================================================================================
echo "== claude-compose-gen --kvm =="

test_kvm_flag_emits_device_and_env_for_named_service_only() {
    local out="$TMPD/t1.yml" log k1 plain
    log="$(gen --out "$out" --kvm k1 z/k1 z/plain)" || { bad "t1: the generator failed: $log"; return; }
    k1="$(svc_block "$out" k1)"; plain="$(svc_block "$out" plain)"
    grep -A1 -xF '    devices:' <<<"$k1" | grep -qxF '      - /dev/kvm' \
        && grep -qxF '      CLAUDE_KVM: "1"' <<<"$k1" \
        && ok "test_kvm_flag_emits_device_and_env_for_named_service_only: k1 gets devices: - /dev/kvm and CLAUDE_KVM" \
        || bad "test_kvm_flag_emits_device_and_env_for_named_service_only: k1 lacks /dev/kvm or CLAUDE_KVM: $k1"
    [[ -n "$plain" && "$plain" != *"/dev/kvm"* && "$plain" != *CLAUDE_KVM* ]] \
        && ok "test_kvm_flag_emits_device_and_env_for_named_service_only: plain gets neither" \
        || bad "test_kvm_flag_emits_device_and_env_for_named_service_only: plain must not get /dev/kvm or CLAUDE_KVM"
    ! grep -q 'group_add' "$out" \
        && ok "test_kvm_flag_emits_device_and_env_for_named_service_only: no group_add" \
        || bad "test_kvm_flag_emits_device_and_env_for_named_service_only: the compose must not hold group_add"
    grep -q 'claude-k1 .* +kvm' <<<"$log" && ! grep -q 'claude-plain .* +kvm' <<<"$log" \
        && ok "test_kvm_flag_emits_device_and_env_for_named_service_only: the summary marks k1 +kvm" \
        || bad "test_kvm_flag_emits_device_and_env_for_named_service_only: the summary must mark only k1 +kvm: $log"
}

test_kvm_flag_changes_only_its_own_lines() {
    local out="$TMPD/t2/dc.yml" added removed want
    mkdir -p "$TMPD/t2"
    gen --out "$out" z/k1 z/plain >/dev/null || { bad "test_kvm_flag_changes_only_its_own_lines: plain run failed"; return; }
    cp "$out" "$TMPD/t2/without.yml"
    gen --out "$out" --kvm k1 z/k1 z/plain >/dev/null || { bad "test_kvm_flag_changes_only_its_own_lines: --kvm run failed"; return; }
    cp "$out" "$TMPD/t2/with.yml"
    added="$(diff "$TMPD/t2/without.yml" "$TMPD/t2/with.yml" | sed -n 's/^> //p')"
    removed="$(diff "$TMPD/t2/without.yml" "$TMPD/t2/with.yml" | grep -c '^< ')"
    want=$'    devices:\n      - /dev/kvm\n      CLAUDE_KVM: "1"'
    [[ "$added" == "$want" && "$removed" == 0 ]] \
        && ok "test_kvm_flag_changes_only_its_own_lines: --kvm adds only its three lines" \
        || bad "test_kvm_flag_changes_only_its_own_lines: diff is not just the three lines: $(diff "$TMPD/t2/without.yml" "$TMPD/t2/with.yml")"
    # The three lines are k1's.
    [[ "$(svc_block "$TMPD/t2/with.yml" plain)" == "$(svc_block "$TMPD/t2/without.yml" plain)" ]] \
        && ok "test_kvm_flag_changes_only_its_own_lines: plain's block is unchanged" \
        || bad "test_kvm_flag_changes_only_its_own_lines: plain's block changed"
    gen --out "$out" z/k1 z/plain >/dev/null
    cmp -s "$out" "$TMPD/t2/without.yml" \
        && ok "test_kvm_flag_changes_only_its_own_lines: regenerating without --kvm is byte-identical" \
        || bad "test_kvm_flag_changes_only_its_own_lines: regenerating without --kvm differs"
}

test_kvm_with_gpu_and_containers_shares_one_devices_list() {
    local out="$TMPD/t3.yml" log g1 devs
    log="$(gen --out "$out" --gpu g1 --containers g1 --kvm g1 z/g1)" \
        || { bad "test_kvm_with_gpu_and_containers_shares_one_devices_list: the generator failed: $log"; return; }
    g1="$(svc_block "$out" g1)"
    devs="$(awk '/^    devices:$/{f=1;next} f&&/^      - /{print;next} f{exit}' <<<"$g1")"
    [[ "$(grep -cxF '    devices:' <<<"$g1")" == 1 \
        && "$devs" == $'      - nvidia.com/gpu=all\n      - /dev/net/tun\n      - /dev/kvm' ]] \
        && ok "test_kvm_with_gpu_and_containers_shares_one_devices_list: one devices: with gpu, tun, kvm in order" \
        || bad "test_kvm_with_gpu_and_containers_shares_one_devices_list: devices wrong: $devs"
}

test_kvm_unknown_repo_is_refused() {
    local log rc
    log="$(gen --out "$TMPD/t4.yml" --kvm nope z/k1)"; rc=$?
    (( rc != 0 )) && [[ "$log" == *"--kvm names 'nope', which is not a repo in this stack"* ]] \
        && ok "test_kvm_unknown_repo_is_refused" \
        || bad "test_kvm_unknown_repo_is_refused: rc=$rc: $log"
}

test_kvm_from_scenario_conf_and_list_forms() {
    local out="$TMPD/t5/dc.yml" conf="$TMPD/t5.conf" log
    mkdir -p "$TMPD/t5"
    printf -- '--out %s\n--kvm k1,k2\nz/k1\nz/k2\nz/k3\n' "$out" > "$conf"
    log="$(gen --scenario "$conf")" || { bad "test_kvm_from_scenario_conf_and_list_forms: the generator failed: $log"; return; }
    [[ "$(svc_block "$out" k1)" == *"- /dev/kvm"* && "$(svc_block "$out" k2)" == *"- /dev/kvm"* \
        && "$(svc_block "$out" k3)" != *"/dev/kvm"* ]] \
        && ok "test_kvm_from_scenario_conf_and_list_forms: k1 and k2 get /dev/kvm, k3 does not" \
        || bad "test_kvm_from_scenario_conf_and_list_forms: wrong services got /dev/kvm"
    # The space-separated form on the command line.
    gen --out "$TMPD/t5/sp.yml" --kvm "k1 k3" z/k1 z/k2 z/k3 >/dev/null
    [[ "$(svc_block "$TMPD/t5/sp.yml" k3)" == *"- /dev/kvm"* && "$(svc_block "$TMPD/t5/sp.yml" k2)" != *"/dev/kvm"* ]] \
        && ok "test_kvm_from_scenario_conf_and_list_forms: a space list works too" \
        || bad "test_kvm_from_scenario_conf_and_list_forms: --kvm 'k1 k3' must give k1 and k3 /dev/kvm"
}

test_kvm_env_override_is_refused() {
    local log rc
    log="$(gen --out "$TMPD/t6.yml" --kvm k1 --env k1=CLAUDE_KVM=0 z/k1)"; rc=$?
    (( rc != 0 )) && [[ "$log" == *"the generator already sets it"* ]] \
        && ok "test_kvm_env_override_is_refused" \
        || bad "test_kvm_env_override_is_refused: rc=$rc: $log"
}

test_kvm_host_warning_without_device() {
    local log rc
    log="$(CLAUDE_KVM_DEV="$TMPD/no-such-kvm" gen --out "$TMPD/t7.yml" --kvm k1 z/k1)"; rc=$?
    (( rc == 0 )) && [[ "$log" == *"this host has no /dev/kvm"* ]] \
        && ok "test_kvm_host_warning_without_device: a missing device warns, exit 0" \
        || bad "test_kvm_host_warning_without_device: rc=$rc: $log"
    grep -qxF '      - /dev/kvm' "$TMPD/t7.yml" \
        && ok "test_kvm_host_warning_without_device: the service still gets /dev/kvm, not the seam's path" \
        || bad "test_kvm_host_warning_without_device: the emitted device must be /dev/kvm"
    log="$(CLAUDE_KVM_DEV=/dev/null gen --out "$TMPD/t7.yml" --kvm k1 z/k1)"
    [[ "$log" != *"this host has no /dev/kvm"* ]] \
        && ok "test_kvm_host_warning_without_device: a character device does not warn" \
        || bad "test_kvm_host_warning_without_device: /dev/null must not warn: $log"
}

test_kvm_flag_emits_device_and_env_for_named_service_only
test_kvm_flag_changes_only_its_own_lines
test_kvm_with_gpu_and_containers_shares_one_devices_list
test_kvm_unknown_repo_is_refused
test_kvm_from_scenario_conf_and_list_forms
test_kvm_env_override_is_refused
test_kvm_host_warning_without_device

# ======================================================================================
echo "== entrypoint.sh §2e: the agent joins the device's group, never stops the boot =="
BLOCK="$(awk '/^# --- 2e\. KVM /{f=1} f{print} f&&/^fi$/{exit}' "$(ep_section 2e)")"
REC="$TMPD/rec"

# run_2e <kvm-dev> <stat-gid> <getent-gid-line> <getent-kvm-line> <asclaude-exit> [CLAUDE_KVM]
# Runs the real block under `set -euo pipefail` with every command it names stubbed; each stub
# appends its call to $REC. Prints the log, then AFTER once the boot goes on past the section.
run_2e() {
    : > "$REC"
    local blk; blk="$(sed -e "s#^KVM_DEV=.*#KVM_DEV=\"$1\"#" <<<"$BLOCK")"
    ( S_GID="$2" S_GRP="$3" S_KVM="$4" S_AS="$5"
      CLAUDE_USER=claude CLAUDE_GID=1000
      if [[ -n "${6-}" ]]; then CLAUDE_KVM="$6"; else unset CLAUDE_KVM; fi
      stat()     { echo "stat $*" >> "$REC"; echo "$S_GID"; }
      getent()   { echo "getent $*" >> "$REC"
                   case "$2" in kvm) line="$S_KVM" ;; *) line="$S_GRP" ;; esac
                   [[ -n "$line" ]] || return 2; echo "$line"; }
      groupadd() { echo "groupadd $*" >> "$REC"; }
      usermod()  { echo "usermod $*" >> "$REC"; }
      asclaude() { echo "asclaude $*" >> "$REC"; return "$S_AS"; }
      log()      { echo "log $*" >> "$REC"; echo "[entrypoint] $*"; }
      set -euo pipefail; eval "$blk"; echo AFTER ) 2>&1
}

test_entrypoint_kvm_adds_agent_to_device_group() {
    local out rc
    out="$(run_2e /dev/null 993 "" "" 0 1)"; rc=$?
    (( rc == 0 )) && grep -qxF 'groupadd -g 993 kvm' "$REC" && grep -qxF 'usermod -aG kvm claude' "$REC" \
        && [[ "$out" == *KVM*ok*"group kvm"* ]] \
        && ok "test_entrypoint_kvm_adds_agent_to_device_group" \
        || bad "test_entrypoint_kvm_adds_agent_to_device_group: rc=$rc: $out / $(cat "$REC")"
}

test_entrypoint_kvm_reuses_existing_group_or_falls_back_name() {
    local out
    out="$(run_2e /dev/null 993 "render:x:993:" "" 0 1)"
    ! grep -q '^groupadd' "$REC" && grep -qxF 'usermod -aG render claude' "$REC" \
        && ok "test_entrypoint_kvm_reuses_existing_group_or_falls_back_name: an existing group is reused" \
        || bad "test_entrypoint_kvm_reuses_existing_group_or_falls_back_name: render: $out / $(cat "$REC")"
    out="$(run_2e /dev/null 993 "" "kvm:x:994:" 0 1)"
    grep -qxF 'groupadd -g 993 claude-kvm' "$REC" && grep -qxF 'usermod -aG claude-kvm claude' "$REC" \
        && ok "test_entrypoint_kvm_reuses_existing_group_or_falls_back_name: a taken kvm name falls back to claude-kvm" \
        || bad "test_entrypoint_kvm_reuses_existing_group_or_falls_back_name: claude-kvm: $out / $(cat "$REC")"
}

test_entrypoint_kvm_never_adds_root_group() {
    local out
    out="$(run_2e /dev/null 0 "root:x:0:" "" 0 1)"
    ! grep -qE '^(groupadd|usermod)' "$REC" && [[ "$out" == *"group 0"* ]] \
        && ok "test_entrypoint_kvm_never_adds_root_group" \
        || bad "test_entrypoint_kvm_never_adds_root_group: $out / $(cat "$REC")"
}

test_entrypoint_kvm_missing_or_unusable_degrades_and_boot_continues() {
    local out rc
    out="$(run_2e "$TMPD/no-such-kvm" 993 "" "" 0 1)"; rc=$?
    (( rc == 0 )) && [[ "$out" == *"KVM MISSING"* && "$out" == *AFTER ]] \
        && ok "test_entrypoint_kvm_missing_or_unusable_degrades_and_boot_continues: a missing device logs KVM MISSING, boot goes on" \
        || bad "test_entrypoint_kvm_missing_or_unusable_degrades_and_boot_continues: missing rc=$rc: $out"
    out="$(run_2e /dev/null 993 "" "" 1 1)"; rc=$?
    (( rc == 0 )) && [[ "$out" == *"KVM UNUSABLE"* && "$out" == *AFTER ]] \
        && ok "test_entrypoint_kvm_missing_or_unusable_degrades_and_boot_continues: an unusable device logs KVM UNUSABLE, boot goes on" \
        || bad "test_entrypoint_kvm_missing_or_unusable_degrades_and_boot_continues: unusable rc=$rc: $out"
}

test_entrypoint_kvm_off_does_nothing() {
    local out rc
    out="$(run_2e /dev/null 993 "" "" 0)"; rc=$?
    (( rc == 0 )) && [[ "$out" == AFTER && ! -s "$REC" ]] \
        && ok "test_entrypoint_kvm_off_does_nothing" \
        || bad "test_entrypoint_kvm_off_does_nothing: rc=$rc: $out / $(cat "$REC")"
}

if [[ -z "$BLOCK" ]]; then
    bad "could not extract §2e from $(ep_section 2e)"
else
    grep -q '^KVM_DEV=/dev/kvm$' <<<"$BLOCK" \
        && ok "§2e names KVM_DEV=/dev/kvm on its own line (so this sandbox redirect is real)" \
        || bad "§2e must assign KVM_DEV=/dev/kvm on its own line"
    test_entrypoint_kvm_adds_agent_to_device_group
    test_entrypoint_kvm_reuses_existing_group_or_falls_back_name
    test_entrypoint_kvm_never_adds_root_group
    test_entrypoint_kvm_missing_or_unusable_degrades_and_boot_continues
    test_entrypoint_kvm_off_does_nothing
fi

# ======================================================================================
echo "== docs =="

test_kvm_documented() {
    local out
    grep -q -- '--kvm REPOS' "$REPO_ROOT/docs/launcher-commands.md" \
        && grep -qF '| `02e-kvm.sh` | §2e: ' "$REPO_ROOT/docs/architecture.md" \
        && grep -q '^| `CLAUDE_KVM` |' "$REPO_ROOT/docs/environment-variables.md" \
        && grep -qw CLAUDE_KVM "$REPO_ROOT/test/docs-unit.sh" && grep -qw CLAUDE_KVM_DEV "$REPO_ROOT/test/docs-unit.sh" \
        && ok "test_kvm_documented: the flag, the variables and §2e are in the docs" \
        || bad "test_kvm_documented: --kvm, CLAUDE_KVM, CLAUDE_KVM_DEV or 02e-kvm.sh is undocumented"
    out="$(bash "$REPO_ROOT/test/docs-unit.sh" 2>&1)" \
        && ok "test_kvm_documented: test/docs-unit.sh passes" \
        || bad "test_kvm_documented: test/docs-unit.sh fails: $(grep FAIL <<<"$out")"
    out="$(bash "$REPO_ROOT/test/entrypoint-unit.sh" 2>&1)" \
        && ok "test_kvm_documented: test/entrypoint-unit.sh passes" \
        || bad "test_kvm_documented: test/entrypoint-unit.sh fails: $(grep FAIL <<<"$out")"
}
test_kvm_documented

echo
echo "kvm-unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
