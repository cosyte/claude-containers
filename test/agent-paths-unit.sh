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
#   - root's install -d never names a path in the agent's dirs (it follows a symlink at a name
#     that exists): §2d's runtime dir, §8d, §8e
#   - root makes no temp file in TMPDIR (the agent's /scratch) for the agent's content: a
#     here-string bigger than a pipe is one, which bash opens again by name (§6, §7, §12f)
#   - the login (§1) keeps the auth volume root's: it runs as the agent in a private directory,
#     its result is read by the agent and written into the volume as root's own file; links in
#     the login's directory or left in the volume by an older login are never followed, and a
#     failed login changes nothing. A master an older login left open is locked before root
#     reads it: at start (§6), on every sync pass, and before a switch reads it (§6a)
#   - own_tree never hands over a file with a second hard link
#   - §0a's as_agent really drops to the agent user (a recording gosu), on the system PATH
#   - the image keeps /opt/claude-config root's; the healthcheck reads the agent's log as the
#     agent; claude-kit's settings merge runs as the agent; nowhere in the boot path does a root
#     file operation (mktemp, install, chmod, chown, cp, ln, cat, jq, grep, dd, rm, mkdir, mv,
#     find, a redirect) name a path in the agent's dirs, and root never hands the auth volume to
#     the agent or writes it other than through root_put and lock_master (static nets under the
#     behavioural checks)
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
# Every line root runs, outside comments and log lines, that names a path in the agent's dirs
# (the config dir, which in a bare `docker run` is a plain directory the agent can swap, its
# home, the CLI prefix, the files in them) and a tool that opens, creates, removes, moves or
# changes a file by name (install -d too: it follows a symlink at a name that exists). The
# agent's own steps (as_agent, agent_put, agent_cat, asclaude), own_tree (-execdir, -h) and a
# test ([[ -L ]], [[ -s ]]) are allowed.
AGENT_VARS='CLAUDE_CONFIG_DIR|CLAUDE_HOME|CJSON|ACCT_FILE|SWITCH_FILE|ACTIVE_FILE|SETTINGS_DST|AUTHKEYS_DST|HOOKS_DIR|CC_PREFIX|gmd|cj|b|req_file|done_file|use_req_file|use_done_file|_ld'
TOOLS='mktemp|install|chmod|chown|cp|ln|cat|jq|grep|cmp|diff|tee|touch|tail|head|dd|rm|mkdir|mv|find|ls|truncate|sed'
NET="$(ep_boot | command grep -nE "(^|[^a-z_-])($TOOLS)( [^|;&]*)?\"\\\$\\{?($AGENT_VARS)[}\"/]|[<>]+ *\"?\\\$\\{?($AGENT_VARS)[}\"/]" \
    | command grep -vE '^[0-9]+: *#|^[0-9]+: *(log|die) |as_agent |agent_put |agent_cat |asclaude |-execdir chown -h|own_tree |_ld="\$\(mktemp -d ' || true)"
[[ -z "$NET" ]] \
    && ok "no root mktemp, install, chmod, chown, cp, ln, cat, jq, grep, cmp, diff, tail, dd, rm, mkdir, mv, find or redirect names an agent path" \
    || bad "root acts by name on an agent path:"$'\n'"$NET"
# The auth volume ($AUTH_DIR, /auth-accounts/<name>) is root's: root reads it, writes it only
# through root_put and lock_master, and never hands it, or the login, to the agent.
AUTH_NET="$(ep_boot | command grep -nE '(chown|chmod)[^#|;&]*CLAUDE_UID[^#|;&]*AUTH_DIR|CLAUDE_CONFIG_DIR="\$AUTH_DIR"|>>? *"?\$\{?AUTH_DIR|(cp|install|tee|mv|ln|dd|mktemp)( [^|;&]*)?"\$\{?AUTH_DIR' \
    | command grep -vE '^[0-9]+: *#|^[0-9]+: *(log|die) ' || true)"
[[ -z "$AUTH_NET" ]] \
    && ok "root never hands the auth volume to the agent, and writes it only through root_put and lock_master" \
    || bad "root hands the auth volume to the agent, or writes it by name:"$'\n'"$AUTH_NET"

# §2d: root makes the agent's runtime dir in its own /run/user; what goes inside, the agent makes.
S2D="$(cat "$(ep_section 2d)")"
command grep -qxF '    as_agent mkdir -p -m 700 "$CONTAINERS_RUNTIME_DIR/podman"' <<<"$S2D" \
    && ! command grep -qE '^[^#]*(install|chown|chmod|mkdir)[^#|;&]*"\$CONTAINERS_RUNTIME_DIR/' <<<"$(command grep -v 'as_agent ' <<<"$S2D")" \
    && ok "§2d: the agent makes what goes inside its runtime dir; root never acts by a name in it" \
    || bad "§2d: root acts by a name inside the agent's runtime dir (an install -d there follows a symlink the agent put at the name)"

# A here-string or here-document bigger than a pipe is a temp file bash makes in TMPDIR and opens
# again by name, and root's TMPDIR is the agent's /scratch. So every here-string root runs reads
# a short value the operator set, never the agent's content, and root runs no here-document.
# Each here-string's whole word is listed, so a command substitution or a longer word shows.
HS="$(ep_boot | command grep -vE '^ *#' | command grep -oE '<<< *[^ )]+' | sed -E 's/^<<< *//' | LC_ALL=C sort -u | tr '\n' ' ')"
HD="$(ep_boot | command grep -vE '^ *#' | command grep -nE '<<-? *['"'"'"]?[A-Za-z_]+['"'"'"]?( |$)' | command grep -v '<<<' || true)"
[[ "$HS" == '"$CLAUDE_ACCOUNTS" "$OWN_TREE_KEEP_IDS" "$authkeys_fps" "$gitkey_pub" ' && -z "$HD" ]] \
    && ok "root's here-strings read only short operator values, and it runs no here-document (TMPDIR is the agent's)" \
    || bad "a root here-string or here-document could carry the agent's content into a temp file in TMPDIR: strings of ${HS:-none}; documents: ${HD:-none}"

echo "== root's own steps make nothing in TMPDIR, the agent's /scratch =="
# Bash puts a here-string bigger than a pipe in a temp file it makes in TMPDIR (and opens again
# by name). TMPDIR here is an empty directory of its own: any file made and removed in it moves
# the directory's mtime. The agent's .claude.json is 70 KB, past a pipe's 64 KiB.
BIG="$(head -c 70000 /dev/zero | tr '\0' x)"
tmpdir_untouched() { [[ "$(stat -c %.9Y "$SB/tmpdir")" == "$1" && -z "$(ls -A "$SB/tmpdir")" ]]; }
reset_sb; mkdir -p "$SB/tmpdir"; t0="$(stat -c %.9Y "$SB/tmpdir")"
printf '{"oauthAccount":{"accountUuid":"u-old"},"pad":"%s"}\n' "$BIG" > "$CFG/.claude.json"
printf '{"oauthAccount":{"accountUuid":"u-new"}}\n' > "$SB/master/.claude.json"
sleep 0.01
( TMPDIR="$SB/tmpdir"; CLAUDE_CONFIG_DIR="$CFG"; eval "$F6_REF"; refresh_cached_account "$SB/master" ) >/dev/null 2>&1
[[ "$(command jq -r .oauthAccount.accountUuid "$CFG/.claude.json" 2>/dev/null)" == u-new ]] && tmpdir_untouched "$t0" \
    && ok "§6 refresh_cached_account merges a 70 KB .claude.json and makes nothing in TMPDIR" \
    || bad "§6 refresh_cached_account made a temp file in TMPDIR for the agent's .claude.json (root's would be in /scratch)"
reset_sb; mkdir -p "$SB/tmpdir"; t0="$(stat -c %.9Y "$SB/tmpdir")"
printf '{"pad":"%s"}\n' "$BIG" > "$CFG/.claude.json"
sleep 0.01
( TMPDIR="$SB/tmpdir"; CLAUDE_CONFIG_DIR="$CFG"; AUTH_DIR="$SB/master"; WORKSPACE=/workspace
  set -euo pipefail; eval "$S7" ) >/dev/null 2>&1
cj_trusted && tmpdir_untouched "$t0" \
    && ok "§7 merges a 70 KB .claude.json and makes nothing in TMPDIR" \
    || bad "§7 made a temp file in TMPDIR for the agent's .claude.json (root's would be in /scratch)"

echo "== the login (§1): the auth volume is root's before, during and after =="
# A login used to hand the whole auth volume to the agent user (chown -R) and log in with the
# volume itself as the CLI's config dir, so every running container's agent could reach the
# master until it restarted. The real §1 block runs here against a sandbox: a fake login CLI,
# the agent's side of a read modelled as the kernel does it (the agent's cat cannot open a
# root-only file), and root's chown recorded instead of run (the agent is uid 4242 here).
L1="$(awk '/^# --- Login mode/{f=1} f{print} f&&/^fi$/{exit}' "$(ep_section 1)")"
extracted "§1's login mode" "$L1"
CRED_SECRET="$OUT/other-account.credentials.json"   # root-only: another account's credential
LB="$SB/lbin"; LA="$SB/lagent"                      # the fake CLI; the agent's own tools
run_login() {  # run_login <fake mode> [plant-temp]: the shipped block; prints rc=<n> last
    local blk
    command rm -rf "$LB" "$LA"; mkdir -p "$LB" "$LA" "$SB/tmp"
    printf '{"claudeAiOauth":{"accessToken":"%s"}}\n' "$SECRET_MARK" > "$CRED_SECRET"; chmod 600 "$CRED_SECRET"
    # The fake `claude auth login`: writes what the real one does into CLAUDE_CONFIG_DIR, or not.
    cat > "$LB/claude" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$CLAUDE_CONFIG_DIR" > "$FAKE_SEEN"
d="$CLAUDE_CONFIG_DIR"
case "$FAKE_MODE" in
    fail) exit 1 ;;
    notoken) printf '{"claudeAiOauth":{"accessToken":""}}\n' > "$d/.credentials.json" ;;
    plant-cred) ln -s "$FAKE_CRED_SECRET" "$d/.credentials.json" ;;
    *) printf '{"claudeAiOauth":{"accessToken":"tok-login"}}\n' > "$d/.credentials.json" ;;
esac
case "$FAKE_MODE" in
    plant-json) ln -s "$FAKE_SECRET" "$d/.claude.json" ;;
    fail|notoken|plant-cred) ;;
    *) printf '{"oauthAccount":{"accountUuid":"u-login"}}\n' > "$d/.claude.json" ;;
esac
FAKE
    chmod +x "$LB/claude"; command cp "$LB/claude" "$LA/claude"
    # The agent's cat, as the kernel answers it: a root-only file (under OUT) cannot be opened.
    printf '#!/bin/sh\nfor a; do case "$(readlink -f -- "$a" 2>/dev/null)" in "%s"/*) echo "cat: $a: Permission denied" >&2; exit 1 ;; esac; done\nexec /bin/cat "$@"\n' "$OUT" > "$LA/cat"
    printf '#!/usr/bin/env bash\nshift\nexec "$@"\n' > "$LA/gosu"
    chmod +x "$LA/cat" "$LA/gosu"
    blk="$(printf '%s\n' "$L1" | sed -e "s#^LOGIN_CLI=.*#LOGIN_CLI=\"$LB/claude\"#" -e "s#^LOGIN_TMP=.*#LOGIN_TMP=\"$SB/tmp\"#")"
    ( export FAKE_MODE="$1" FAKE_SEEN="$SB/login-dir" FAKE_SECRET="$SECRET" FAKE_CRED_SECRET="$CRED_SECRET"
      export CLAUDE_AGENT_PATH="$LA:$PATH"; export PATH="$LA:$PATH"
      AUTH_DIR="$SB/auth"; CLAUDE_USER="$(id -un)"; CLAUDE_UID=4242; CLAUDE_GID=4242; CLAUDE_HOME="$AGENT_HOME"
      CLAUDE_LOGIN_MODE=1
      as_agent() { PATH="$LA:$PATH" "$@"; }
      chown() { printf '%s\n' "$*" >> "$SB/chown.log"; }
      die() { echo "die: $*"; exit 1; }
      log() { :; }
      # root's own reads and writes: any name in the agent's private login dir is recorded
      for t in cat jq grep dd cp install head; do
          eval "$t() { local a; for a; do [[ \"\$a\" == \"$SB/tmp/claude-login.\"* ]] && printf '%s %s\n' $t \"\$a\" >> \"$SB/root-opened.log\"; done; command $t \"\$@\"; }"
      done
      if [[ "${2:-}" == plant-temp ]]; then
          mktemp() { local t; t="$(command mktemp "$@")" || return; [[ "$1" == -u && "$t" == "$SB/auth/"* ]] && command ln -s "$VICTIM" "$t"; printf '%s\n' "$t"; }
      fi
      eval "$blk"
      echo "fell through" ) 2>&1
    echo "rc=$?"
}
login_sb() {  # a volume an older login left: mode 755, links at both names, an old credential elsewhere
    reset_sb; mkdir -p "$SB/auth"; chmod 755 "$SB/auth"; : > "$SB/chown.log"; : > "$SB/root-opened.log"
    command ln -s "$VICTIM" "$SB/auth/.credentials.json"; command ln -s "$VICTIM" "$SB/auth/.claude.json"
}
login_sb_old() {  # the same, with a credential of its own already there (tok-old)
    login_sb; command rm -f "$SB/auth/.credentials.json"
    printf '{"claudeAiOauth":{"accessToken":"tok-old"}}\n' > "$SB/auth/.credentials.json"
}
handed_to_agent() { command grep -E '4242:4242' "$SB/chown.log" | command grep -F "$SB/auth" || true; }
login_dir_gone() { local d; d="$(command cat "$SB/login-dir" 2>/dev/null)"; [[ -n "$d" && "$d" != "$SB/auth"* && ! -e "$d" ]]; }

login_sb; out="$(run_login ok)"
if [[ "$out" == *"rc=0"* ]] && regular "$SB/auth/.credentials.json" && command grep -q tok-login "$SB/auth/.credentials.json" \
   && [[ "$(stat -c %a "$SB/auth/.credentials.json")" == 600 && "$(stat -c %a "$SB/auth")" == 700 ]] \
   && regular "$SB/auth/.claude.json" && [[ "$(command jq -r .oauthAccount.accountUuid "$SB/auth/.claude.json")" == u-login ]]; then
    ok "§1: the login's credential and identity land in the volume as regular files, mode 600, the volume mode 700"
else
    bad "§1: the login did not land as root's own files in a mode-700 volume: $(tail -n 3 <<<"$out" | tr '\n' ' ')"
fi
victim_intact \
    && ok "§1: links an older login's agent left in the volume are replaced, never written through" \
    || bad "§1 wrote through a link in the auth volume (victim: $(victim_state))"
[[ -z "$(handed_to_agent)" ]] \
    && ok "§1: nothing in the auth volume is ever handed to the agent user" \
    || bad "§1 handed the auth volume to the agent: $(handed_to_agent | head -n 2 | tr '\n' ' ')"
login_dir_gone \
    && ok "§1: the login runs in a private directory outside the volume, removed afterwards" \
    || bad "§1: the login's config dir was the volume, or was left behind: $(command cat "$SB/login-dir" 2>/dev/null)"
[[ ! -s "$SB/root-opened.log" ]] \
    && ok "§1: root opens no name in the login's directory (the agent reads it, agent_cat)" \
    || bad "§1: root opened names in the agent's login directory: $(head -n 2 "$SB/root-opened.log" | tr '\n' ' ')"

login_sb; out="$(run_login plant-json)"
[[ "$out" == *"rc=0"* && ! -L "$SB/auth/.claude.json" ]] && ! command grep -rqF "$SECRET_MARK" "$SB/auth" \
    && ok "§1: a link the login leaves at .claude.json to a root-only file never reaches the volume" \
    || bad "§1: a root-only file reached the volume through the login's .claude.json: $(tail -n 2 <<<"$out" | tr '\n' ' ')"
login_sb_old; out="$(run_login plant-cred)"
[[ "$out" != *"rc=0"* ]] && command grep -q tok-old "$SB/auth/.credentials.json" && ! command grep -rqF "$SECRET_MARK" "$SB/auth" \
    && ok "§1: a link at the login's .credentials.json to another account's credential is no login: the volume keeps its own" \
    || bad "§1 took a root-only credential through the login's .credentials.json: $(tail -n 2 <<<"$out" | tr '\n' ' ')"
for mode in fail notoken; do
    login_sb_old; out="$(run_login "$mode")"
    [[ "$out" != *"rc=0"* ]] && command grep -q tok-old "$SB/auth/.credentials.json" \
        && ok "§1: a login that $([[ $mode == fail ]] && echo fails || echo leaves no token) stops with an error, the volume's credential unchanged" \
        || bad "§1: a $mode login changed the volume or reported success: $(tail -n 2 <<<"$out" | tr '\n' ' ')"
done
login_sb_old; out="$(run_login ok plant-temp)"
victim_intact && command grep -q tok-old "$SB/auth/.credentials.json" && [[ "$out" != *"rc=0"* ]] \
    && ok "§1: a link at root's temp name in the volume is never written through (an exclusive create, then a rename)" \
    || bad "§1 wrote through a link at its temp name in the volume (victim: $(victim_state))"

echo "== a master an older login left to the agent (§6 at start, every sync pass, §6a) =="
# Until it is locked again the volume is the agent's: a link at the master's name to a root-only
# credential must never be read into the agent's own copy.
S6TOP="$(awk '/^# >>> credential sync/{exit} {print}' "$S6")"
reset_sb; mkdir -p "$SB/master"; chmod 755 "$SB/master"
printf '{"claudeAiOauth":{"accessToken":"%s"}}\n' "$SECRET_MARK" > "$OUT/cred"; chmod 600 "$OUT/cred"
command ln -s "$OUT/cred" "$SB/master/.credentials.json"
( CLAUDE_CONFIG_DIR="$CFG"; AUTH_DIR="$SB/master"; CLAUDE_SKIP_AUTH_CHECK=1; CLAUDE_UID="$(id -u)"; CLAUDE_GID="$(id -g)"
  die() { exit 1; }; set -euo pipefail; eval "$S6TOP" ) >/dev/null 2>&1
[[ ! -e "$CFG/.credentials.json" || -z "$(command grep -F "$SECRET_MARK" "$CFG/.credentials.json")" ]] \
   && [[ ! -L "$SB/master/.credentials.json" && "$(stat -c %a "$SB/master")" == 700 ]] \
    && ok "§6 at start: the master is locked before it is read; a link at its name is removed, never copied to the agent" \
    || bad "§6 at start copied a root-only file to the agent through a link at the master's name, or left the master open"

reset_sb; mkdir -p "$SB/master"; chmod 755 "$SB/master"
printf '{"claudeAiOauth":{"accessToken":"%s"}}\n' "$SECRET_MARK" > "$OUT/cred"; chmod 600 "$OUT/cred"
command ln -s "$OUT/cred" "$SB/master/.credentials.json"
printf '{"claudeAiOauth":{"accessToken":""}}\n' > "$CFG/.credentials.json"
( CLAUDE_CONFIG_DIR="$CFG"; AUTH_DIR="$SB/master"; CLAUDE_UID="$(id -u)"; CLAUDE_GID="$(id -g)"
  CLAUDE_AUTH_FOLLOW=0; CREDS_SNAP_DIR="$SB/root/snap"; CLAUDE_BIN_RE='^/fake/bin/claude$'
  set -euo pipefail; eval "$SYNC"; reconcile_once || true ) >/dev/null 2>&1
! command grep -qF "$SECRET_MARK" "$CFG/.credentials.json" 2>/dev/null \
   && [[ ! -L "$SB/master/.credentials.json" && "$(stat -c %a "$SB/master")" == 700 ]] \
    && ok "§6 every pass: the master is locked again before it is read; a link at its name never reaches the agent's copy" \
    || bad "§6's sync read a root-only file into the agent's copy through a link at the master's name"

# §6a: a switch to an account whose volume an older login left open.
S6A="$(sed "s#/auth-accounts/#$SB/accts/#g; s/while sleep 2; do/while sleep 0.1; do/" "$(ep_section 6a)")"
reset_sb; mkdir -p "$SB/accts/work" "$SB/accts/home"; chmod 755 "$SB/accts/home"
printf '{"claudeAiOauth":{"accessToken":"%s"}}\n' "$SECRET_MARK" > "$OUT/cred"; chmod 600 "$OUT/cred"
command ln -s "$OUT/cred" "$SB/accts/home/.credentials.json"
printf '{"oauthAccount":{"accountUuid":"u-home"}}\n' > "$SB/accts/home/.claude.json"
(
    CLAUDE_CONFIG_DIR="$CFG"; CLAUDE_UID="$(id -u)"; CLAUDE_GID="$(id -g)"; CLAUDE_ACCOUNTS="work,home"
    ACCT_FILE="$CFG/.credentials-account"; SWITCH_FILE="$CFG/.account-changed"; CREDS_SNAP_DIR="$SB/root/snap"
    eval "$SYNC" 2>/dev/null
    eval "$S6A"
    echo "$ACCT_SWITCH_PID" > "$SB/listener.pid"
) >/dev/null 2>&1
printf 'home\n' > "$CFG/.account-switch-request"
for _ in $(seq 1 40); do [[ -s "$CFG/.account-switch-done" ]] && break; sleep 0.1; done
kill "$(command cat "$SB/listener.pid" 2>/dev/null)" 2>/dev/null || true
! command grep -qF "$SECRET_MARK" "$CFG/.credentials.json" 2>/dev/null \
   && [[ "$(command cat "$CFG/.account-switch-done" 2>/dev/null)" == "ERROR:no-token:home" && "$(stat -c %a "$SB/accts/home")" == 700 ]] \
    && ok "§6a: an account's master is locked before a switch reads it; a link at its name is no credential" \
    || bad "§6a read a root-only file into the agent's copy through a link at an account's master: answer '$(command cat "$CFG/.account-switch-done" 2>/dev/null)'"

echo
echo "agent-paths-unit: $PASS passed, $FAIL failed"
exit $(( FAIL > 0 ? 1 : 0 ))
