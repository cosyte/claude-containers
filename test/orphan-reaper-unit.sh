#!/usr/bin/env bash
# Unit tests for bin/claude-orphan-reaper: NO docker, NO root. A fake `ps` listing stands in for
# the container's processes and a fake `kill` records the signals.
#   - ended: the agent's PID-1 child older than the age, also when it runs under an interpreter
#   - spared: younger than the age, a live parent, another owner, a kept name (tmux, claude,
#     claude.exe, claude-session under bash, sshd:, the Gradle daemon by its main class, podman's
#     aardvark-dns and netavark), a VS Code server by its install path, the kit start command's
#     session; a kept name or a ~/.vscode-server path as an argument is not kept;
#     CLAUDE_ORPHAN_KEEP adds names, and a bad one is ignored
#   - SIGKILL follows only for a pid that still matches after the grace
#   - with no init (PID 1 the entrypoint) nothing is ended
#   - CLAUDE_ORPHAN_MAX_AGE: 0 is off, N[smhd] parses, a bad value falls back to 2h
#   - the entrypoint starts it and stops it, the image ships it, the docs name its variables
#   - every session container runs an init (claude-launch, claude-compose-gen, smoke), and
#     §12e clears the last boot's kit-start.pid even with no start command
# shellcheck source=test/lib/prelude.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/prelude.sh"
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAP="$REPO_ROOT/bin/claude-orphan-reaper"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

# The listing: pid ppid uid sid etimes args. The agent is uid 1000; the age 2h is 7200 s.
cat > "$TMPD/ps.txt" <<'EOF'
    1     0     0     1 40000 /sbin/docker-init -- /usr/local/bin/entrypoint.sh
   10     1     0     1 40000 bash /usr/local/bin/entrypoint.sh
  101     1  1000   101 39000 bfs / -name foo
  102     1  1000   102 36000 /bin/sh -c find / -type f
  103     1  1000   103  3600 find /cache -name young
  104    10  1000     1 39000 find / -name parent-alive
  105     1     0   105 39000 find / -name root-owned
  106     1  1000   106 39000 tmux new-session -d -s claude
  107     1  1000   107 39000 claude --resume abc
  108     1  1000   108 39000 bash /usr/local/bin/claude-session main
  109     1  1000   109 39000 sshd: claude@pts/0
  110     1  1000   777 39000 node kit-supervisor.js
  111     1  1000   111 39000 python3 /workspace/x/esphome-sim.py
  112     1  1000   112 39000 /opt/chrome/chrome_crashpad_handler --database=/x
  113     1  1000   113  7201 tmuxinator-lookalike run
  114     1  1000   114 39000 /opt/java/bin/java -Xmx512m -cp /g/gradle-launcher.jar org.gradle.launcher.daemon.bootstrap.GradleDaemon 8.10
  116     1  1000   116 39000 find /home/claude -name tmux
  117     1  1000   117 39000 bash -c find / -name claude
  115     1  1000   115 39000 /opt/java/bin/java -cp /k/kotlin-daemon.jar org.jetbrains.kotlin.daemon.KotlinCompileDaemon --daemon-runFilesPath /k
  118     1  1000   118 39000 /usr/lib/podman/aardvark-dns --config /run/user/1000/containers/networks/aardvark-dns -p 53 run
  119     1  1000   119 39000 /usr/lib/podman/netavark dhcp-proxy --activity-timeout 0
  120     1  1000   120 39000 /opt/claude-code/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe --bg
  121     1  1000   121 39000 sh /home/claude/.vscode-server/bin/0123abc/bin/code-server --start-server --host=127.0.0.1
  122     1  1000   122 39000 /home/claude/.vscode-server/bin/0123abc/node --inspect=0 /home/claude/.vscode-server/bin/0123abc/out/server-main.js
  123     1  1000   123 39000 /home/claude/.vscode-server/code-0123abc command-shell --cli-data-dir /home/claude/.vscode-server/cli
  124     1  1000   124 39000 node /workspace/app/server.js /home/claude/.vscode-server/data
  125     1  1000   125 39000 find /home/claude/.vscode-server -name x
EOF
printf '#!/bin/sh\ncat "%s"\n' "$TMPD/ps.txt" > "$TMPD/ps"
printf '#!/bin/sh\necho "$1 $2" >> "%s"\n' "$TMPD/kills" > "$TMPD/kill"
chmod +x "$TMPD/ps" "$TMPD/kill"
mkdir -p "$TMPD/config"; echo 777 > "$TMPD/config/kit-start.pid"

run() {  # run <args...>, with the fakes, as uid 1000
    env CLAUDE_ORPHAN_PS="$TMPD/ps" CLAUDE_ORPHAN_KILL="$TMPD/kill" CLAUDE_ORPHAN_UID=1000 \
        CLAUDE_ORPHAN_GRACE=0 CLAUDE_CONFIG_DIR="$TMPD/config" "$@"
}
pids() { awk '{print $1}' | sort -n | tr '\n' ' '; }

echo "== selection =="
got="$(run "$REAP" --list | pids)"
want="101 102 111 113 116 117 124 125 "
[[ "$got" == "$want" ]] && ok "ends old PID-1 orphans of the agent only ($want)" \
    || bad "selection: got '$got', want '$want'"
for c in "116 a kept name as an argument (find /home/claude -name tmux)" "117 a kept name inside bash -c" \
         "124 a node orphan whose ARGUMENT is under ~/.vscode-server" "125 find walking ~/.vscode-server"; do
    grep -qw "${c%% *}" <<<"$got" && ok "ended: ${c#* }" || bad "not ended: ${c#* }"
done
for c in "103 younger than the age" "104 a live parent" "105 another owner" "106 tmux" "107 claude" \
         "108 claude-session under bash" "109 sshd:" "110 the kit start session" "112 chrome_crashpad_handler" \
         "114 a Gradle daemon (by its main class)" "115 a Kotlin compile daemon" \
         "118 podman's aardvark-dns (a nested compose network's DNS)" "119 netavark dhcp-proxy" \
         "120 the native Claude binary (claude.exe --bg)" "121 the VS Code server under sh" \
         "122 the VS Code server's node, by its script's path" "123 the VS Code CLI (code-<commit>)"; do
    grep -qw "${c%% *}" <<<"$got" && bad "spared: ${c#* } (pid ${c%% *})" || ok "spared: ${c#* }"
done
got="$(run env CLAUDE_ORPHAN_KEEP='^(python3|bfs)$' "$REAP" --list | pids)"
[[ "$got" == "102 113 116 117 124 125 " ]] && ok "CLAUDE_ORPHAN_KEEP adds to the kept names (python3 by command, bfs)" \
    || bad "custom keep: got '$got'"
out="$(run env CLAUDE_ORPHAN_KEEP='tmux|(claude' "$REAP" --list 2>&1)"
[[ "$out" == *"WARNING: CLAUDE_ORPHAN_KEEP"*"ignored"* && "$(grep -v WARNING <<<"$out" | pids)" == "$want" ]] \
    && ok "a bad CLAUDE_ORPHAN_KEEP is warned and ignored, tmux still kept" || bad "bad keep: $out"
rm -f "$TMPD/config/kit-start.pid"
grep -qw 110 <<<"$(run "$REAP" --list | pids)" && ok "without kit-start.pid the kit's process is not spared" \
    || bad "kit process spared with no pidfile"
echo 777 > "$TMPD/config/kit-start.pid"

# A container run without --init: PID 1 is the entrypoint, and its watchdogs have PPID 1.
sed 's|^    1     0     0     1 40000 .*|    1     0     0     1 40000 bash /usr/local/bin/entrypoint.sh|' "$TMPD/ps.txt" > "$TMPD/ps-noinit.txt"
printf '#!/bin/sh\ncat "%s"\n' "$TMPD/ps-noinit.txt" > "$TMPD/ps-noinit"; chmod +x "$TMPD/ps-noinit"
out="$(run env CLAUDE_ORPHAN_PS="$TMPD/ps-noinit" "$REAP" --list 2>&1)"
[[ "$out" == *"PID 1 is the entrypoint"* && "$(grep -v orphan-reaper <<<"$out")" == "" ]] \
    && ok "with no init (PID 1 the entrypoint) nothing is ended" || bad "no init: $out"

echo "== the age =="
got="$(run env CLAUDE_ORPHAN_MAX_AGE=30m "$REAP" --list | pids)"
grep -qw 103 <<<"$got" && ok "30m: a 1 h orphan is ended" || bad "30m: got '$got'"
got="$(run env CLAUDE_ORPHAN_MAX_AGE=7201 "$REAP" --list | pids)"
grep -qw 113 <<<"$got" && bad "7201: a 7201 s orphan is not older than the age" || ok "the age is strict: 7201 s at 7201 is spared"
out="$(run env CLAUDE_ORPHAN_MAX_AGE=soon "$REAP" --list 2>&1)"
grep -q "WARNING.*soon" <<<"$out" && [[ "$(grep -v WARNING <<<"$out" | pids)" == "$want" ]] \
    && ok "a bad age warns and uses 2h" || bad "bad age: $out"
for off in 0 0h; do
    out="$(run env CLAUDE_ORPHAN_MAX_AGE=$off "$REAP" --list; run env CLAUDE_ORPHAN_MAX_AGE=$off "$REAP" --once)"
    [[ -z "$out" && ! -e "$TMPD/kills" ]] && ok "CLAUDE_ORPHAN_MAX_AGE=$off is off" || bad "$off is not off: $out"
done
out="$(run env CLAUDE_ORPHAN_MAX_AGE=0 "$REAP")"
grep -q "off (CLAUDE_ORPHAN_MAX_AGE=0)" <<<"$out" && ok "the loop says it is off and exits" || bad "loop off: $out"

echo "== the signals =="
out="$(run "$REAP" --once)"
want="$(printf -- '-TERM %s\n' 101 102 111 113 116 117 124 125; printf -- '-KILL %s\n' 101 102 111 113 116 117 124 125)"
[[ "$(cat "$TMPD/kills")" == "$want" ]] && ok "SIGTERM each, then SIGKILL each still there" \
    || bad "signals: $(cat "$TMPD/kills")"
grep -q 'SIGTERM pid 101 (orphaned, age 10h50m): bfs / -name foo' <<<"$out" \
    && ok "each kill is logged with pid, age and command" || bad "log: $out"
# Between the passes 101 exits and its pid is reused by a young process: no SIGKILL for it.
rm -f "$TMPD/kills"
cat > "$TMPD/ps" <<EOF
#!/bin/sh
if [ -e "$TMPD/second" ]; then sed 's/^  101     1  1000   101 39000/  101     1  1000   101     5/' "$TMPD/ps.txt"
else touch "$TMPD/second"; cat "$TMPD/ps.txt"; fi
EOF
run "$REAP" --once >/dev/null
grep -q -- '-KILL 101' "$TMPD/kills" && bad "a reused pid got SIGKILL" || ok "a pid reused during the grace is not killed"
grep -q -- '-KILL 102' "$TMPD/kills" && ok "the others still get SIGKILL" || bad "no SIGKILL: $(cat "$TMPD/kills")"

echo "== wiring =="
grep -q 'asclaude /usr/local/bin/claude-orphan-reaper &' "$REPO_ROOT/entrypoint.d/12h-orphan-reaper.sh" \
    && ok "the entrypoint starts it as the agent" || bad "entrypoint §12h does not start it"
grep -q 'kill "$ORPHAN_REAPER_PID"' "$REPO_ROOT/entrypoint.d/13-stay-alive.sh" \
    && ok "shutdown stops it" || bad "shutdown does not stop it"
grep -q '^COPY bin/claude-orphan-reaper /usr/local/bin/claude-orphan-reaper$' "$REPO_ROOT/Dockerfile" \
    && ok "the image ships it" || bad "the Dockerfile does not COPY it"
# The reaper skips every pass when PID 1 is the entrypoint, so every way a session is started runs
# an init; smoke's main container too, or its reaper check proves nothing (it failed for that).
e12e="$REPO_ROOT/entrypoint.d/12e-named-sessions.sh"
grep -q -- '--init' <(sed -n '/^docker run -d \\$/,/"\$IMAGE"/p' "$REPO_ROOT/bin/claude-launch") \
    && grep -q '^    init: true$' "$REPO_ROOT/bin/claude-compose-gen" \
    && grep -qE '^docker run -d --name "\$CN" --init( |\\)' "$REPO_ROOT/test/smoke.sh" \
    && ok "claude-launch, claude-compose-gen and smoke's main container all run an init (--init)" \
    || bad "a session container is started without --init: the reaper would skip every pass in it"
# The last boot's kit-start.pid names a session the reaper spares. claude-kit start clears it, so
# the entrypoint runs it every boot, not only when a start command is set.
grep -q '^asclaude /usr/local/bin/claude-kit start \\$' "$e12e" && ! grep -q 'CLAUDE_EXTRA_START_CMD:-}" ]]' "$e12e" \
    && ok "§12e runs claude-kit start on every boot (it clears the last boot's kit-start.pid)" \
    || bad "§12e runs claude-kit start only with a start command: a dropped command leaves a stale kit-start.pid"
mkdir -p "$TMPD/kitcfg"; echo 4242 > "$TMPD/kitcfg/kit-start.pid"
env -u CLAUDE_EXTRA_START_CMD CLAUDE_CONFIG_DIR="$TMPD/kitcfg" CLAUDE_KIT_START_LOG="$TMPD/kitcfg/kit-start.log" \
    "$REPO_ROOT/bin/claude-kit" start >/dev/null 2>&1; rc=$?
(( rc == 0 )) && [[ ! -e "$TMPD/kitcfg/kit-start.pid" ]] \
    && ok "claude-kit start with no start command clears the last boot's kit-start.pid, exit 0" \
    || bad "claude-kit start with no command: rc=$rc, pidfile $( [[ -e "$TMPD/kitcfg/kit-start.pid" ]] && echo kept || echo gone)"
for v in CLAUDE_ORPHAN_MAX_AGE CLAUDE_ORPHAN_KEEP; do
    grep -q "$v" "$REPO_ROOT/docs/environment-variables.md" && grep -q "$v" "$REPO_ROOT/.env.example" \
        && ok "$v is documented" || bad "$v missing from docs/environment-variables.md or .env.example"
done

echo
echo "orphan-reaper-unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
