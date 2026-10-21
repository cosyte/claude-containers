#!/usr/bin/env bash
# Unit tests for the Gradle caps in entrypoint.sh §12 and the facts' Gradle line: NO docker, NO
# root, NO Gradle. A fake nproc stands in for the image's (the CPU quota).
#   - unset: workers.max a third of the quota, at least 2 (9 at 28, 2 at 4), idletimeout 30 min
#   - appended to the operator's GRADLE_OPTS, never over a -D of the same name there
#   - 0 or empty for either leaves Gradle's own default
#   - SSH logins get the same from /etc/profile.d, again never over their own -D
#   - claude-container-facts prints both, and the image ships the block (§12, docs)
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

for n in 28 4; do
    mkdir -p "$TMPD/n$n"; printf '#!/bin/sh\necho %s\n' "$n" > "$TMPD/n$n/nproc"; chmod +x "$TMPD/n$n/nproc"
done
PROFILE="$TMPD/gradle.sh"
GB="$(awk '/^# Gradle builds\./{f=1} f{print} f&&/^unset _gw /{exit}' "$(ep_section 12)")"
[[ -n "$GB" ]] && ok "extracted §12's Gradle block" || bad "could not extract §12's Gradle block"
gb() {  # gb <cpus> <env...>: run the block, print GRADLE_OPTS and the log
    local n="$1"; shift
    env -i PATH="$TMPD/n$n:$PATH" "$@" bash -c "set -euo pipefail; log() { echo \"[entrypoint] \$*\"; }
        $(printf '%s\n' "$GB" | sed "s#^GRADLE_PROFILE_D=.*#GRADLE_PROFILE_D=$PROFILE#")
        echo \"opts=\${GRADLE_OPTS-unset}\""
}
login() {  # login <GRADLE_OPTS|-> : what an SSH login shell (sh) gets from the profile file
    if [[ "$1" == - ]]; then env -i sh -c ". '$PROFILE'; echo \"opts=\${GRADLE_OPTS-unset}\""
    else env -i GRADLE_OPTS="$1" sh -c ". '$PROFILE'; echo \"opts=\${GRADLE_OPTS-unset}\""; fi
}

echo "== §12: the defaults =="
out="$(gb 28)"
[[ "$out" == *"opts=-Dorg.gradle.workers.max=9 -Dorg.gradle.daemon.idletimeout=1800000"* ]] \
    && ok "28-CPU quota: 9 workers, 30 min idle" || bad "28: $out"
[[ "$out" == *"Gradle              : org.gradle.workers.max=9, org.gradle.daemon.idletimeout=1800000"* ]] \
    && ok "the boot log says so" || bad "log: $out"
out="$(login -)"
[[ "$out" == "opts=-Dorg.gradle.workers.max=9 -Dorg.gradle.daemon.idletimeout=1800000" ]] \
    && ok "an SSH login gets the same" || bad "login: $out"
out="$(login "-Xmx2g -Dorg.gradle.workers.max=3")"
[[ "$out" == "opts=-Xmx2g -Dorg.gradle.workers.max=3 -Dorg.gradle.daemon.idletimeout=1800000" ]] \
    && ok "a login's own -D is kept, the other appended" || bad "login own: $out"
out="$(login "-Dorg.gradle.workers.max=9 -Dorg.gradle.daemon.idletimeout=1800000")"
[[ "$out" == "opts=-Dorg.gradle.workers.max=9 -Dorg.gradle.daemon.idletimeout=1800000" ]] \
    && ok "a second login shell adds nothing twice" || bad "login twice: $out"
out="$(gb 4)"
[[ "$out" == *"opts=-Dorg.gradle.workers.max=2 -Dorg.gradle.daemon.idletimeout=1800000"* ]] \
    && ok "4-CPU quota: at least 2 workers" || bad "4: $out"
out="$(gb 28 CLAUDE_GRADLE_WORKERS=5 CLAUDE_GRADLE_IDLE_MS=600000)"
[[ "$out" == *"opts=-Dorg.gradle.workers.max=5 -Dorg.gradle.daemon.idletimeout=600000"* ]] \
    && ok "CLAUDE_GRADLE_WORKERS and CLAUDE_GRADLE_IDLE_MS set them" || bad "set: $out"

echo "== §12: the operator's GRADLE_OPTS =="
out="$(gb 28 GRADLE_OPTS="-Xmx2g")"
[[ "$out" == *"opts=-Xmx2g -Dorg.gradle.workers.max=9 -Dorg.gradle.daemon.idletimeout=1800000"* ]] \
    && ok "appended to an operator's GRADLE_OPTS" || bad "append: $out"
out="$(gb 28 GRADLE_OPTS="-Dorg.gradle.workers.max=20")"
[[ "$out" == *"opts=-Dorg.gradle.workers.max=20 -Dorg.gradle.daemon.idletimeout=1800000"* \
    && "$out" == *"org.gradle.workers.max the operator's (GRADLE_OPTS)"* ]] \
    && ok "an explicit -Dorg.gradle.workers.max wins, and the log says whose" || bad "no override: $out"
out="$(gb 28 GRADLE_OPTS="-Dorg.gradle.daemon.idletimeout=60000")"
[[ "$out" == *"opts=-Dorg.gradle.daemon.idletimeout=60000 -Dorg.gradle.workers.max=9"* ]] \
    && ok "an explicit -Dorg.gradle.daemon.idletimeout wins" || bad "no override idle: $out"
[[ "$(login -)" == "opts=-Dorg.gradle.workers.max=9" ]] \
    && ok "the profile file holds only what §12 added" || bad "profile: $(cat "$PROFILE")"

echo "== §12: the opt-out =="
out="$(gb 28 CLAUDE_GRADLE_WORKERS=0 CLAUDE_GRADLE_IDLE_MS=)"
[[ "$out" == *"opts=unset"* && "$out" == *"org.gradle.workers.max Gradle's default, org.gradle.daemon.idletimeout Gradle's default"* ]] \
    && ok "0 and empty leave Gradle's defaults, and say so" || bad "opt-out: $out"
[[ "$(login -)" == "opts=unset" ]] && ok "and an SSH login gets nothing either" || bad "login opt-out: $(login -)"
out="$(gb 28 CLAUDE_GRADLE_WORKERS= )"
[[ "$out" == *"opts=-Dorg.gradle.daemon.idletimeout=1800000"* ]] && ok "empty workers alone: only the idle timeout" || bad "empty: $out"
out="$(gb 28 CLAUDE_GRADLE_WORKERS=lots)"
[[ "$out" == *"opts=-Dorg.gradle.daemon.idletimeout=1800000"* ]] && ok "a non-number is not passed to Gradle" || bad "garbage: $out"

echo "== the facts =="
facts() {
    env -u CLAUDE_GRADLE_WORKERS -u CLAUDE_GRADLE_IDLE_MS CLAUDE_FACTS_NPROC="$TMPD/n$1/nproc" \
        CLAUDE_FACTS_GPU_STATE="$TMPD/none" CLAUDE_FACTS_DIRS="$TMPD" CLAUDE_GPU=0 "${@:2}" \
        bash "$REPO_ROOT/bin/claude-container-facts" | grep '^- Gradle:'
}
out="$(facts 28)"
[[ "$out" == '- Gradle: builds capped at 9 workers, daemons stop after 30 min idle'* ]] \
    && ok "facts: 9 workers at 28, 30 min" || bad "facts 28: '$out'"
out="$(facts 4)"
[[ "$out" == *"capped at 2 workers"* ]] && ok "facts: 2 workers at 4" || bad "facts 4: '$out'"
out="$(facts 28 CLAUDE_GRADLE_WORKERS=0 CLAUDE_GRADLE_IDLE_MS=0)"
[[ "$out" == *"workers not capped, daemons keep Gradle's 3 h idle timeout"* ]] \
    && ok "facts: the opt-out says not capped" || bad "facts off: '$out'"

echo "== docs =="
for v in CLAUDE_GRADLE_WORKERS CLAUDE_GRADLE_IDLE_MS; do
    grep -q "$v" "$REPO_ROOT/.env.example" && grep -q "^| \`$v\`" "$REPO_ROOT/docs/environment-variables.md" \
        && ok "$v is in .env.example and docs/environment-variables.md" || bad "$v undocumented"
done
grep -q 'Gradle builds are capped at N workers' "$REPO_ROOT/claude-config/CLAUDE.md" \
    && ok "the baked CLAUDE.md tells sessions" || bad "baked CLAUDE.md line"

echo
echo "gradle-limits-unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
