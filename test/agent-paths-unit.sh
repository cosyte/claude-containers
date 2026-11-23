#!/usr/bin/env bash
# shellcheck disable=SC2034  # the sections and functions this runs through eval read the sandbox's variables
# agent-paths-unit.sh: root never acts by name in a directory the agent can write. NO docker,
# NO root.
#
# The entrypoint runs as root and works in the agent's config dir and ~/.ssh, at boot and in
# its background loops. A session can rename a symlink over any name there at any moment, so
# every root step on such a name is a window: a temp file root made and then writes, chowns or
# chmods; a file root reads after its symlink check; GNU install's own chmod by name after it
# creates the file; a name root unlinks and then creates. Through any of them root follows the
# link to a file of the session's choosing: overwritten, chmod 644, or chowned to the agent,
# which is root in the container.
#
# These run the real sections and functions against a sandbox and open each window on purpose:
# a shim in root's shell plants the agent's symlink at that exact step, as a racing session
# would, so a run is deterministic. A pass means root never followed the link:
#   - a temp file beside an agent file (mktemp, then a write, chown or chmod by its name):
#     §1b _write_active, §6 set_local_account, refresh_cached_account and write_switch_file,
#     §6a _switch_write, §7 .claude.json, §8b and §8c settings.json
#   - a read after the check (cat, jq, grep of an agent file): §6 refresh_cached_account and
#     the credential sync, §7, §8b, §8c; no root-only file reaches the agent's files
#   - GNU install's chmod by name (coreutils 9.x creates the file, then sets its mode with
#     fchmodat without AT_SYMLINK_NOFOLLOW, which follows a symlink): §6's first copy, §5's key
#     file, §8a, §8d
#   - an unlink, then a create by the same name: §5's ~/.ssh/config
#   - own_tree never hands over a file with a second hard link
#   - §0a's as_agent really drops to the agent user (a recording gosu), on the system PATH
#   - the image keeps /opt/claude-config root's; the healthcheck reads the agent's log as the
#     agent; claude-kit's settings merge runs as the agent; and nowhere in the boot path does a
#     root mktemp, install, chmod, chown, cp, ln, cat, jq, grep or redirect name an agent path
#     (a static net under the behavioural checks)
# The shims are functions in root's shell. The agent's own processes (as_agent's `sh -c`) run
# the real tools: a racing session plants links around root's steps, and what the agent itself
# opens, the kernel checks against the agent's own rights. One user here, so as_agent runs the
# command as it is; that the real one drops to the agent user is checked on its own.
# shellcheck source=test/lib/prelude.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/prelude.sh"
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=test/lib/entrypoint.sh
source "$REPO_ROOT/test/lib/entrypoint.sh"
PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

SB="$TMPDIR/sb"
AGENT_HOME="$SB/home"              # the agent's home: every name under it is the agent's to swap
CFG="$AGENT_HOME/.claude"          # its config dir
OUT="$SB/outside"                  # root's: what a planted link points at
VICTIM="$OUT/victim"               # stands in for a root-only file (/etc/shadow, a host key)
SECRET="$OUT/secret.json"          # stands in for a root-only JSON (another account's credential)
VICTIM_TEXT="VICTIM-ROOT-ONLY"
SECRET_MARK="ROOTONLY-SECRET"
RACE=""                            # which window the shims open: temp, open, install, unlink

reset_sb() {
    command rm -rf "$SB"
    mkdir -p "$CFG" "$AGENT_HOME/.ssh" "$OUT" "$SB/root" "$SB/master" "$SB/bake"
    printf '%s\n' "$VICTIM_TEXT" > "$VICTIM"; chmod 640 "$VICTIM"
    printf '{"claudeAiOauth":{"accessToken":"%s"},"oauthAccount":{"accountUuid":"%s"}}\n' \
        "$SECRET_MARK" "$SECRET_MARK" > "$SECRET"
    chmod 600 "$SECRET"
}
victim_intact() { [[ "$(command cat "$VICTIM" 2>/dev/null)" == "$VICTIM_TEXT" && "$(stat -c %a "$VICTIM")" == 640 ]]; }
victim_state()  { printf '%s, mode %s' "$(command head -c 40 "$VICTIM" 2>/dev/null | tr '\n' ' ')" "$(stat -c %a "$VICTIM" 2>/dev/null)"; }
# A regular file in the agent's dirs holding the secret (grep -r follows no symlink: a planted
# link is not a leak, a file root wrote with the secret in it is).
secret_leaked() { command grep -rlF "$SECRET_MARK" "$AGENT_HOME" 2>/dev/null | head -n 1; }
regular() { [[ -f "$1" && ! -L "$1" ]]; }

# --- the racing session, as shims in root's shell --------------------------------------------
in_agent_dir() { [[ "$1" == "$AGENT_HOME"/* ]]; }
plant() { command rm -f -- "$1"; command ln -s "$2" "$1"; }   # unlink root's name, a link in its place
# mktemp: the session swaps root's fresh temp file in its dir for a link (temp).
mktemp() {
    local t
    t="$(command mktemp "$@")" || return
    if [[ "$RACE" == temp ]] && in_agent_dir "$t"; then plant "$t" "$VICTIM"; fi
    printf '%s\n' "$t"
}
# cat, jq, grep: just before root opens an agent file by name, after any check root made on
# it, the session swaps it for a link to the secret (open).
race_args() {
    local a
    [[ "$RACE" == open ]] || return 0
    for a in "$@"; do
        if [[ -f "$a" ]] && in_agent_dir "$a"; then plant "$a" "$SECRET"; fi
    done
    return 0
}
cat()  { race_args "$@"; command cat "$@"; }
jq()   { race_args "$@"; command jq "$@"; }
grep() { race_args "$@"; command grep "$@"; }
# install: GNU install creates the file, then sets its mode by name, following a link: the
# session swaps the new file for a link in between (install).
install() {
    local mode="" dir=0 dst="${*: -1}" a prev=""
    for a in "$@"; do
        [[ "$prev" == -m ]] && mode="$a"
        [[ "$a" == -d ]] && dir=1
        prev="$a"
    done
    if [[ "$RACE" == install && $dir == 0 ]] && in_agent_dir "$dst"; then
        command install "$@" || return
        plant "$dst" "$VICTIM"
        [[ -z "$mode" ]] || chmod "$mode" "$dst"
        return 0
    fi
    command install "$@"
}
# rm: the moment root unlinks an agent name, the session puts a link there (unlink).
rm() {
    local rc=0 a
    command rm "$@" || rc=$?
    if [[ "$RACE" == unlink ]]; then
        for a in "$@"; do
            [[ "$a" != -* ]] && in_agent_dir "$a" && [[ ! -e "$a" && ! -L "$a" ]] && command ln -s "$VICTIM" "$a"
        done
    fi
    return "$rc"
}

# §0a's real agent_put and agent_cat; one user here, so the agent is this user.
eval "$(ep_agent_io)"
as_agent() { "$@"; }

# fn_text <file> <name>: a function's text from a section, top-level or nested, one line or a block.
fn_text() {
    awk -v n="$2" 'f == 0 && $0 ~ "^ *"n"\\(\\) \\{" { f = 1; print; if ($0 ~ /\}[[:space:]]*$/) exit; next }
                   f { print; if ($0 ~ /^ *\}[[:space:]]*$/) exit }' "$1"
}
extracted() { [[ -n "$2" ]] && ok "$1 extracted from the shipped section" || bad "$1 did not extract: the checks on it would be vacuous"; }
log() { :; }

echo "== a temp file root made beside an agent file, swapped for a link (§1b, §6, §6a) =="
F1B="$(fn_text "$(ep_section 1b)" _write_active)"; extracted "§1b _write_active" "$F1B"
reset_sb
( RACE=temp; CLAUDE_CONFIG_DIR="$CFG"; ACTIVE_FILE="$CFG/.active-account"
  eval "$F1B"; _write_active home ) >/dev/null 2>&1
victim_intact && regular "$CFG/.active-account" && [[ "$(command cat "$CFG/.active-account")" == home ]] \
    && ok "§1b _write_active: the link at its temp name is never followed, and .active-account is written" \
    || bad "§1b _write_active followed a link swapped in at its temp name (victim: $(victim_state))"

F6A="$(fn_text "$(ep_section 6a)" _switch_write)"; extracted "§6a _switch_write" "$F6A"
reset_sb
( RACE=temp; CLAUDE_CONFIG_DIR="$CFG"; eval "$F6A"; _switch_write "$CFG/.account-switch-done" home ) >/dev/null 2>&1
victim_intact && regular "$CFG/.account-switch-done" && [[ "$(command cat "$CFG/.account-switch-done")" == home ]] \
    && ok "§6a _switch_write: the link at its temp name is never followed, and the answer is written" \
    || bad "§6a _switch_write followed a link swapped in at its temp name (victim: $(victim_state))"

S6="$(ep_section 6)"
F6_SET="$(fn_text "$S6" set_local_account)"; extracted "§6 set_local_account" "$F6_SET"
F6_SW="$(fn_text "$S6" write_switch_file)"; extracted "§6 write_switch_file" "$F6_SW"
F6_REF="$(fn_text "$S6" refresh_cached_account)"; extracted "§6 refresh_cached_account" "$F6_REF"
run6() {  # run6 <race> <call...>: one §6 helper, against a fresh sandbox
    local race="$1"; shift
    reset_sb
    printf '{"oauthAccount":{"accountUuid":"u-old"},"keep":1}\n' > "$CFG/.claude.json"
    printf '{"oauthAccount":{"accountUuid":"u-new"}}\n' > "$SB/master/.claude.json"
    ( RACE="$race"; CLAUDE_CONFIG_DIR="$CFG"; CLAUDE_UID="$(id -u)"; CLAUDE_GID="$(id -g)"
      ACCT_FILE="$CFG/.credentials-account"; SWITCH_FILE="$CFG/.account-changed"
      eval "$F6_SET"; eval "$F6_SW"; eval "$F6_REF"; "$@" ) >/dev/null 2>&1
}
run6 temp set_local_account u-new
victim_intact && regular "$CFG/.credentials-account" && [[ "$(command cat "$CFG/.credentials-account")" == u-new ]] \
    && ok "§6 set_local_account: the link at its temp name is never followed (chown, chmod 644, write)" \
    || bad "§6 set_local_account followed a link swapped in at its temp name (victim: $(victim_state))"
run6 temp write_switch_file 123 u-new
victim_intact && regular "$CFG/.account-changed" && [[ "$(command cat "$CFG/.account-changed")" == "123 u-new" ]] \
    && ok "§6 write_switch_file: the link at its temp name is never followed (chown, write)" \
    || bad "§6 write_switch_file followed a link swapped in at its temp name (victim: $(victim_state))"
run6 temp refresh_cached_account "$SB/master"
victim_intact && regular "$CFG/.claude.json" && [[ "$(command jq -r .oauthAccount.accountUuid "$CFG/.claude.json")" == u-new ]] \
    && ok "§6 refresh_cached_account: the link at its temp name is never followed, and the identity is refreshed" \
    || bad "§6 refresh_cached_account followed a link swapped in at its temp name (victim: $(victim_state))"

echo "== an agent file swapped for a link to a root-only file after root's check (§6, §7, §8b, §8c) =="
run6 open refresh_cached_account "$SB/master"
leak="$(secret_leaked)"
[[ -z "$leak" ]] \
    && ok "§6 refresh_cached_account: a root-only file never reaches the agent's .claude.json" \
    || bad "§6 refresh_cached_account copied a root-only file into the agent's dir: $leak"

# The credential sync: the agent's copy is swapped for a link to another root-only credential as
# root reads it. The master must only ever get what the agent itself can read.
SYNC="$(awk '/^# >>> credential sync/{f=1} f{print} /^# <<< credential sync/{exit}' "$S6")"
extracted "§6's credential sync" "$SYNC"
reset_sb
printf '{"claudeAiOauth":{"accessToken":"tok-local"}}\n' > "$CFG/.credentials.json"
printf '{"claudeAiOauth":{"accessToken":""}}\n' > "$SB/master/.credentials.json"
( CLAUDE_CONFIG_DIR="$CFG"; AUTH_DIR="$SB/master"; CLAUDE_UID="$(id -u)"; CLAUDE_GID="$(id -g)"
  CLAUDE_AUTH_FOLLOW=0; CREDS_SNAP_DIR="$SB/root/snap"; CLAUDE_BIN_RE='^/fake/bin/claude$'
  set -euo pipefail
  eval "$SYNC"
  RACE=open; reconcile_once || true ) >/dev/null 2>&1
if ! command grep -qF "$SECRET_MARK" "$SB/master/.credentials.json" 2>/dev/null \
   && command grep -qF tok-local "$SB/master/.credentials.json" 2>/dev/null; then
    ok "§6 sync: the master gets the agent's own copy, never a root-only file the copy was swapped for"
else
    bad "§6 sync published a root-only file to the master through the agent's copy: $(command head -c 80 "$SB/master/.credentials.json" 2>/dev/null)"
fi

S7="$(awk '/^# --- 7\. Seed/{f=1} f && /^# --- 7a\./{exit} f{print}' "$(ep_section 7)")"
extracted "§7" "$S7"
run7() {  # run7 <race> [existing .claude.json]
    reset_sb
    [[ -z "${2:-}" ]] || printf '%s\n' "$2" > "$CFG/.claude.json"
    ( RACE="$1"; CLAUDE_CONFIG_DIR="$CFG"; AUTH_DIR="$SB/master"; WORKSPACE=/workspace
      CLAUDE_UID="$(id -u)"; CLAUDE_GID="$(id -g)"
      set -euo pipefail
      eval "$S7" ) >/dev/null 2>&1
}
cj_trusted() { regular "$CFG/.claude.json" && [[ "$(command jq -r '.projects["/workspace"].hasTrustDialogAccepted' "$CFG/.claude.json" 2>/dev/null)" == true ]]; }
run7 temp
victim_intact && cj_trusted \
    && ok "§7: links at its temp names are never followed, and .claude.json is seeded with the trust" \
    || bad "§7 followed a link swapped in at a temp name (victim: $(victim_state))"
run7 open '{"keep":1}'
leak="$(secret_leaked)"
[[ -z "$leak" ]] && cj_trusted \
    && ok "§7: a root-only file swapped in at .claude.json never reaches the agent's files" \
    || bad "§7 merged a root-only file into the agent's dir: ${leak:-.claude.json not written}"

S8B="$(cat "$(ep_section 8b)")"
S8C="$(awk '/^# --- 8c\./{f=1} f && /^# The runtime kit/{exit} f{print}' "$(ep_section 8c)")"
extracted "§8c's baked merge" "$S8C"
run8() {  # run8 <race> <section text>
    reset_sb
    printf '{"model":"x"}\n' > "$CFG/settings.json"
    printf '{"keep":1}\n' > "$CFG/.claude.json"
    printf '{}\n' > "$SB/bake/settings.json"; mkdir -p "$SB/bake/plugins"
    printf '{"enabledPlugins":{"p@m":true}}\n' > "$SB/bake/plugins/plugins.json"
    ( RACE="$1"; CLAUDE_CONFIG_DIR="$CFG"; BAKE_DIR="$SB/bake"; CJSON="$CFG/.claude.json"
      CLAUDE_UID="$(id -u)"; CLAUDE_GID="$(id -g)"
      set -euo pipefail
      eval "$2" ) >/dev/null 2>&1
}
settings_ok() { regular "$CFG/settings.json" && [[ "$(command jq -r "$1" "$CFG/settings.json" 2>/dev/null)" == "$2" ]]; }
run8 temp "$S8B"
victim_intact && settings_ok .model x \
    && ok "§8b: the link at its temp name is never followed, and settings.json keeps the agent's settings" \
    || bad "§8b followed a link swapped in at its temp name (victim: $(victim_state))"
run8 open "$S8B"
leak="$(secret_leaked)"
[[ -z "$leak" ]] && regular "$CFG/settings.json" \
    && ok "§8b: a root-only file swapped in at settings.json never reaches the agent's files" \
    || bad "§8b merged a root-only file into the agent's dir: ${leak:-settings.json not written}"
run8 temp "$S8C"
victim_intact && settings_ok '.enabledPlugins["p@m"]' true \
    && ok "§8c: the link at its temp name is never followed, and the baked plugins are merged" \
    || bad "§8c followed a link swapped in at its temp name (victim: $(victim_state))"
run8 open "$S8C"
leak="$(secret_leaked)"
[[ -z "$leak" ]] && regular "$CFG/settings.json" \
    && ok "§8c: a root-only file swapped in at settings.json never reaches the agent's files" \
    || bad "§8c merged a root-only file into the agent's dir: ${leak:-settings.json not written}"

echo "== GNU install's chmod by name, after it creates the file (§6, §5, §8a, §8d) =="
F6_BOOT="$(awk '/^if \[\[ -s "\$AUTH_DIR\/.credentials.json" && ! -s "\$CLAUDE_CONFIG_DIR\/.credentials.json" \]\]; then$/{f=1} f{print} f&&/^fi$/{exit}' "$S6")"
extracted "§6's first copy of the credential" "$F6_BOOT"
reset_sb
printf '{"claudeAiOauth":{"accessToken":"tok-m"}}\n' > "$SB/master/.credentials.json"
( RACE=install; CLAUDE_CONFIG_DIR="$CFG"; AUTH_DIR="$SB/master"; CLAUDE_UID="$(id -u)"; CLAUDE_GID="$(id -g)"
  set -euo pipefail; eval "$F6_BOOT" ) >/dev/null 2>&1
victim_intact && regular "$CFG/.credentials.json" && [[ "$(stat -c %a "$CFG/.credentials.json")" == 600 ]] \
    && ok "§6: the first copy of the credential never chmods a link swapped in at its name" \
    || bad "§6's first copy chmodded or wrote a link swapped in at its name (victim: $(victim_state))"

reset_sb
printf '# baked\n' > "$SB/bake/CLAUDE.md"
( RACE=install; CLAUDE_CONFIG_DIR="$CFG"; BAKE_DIR="$SB/bake"; CLAUDE_UID="$(id -u)"; CLAUDE_GID="$(id -g)"
  set -euo pipefail
  # shellcheck source=/dev/null
  source "$(ep_section 8a)" ) >/dev/null 2>&1
victim_intact && regular "$CFG/CLAUDE.md" && [[ "$(command cat "$CFG/CLAUDE.md")" == '# baked' ]] \
    && ok "§8a: the global CLAUDE.md is installed, and a link swapped in at its name is never chmodded 644" \
    || bad "§8a chmodded a link swapped in at CLAUDE.md (victim: $(victim_state))"

reset_sb
mkdir -p "$SB/bake/commands"; printf '# cmd\n' > "$SB/bake/commands/hello.md"
( RACE=install; CLAUDE_CONFIG_DIR="$CFG"; BAKE_DIR="$SB/bake"; CLAUDE_UID="$(id -u)"; CLAUDE_GID="$(id -g)"
  set -euo pipefail
  # shellcheck source=/dev/null
  source "$(ep_section 8d)" ) >/dev/null 2>&1
victim_intact && regular "$CFG/commands/hello.md" \
    && ok "§8d: a baked command is installed, and a link swapped in at its name is never chmodded 644" \
    || bad "§8d chmodded a link swapped in at a command's name (victim: $(victim_state))"

# §5 with the readable-key opt-out: the only path that writes a key file and appends to the config.
S5="$(awk '/^# --- 5\. Git SSH key \+ identity/{f=1} f{print} f&&/^fi$/{exit}' "$(ep_section 5)")"
extracted "§5's key block" "$S5"
run5() {  # run5 <race>
    reset_sb
    printf 'KEYBYTES\n' > "$SB/root/git-key"
    local blk
    blk="$(printf '%s\n' "$S5" | sed -e "s#^BROKER_RUN_DIR=.*#BROKER_RUN_DIR=\"$SB/root/run\"#" \
                                     -e "s#^BROKER_PROFILE_D=.*#BROKER_PROFILE_D=\"$SB/root/profile-d.sh\"#")"
    ( RACE="$1"; CLAUDE_HOME="$AGENT_HOME"; GITKEY_SRC="$SB/root/git-key"; CLAUDE_BROKER_GIT_KEY=0
      CLAUDE_USER="$(id -un)"; CLAUDE_UID="$(id -u)"; CLAUDE_GID="$(id -g)"
      set -euo pipefail; eval "$blk" ) >/dev/null 2>&1
}
ssh_ok() { regular "$AGENT_HOME/.ssh/config" && command grep -q 'IdentityFile ~/.ssh/id_ed25519' "$AGENT_HOME/.ssh/config" \
           && regular "$AGENT_HOME/.ssh/id_ed25519" && [[ "$(stat -c %a "$AGENT_HOME/.ssh/config")" == 600 ]]; }
run5 install
victim_intact && ssh_ok \
    && ok "§5: the key file is installed, and a link swapped in at its name is never chmodded" \
    || bad "§5 chmodded a link swapped in at ~/.ssh/id_ed25519 (victim: $(victim_state))"
run5 unlink
victim_intact && ssh_ok \
    && ok "§5: a link put at ~/.ssh/config the moment root unlinks it is never written through" \
    || bad "§5 wrote ~/.ssh/config through a link put there after its unlink (victim: $(victim_state))"

echo "== own_tree and hard links =="
# A hard link is the file itself: one the agent made in its home to a system file (the same
# filesystem as the container layer) would be handed over by a chown by name, -h or not.
reset_sb
mkdir -p "$SB/bin" "$SB/tree/d"; : > "$SB/tree/d/one"; : > "$SB/tree/d/linked"; ln "$SB/tree/d/linked" "$SB/tree/d/linked2"
printf '#!/bin/sh\nshift 2\nfor f; do echo "$f"; done >> "%s"\n' "$SB/chowned" > "$SB/bin/chown"; chmod +x "$SB/bin/chown"
( PATH="$SB/bin:$PATH"; CLAUDE_UID=4242; CLAUDE_GID=4242; unset CLAUDE_CONTAINERS
  eval "$(sed -n '/^CONTAINERS_SUBID_START=/,/^}/p' "$REPO_ROOT/entrypoint.sh")"
  own_tree "$SB/tree" ) >/dev/null 2>&1
chowned="$(sort "$SB/chowned" 2>/dev/null | tr '\n' ' ')"
[[ "$chowned" == *"./one"* && "$chowned" == *"./d"* && "$chowned" != *linked* ]] \
    && ok "own_tree hands over a file and a directory, never a file with a second hard link" \
    || bad "own_tree must skip a multiply-linked file: it chowned $chowned"

echo "== §0a: the agent's own steps run as the agent, on the system PATH =="
AIO="$(ep_agent_io)"
[[ "$AIO" == *'as_agent() { gosu "$CLAUDE_USER" "$@"; }'* ]] \
    && ok "as_agent is gosu to the agent user, with no PATH handed over: root's system-only PATH" \
    || bad "§0a's as_agent must be exactly gosu to \$CLAUDE_USER (no env PATH=): ${AIO:-missing}"
reset_sb
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "%s"\nshift\nexec "$@"\n' "$SB/gosu-users" > "$SB/root/gosu"
chmod +x "$SB/root/gosu"
( PATH="$SB/root:$PATH"; CLAUDE_USER=agent-user; eval "$AIO"
  printf 'hello\n' | agent_put "$CFG/put" 640; agent_cat "$CFG/put" > "$SB/root/got" ) >/dev/null 2>&1
[[ "$(sort -u "$SB/gosu-users" 2>/dev/null)" == agent-user && "$(command cat "$SB/root/got" 2>/dev/null)" == hello \
   && "$(stat -c %a "$CFG/put" 2>/dev/null)" == 640 ]] \
    && ok "agent_put and agent_cat run through gosu to the agent user, and write with the mode asked for" \
    || bad "agent_put/agent_cat did not run as the agent user: $(command cat "$SB/gosu-users" 2>/dev/null | tr '\n' ' ')"

echo "== what root copies from, and the root-run tools =="
DF="$REPO_ROOT/Dockerfile"
if ! command grep -qE '^[^#]*chown[^#]*CLAUDE_UID[^#]*/opt/claude-config' "$DF" \
   && command grep -qE '^[^#]*chown -R root:root /opt/claude-config && chmod -R u=rwX,go=rX /opt/claude-config' "$DF"; then
    ok "the image keeps /opt/claude-config root's and read-only to the agent (the entrypoint copies from it as root)"
else
    bad "the image must not hand /opt/claude-config to the agent: a link it left there would be copied as root"
fi
command grep -qF 'last="$(gosu "$CLAUDE_USER" tail -n 800 -- "$LOG"' "$REPO_ROOT/bin/claude-healthcheck" \
    && ! command grep -qE '^[^#]*[^ ] *tail -n 800 "\$LOG"' "$REPO_ROOT/bin/claude-healthcheck" \
    && ok "the healthcheck (root) reads the agent's RC debug log as the agent" \
    || bad "the healthcheck must read the agent's RC debug log as the agent, never as root by name"
command grep -qF 'if as_agent /usr/local/bin/claude-kit settings "$CLAUDE_CONFIG_DIR/settings.json"; then' "$(ep_section 8c)" \
    && ok "§8c runs claude-kit's settings merge as the agent" \
    || bad "§8c must run claude-kit settings as the agent: it reads and writes the agent's settings.json"

echo "== nowhere in the boot path does a root step name an agent path =="
# Every line root runs, outside comments and log lines, that names an agent path and a tool that
# opens, creates or changes a file by name. The agent's own steps (as_agent, agent_put,
# agent_cat, asclaude), own_tree (-execdir, -h), install -d (a no-follow descriptor), a test
# ([[ -L ]], [[ -s ]]) and an unlink are allowed.
AGENT_VARS='CLAUDE_CONFIG_DIR|CLAUDE_HOME|CJSON|ACCT_FILE|SWITCH_FILE|ACTIVE_FILE|SETTINGS_DST|AUTHKEYS_DST|HOOKS_DIR|CC_PREFIX|gmd|cj|b'
NET="$(ep_boot | command grep -nE "(^|[^a-z_-])(mktemp|install|chmod|chown|cp|ln|cat|jq|grep|cmp|diff|tee|touch|tail|dd)( [^|;&]*)?\"\\\$\\{?($AGENT_VARS)[}\"/]|>>? *\"?\\\$\\{?($AGENT_VARS)[}\"/]" \
    | command grep -vE '^[0-9]+: *#|^[0-9]+: *(log|die) |as_agent |agent_put |agent_cat |asclaude |install -d |-execdir chown -h|own_tree ' || true)"
[[ -z "$NET" ]] \
    && ok "no root mktemp, install, chmod, chown, cp, ln, cat, jq, grep, cmp, diff, tail, dd or redirect names an agent path" \
    || bad "root acts by name on an agent path:"$'\n'"$NET"

echo
echo "agent-paths-unit: $PASS passed, $FAIL failed"
exit $(( FAIL > 0 ? 1 : 0 ))
