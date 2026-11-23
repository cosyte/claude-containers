#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables set in subshells are read by the entrypoint block run with eval
# Unit tests for GH_TOKEN in SSH logins: NO docker daemon, NO root, NO network.
#
# sshd builds a fresh environment for every login, so an SSH login (VS Code Remote-SSH's server,
# its Git panel and terminals, `ssh host cmd`) had no GH_TOKEN while the tmux sessions did. The
# entrypoint (§5) now writes `SetEnv GH_TOKEN=...` into a root-only file that sshd_config
# Includes. These pin that:
#   - §5's block, extracted and run for real against a sandbox (only its root-only path is
#     redirected, and that redirect is asserted): with GH_TOKEN set the file holds exactly the
#     one SetEnv line, mode 600; without it (unset or empty) a file from an earlier boot is gone;
#     a value with a character a token never has is refused and never written; no temp file is
#     left; a symlink at the name is replaced, its target untouched; the value is in no log line
#   - the block hands the value to nothing but a builtin (no command line carries it)
#   - sshd_config Includes that same path, last, outside any Match block, with no SetEnv of its own
#   - with an sshd on this machine, its own parser reads the result: `sshd -T` shows the token
#     with the file and no SetEnv without it (SKIP when there is no sshd)
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

S5="$(ep_section 5)"
SSHD_CONFIG="$REPO_ROOT/sshd_config"
TOKEN_PATH="/etc/ssh/sshd_config.d/claude-gh-token.conf"
# Distinctive enough to grep every log and file for.
TOK="ghp_unitTestDummyToken"

echo "== §5: GH_TOKEN for SSH logins, run against a sandbox =="
BLOCK="$(awk '/^# >>> GH_TOKEN for SSH logins/{f=1} f{print} /^# <<< GH_TOKEN for SSH logins/{exit}' "$S5")"
blk() {  # blk <sandbox>: the shipped block with ONLY its root-only path pointed into <sandbox>
    printf '%s\n' "$BLOCK" | sed -e "s#^SSHD_TOKEN_CONF=\"[^\"]*\"#SSHD_TOKEN_CONF=\"$1/sshd_config.d/claude-gh-token.conf\"#"
}
probe="$(blk "$TMPD/probe")"
if [[ -n "$BLOCK" ]] && grep -qF "SSHD_TOKEN_CONF=\"$TMPD/probe/sshd_config.d/claude-gh-token.conf\"" <<<"$probe" \
   && [[ "$(grep -c '^SSHD_TOKEN_CONF=' <<<"$probe")" == 1 ]] \
   && grep -qF "SSHD_TOKEN_CONF=\"$TOKEN_PATH\"" <<<"$BLOCK"; then
    ok "the block is extracted from §5, names $TOKEN_PATH, and that one path is redirected into a sandbox"
else
    # Stop here: every case below would write into the real /etc/ssh/sshd_config.d.
    bad "the block did not extract, or its root-only path did not redirect: these tests would target /etc/ssh"
    echo; echo "git-unit: $PASS passed, $FAIL failed"; exit 1
fi

# run_block <sandbox> [VAR=VAL ...]: the block under the entrypoint's shell options, as the
# loader sources it; GH_TOKEN only as given (this suite may itself run where one is set).
# RB_UMASK and RB_STUBS (a directory put first on PATH) set up the hostile cases.
run_block() {
    local sb="$TMPD/$1"; shift
    mkdir -p "$sb"
    local b; b="$(blk "$sb")"
    ( unset GH_TOKEN
      # shellcheck disable=SC2163  # "$@" is VAR=VAL pairs, exported as given
      if [[ $# -gt 0 ]]; then export "$@"; fi
      [[ -z "${RB_UMASK:-}" ]] || umask "$RB_UMASK"
      [[ -z "${RB_STUBS:-}" ]] || PATH="$RB_STUBS:$PATH"
      log() { echo "[entrypoint] $*"; }
      set -euo pipefail
      eval "$b"
      echo "rc=0" ) 2>&1
}
conf_of() { printf '%s' "$TMPD/$1/sshd_config.d/claude-gh-token.conf"; }
leftovers() { find "$TMPD/$1/sshd_config.d" -name '.claude-gh-token.*' 2>/dev/null | wc -l; }

# --- the token is set ----------------------------------------------------------------------
out="$(run_block set "GH_TOKEN=$TOK")"; f="$(conf_of set)"
[[ "$out" == *"rc=0"* && -f "$f" && ! -L "$f" && "$(cat "$f")" == "SetEnv GH_TOKEN=$TOK" ]] \
    && ok "GH_TOKEN set: the file holds exactly one line, SetEnv GH_TOKEN=<the token>" \
    || bad "GH_TOKEN set: no file or the wrong content: $out / $(cat "$f" 2>&1)"
[[ "$(stat -c '%a' "$f" 2>/dev/null)" == 600 ]] \
    && ok "the file is mode 600 (root's, read by sshd only)" \
    || bad "the file's mode is $(stat -c '%a' "$f" 2>&1), not 600"
grep -q "GH_TOKEN for SSH    : every SSH login gets it too" <<<"$out" \
    && ok "the boot log says SSH logins get the token" || bad "no boot log line for SSH logins: $out"
grep -qF "$TOK" <<<"$out" && bad "the token's value is in the boot log" || ok "the token's value is in no boot log line"
[[ "$(leftovers set)" == 0 ]] && ok "no temp file is left beside it" || bad "a temp file is left: $(ls -A "$TMPD/set/sshd_config.d")"
# Fakes in each shape GitHub issues (fine-grained, OAuth, an old installation token, a 40-hex
# legacy one), none a real token's length or checksum.
for t in "github_pat_unitTestDummy_fineGrained" "gho_unitTestDummy" "v1.0123abcd" "0123456789abcdef"; do
    out="$(run_block "fmt" "GH_TOKEN=$t")"
    [[ "$(cat "$(conf_of fmt)" 2>/dev/null)" == "SetEnv GH_TOKEN=$t" ]] \
        && ok "a token of the form ${t:0:11}... is written" || bad "a token of the form ${t:0:11}... was refused: $out"
done

# A new boot with another token replaces the old one, through a symlink planted at the name
# never: the link is replaced and what it pointed at is untouched.
mkdir -p "$TMPD/link/sshd_config.d"; echo outside > "$TMPD/outside"
ln -s "$TMPD/outside" "$(conf_of link)"
out="$(run_block link "GH_TOKEN=$TOK")"
[[ "$(cat "$TMPD/outside")" == outside && ! -L "$(conf_of link)" && "$(cat "$(conf_of link)")" == "SetEnv GH_TOKEN=$TOK" ]] \
    && ok "a symlink at the name is replaced with root's own file; its target is untouched" \
    || bad "the block wrote through a symlink, or left it: $out"

# The file is never readable by anyone but root, not even for a moment: it is created 0600 by
# mktemp, so a chmod that does nothing and a umask of 000 still leave it 600.
mkdir -p "$TMPD/stub-chmod"; printf '#!/bin/sh\nexit 0\n' > "$TMPD/stub-chmod/chmod"; chmod +x "$TMPD/stub-chmod/chmod"
out="$(RB_UMASK=000 RB_STUBS="$TMPD/stub-chmod" run_block umask "GH_TOKEN=$TOK")"
[[ "$out" == *"rc=0"* && "$(stat -c '%a' "$(conf_of umask)" 2>/dev/null)" == 600 ]] \
    && ok "with umask 000 and a chmod that does nothing, the file is still 600 (created private, never widened)" \
    || bad "the file is created readable before its chmod: mode $(stat -c '%a' "$(conf_of umask)" 2>&1)"

# --- the token is unset or empty: gone ------------------------------------------------------
for v in unset empty; do
    mkdir -p "$TMPD/$v/sshd_config.d"; printf 'SetEnv GH_TOKEN=%s\n' "$TOK" > "$(conf_of "$v")"
    if [[ "$v" == unset ]]; then out="$(run_block "$v")"; else out="$(run_block "$v" GH_TOKEN=)"; fi
    [[ "$out" == *"rc=0"* && ! -e "$(conf_of "$v")" ]] \
        && ok "GH_TOKEN $v: the file from an earlier boot is removed (SSH logins get no token)" \
        || bad "GH_TOKEN $v: the earlier boot's file is still there: $out"
    grep -q "GH_TOKEN for SSH\|WARNING" <<<"$out" && bad "GH_TOKEN $v: it logged a token line: $out" \
        || ok "GH_TOKEN $v: nothing is logged about SSH logins (as before)"
done

# --- a value sshd could read as more than a value: refused, never written ------------------
for v in "$TOK"$'\n'"PasswordAuthentication yes" "$TOK PermitRootLogin" "\"$TOK\"" "$TOK#x" "$TOK=" "tok/x" "tok\\x" "tok'x"; do
    mkdir -p "$TMPD/bad/sshd_config.d"; printf 'SetEnv GH_TOKEN=old\n' > "$(conf_of bad)"
    out="$(run_block bad "GH_TOKEN=$v")"
    if [[ "$out" == *"rc=0"* && ! -e "$(conf_of bad)" && "$(leftovers bad)" == 0 ]] \
       && grep -q "WARNING: GH_TOKEN holds a character outside" <<<"$out" && ! grep -qF -- "$v" <<<"$out"; then
        ok "GH_TOKEN $(printf '%q' "$v" | cut -c1-24)...: refused with a WARNING naming no value; no file (the old one is gone too)"
    else
        bad "GH_TOKEN $(printf '%q' "$v"): written, or logged with its value: $out / $(cat "$(conf_of bad)" 2>&1)"
    fi
done

# --- a failed write: a WARNING, and the boot goes on ---------------------------------------
mkdir -p "$TMPD/ro"; : > "$TMPD/ro/sshd_config.d"   # a file where the directory belongs
out="$(run_block ro "GH_TOKEN=$TOK")"
[[ "$out" == *"rc=0"* ]] && grep -q "WARNING: could not write sshd's GH_TOKEN file" <<<"$out" && ! grep -qF "$TOK" <<<"$out" \
    && ok "a file that cannot be written is a WARNING (no value in it) and the boot goes on" \
    || bad "a failed write ended the boot or went unlogged: $out"

# A failure after the temp file exists (the rename): a WARNING, no file, no temp file left.
mkdir -p "$TMPD/stub-mv"; printf '#!/bin/sh\nexit 1\n' > "$TMPD/stub-mv/mv"; chmod +x "$TMPD/stub-mv/mv"
out="$(RB_STUBS="$TMPD/stub-mv" run_block latefail "GH_TOKEN=$TOK")"
[[ "$out" == *"rc=0"* && ! -e "$(conf_of latefail)" && "$(leftovers latefail)" == 0 ]] \
    && grep -q "WARNING: could not write sshd's GH_TOKEN file" <<<"$out" && ! grep -qF "$TOK" <<<"$out" \
    && ok "a rename that fails is a WARNING, and its temp file (holding the token) is removed" \
    || bad "a failed rename left a file or no warning: $out / $(ls -A "$TMPD/latefail/sshd_config.d" 2>&1)"

# --- the value reaches nothing but builtins ---------------------------------------------------
# Every use of the value: the [[ ]] test and printf (a bash builtin), never an external
# command's argument list (readable in /proc/<pid>/cmdline by any user), never a log line.
# shellcheck disable=SC2016  # the patterns are the literal code text
uses="$(grep -v '^ *#' <<<"$BLOCK" | grep -E '\$\{?GH_TOKEN' | sed 's/^ *//')"
want="$(printf '%s\n' 'if [[ -n "${GH_TOKEN:-}" ]]; then' \
    'if [[ ! "$GH_TOKEN" =~ ^[A-Za-z0-9_.-]+$ ]]; then' \
    "&& printf 'SetEnv GH_TOKEN=%s\\n' \"\$GH_TOKEN\" > \"\$_tc\" \\")"
[[ "$uses" == "$want" ]] \
    && ok "the value is read on three lines only: the two [[ ]] tests and the builtin printf into the temp file" \
    || bad "the token's value is used somewhere else (a command line or a log?): $uses"

echo "== sshd_config Includes it =="
inc="$(grep -nE '^[[:space:]]*Include[[:space:]]' "$SSHD_CONFIG")"
[[ "$(wc -l <<<"$inc")" == 1 && "$inc" == *"Include $TOKEN_PATH" ]] \
    && ok "sshd_config has one Include, of $TOKEN_PATH (the path §5 writes)" \
    || bad "sshd_config's Include is missing or names another path: '$inc'"
last="$(grep -vE '^[[:space:]]*(#|$)' "$SSHD_CONFIG" | tail -1)"
[[ "$last" == "Include $TOKEN_PATH" ]] \
    && ok "the Include is sshd_config's last directive" || bad "the Include is not last: '$last'"
! grep -qiE '^[[:space:]]*Match[[:space:]]' "$SSHD_CONFIG" \
    && ok "no Match block: the Include reaches every login" || bad "sshd_config has a Match block: the Include may sit inside it"
! grep -qiE '^[[:space:]]*SetEnv[[:space:]]' "$SSHD_CONFIG" \
    && ok "sshd_config sets no SetEnv of its own (sshd keeps the first SetEnv line only)" \
    || bad "sshd_config has its own SetEnv: sshd would ignore the token's"
! grep -qiE '^[[:space:]]*PermitUserEnvironment[[:space:]]+yes' "$SSHD_CONFIG" \
    && ok "PermitUserEnvironment stays off (the agent's ~/.ssh/environment is never read)" \
    || bad "PermitUserEnvironment is on"

echo "== sshd's own parser reads it =="
SSHD="$(command -v sshd 2>/dev/null || true)"; [[ -n "$SSHD" ]] || { [[ -x /usr/sbin/sshd ]] && SSHD=/usr/sbin/sshd; }
if [[ -n "$SSHD" ]] && command -v ssh-keygen >/dev/null 2>&1; then
    P="$TMPD/sshd"; mkdir -p "$P"
    ssh-keygen -q -t ed25519 -f "$P/hostkey" -N '' && : > "$P/revoked"
    # The shipped config with only its root-only paths moved: the host keys, RevokedKeys, and
    # the Include, at the sandbox §5 wrote (set) and one it never wrote (unset).
    mkcfg() {
        sed -e '/^HostKey .*_rsa_key$/d' -e "s#^HostKey .*#HostKey $P/hostkey#" \
            -e "s#^RevokedKeys .*#RevokedKeys $P/revoked#" -e "s#^Include .*#Include $1#" "$SSHD_CONFIG" > "$2"
    }
    mkcfg "$(conf_of set)" "$P/with"; mkcfg "$(conf_of unset)" "$P/without"
    T="$("$SSHD" -T -f "$P/with" -C user=claude,host=localhost,addr=127.0.0.1 2>&1)"; rc=$?
    if (( rc == 0 )) && grep -qx "setenv GH_TOKEN=$TOK" <<<"$T"; then
        ok "sshd -T with §5's file: every login gets setenv GH_TOKEN=<the token>"
    elif (( rc != 0 )) && grep -qi 'privilege separation' <<<"$T"; then
        echo "  SKIP  sshd -T (this machine's sshd cannot run its test mode here: $(head -1 <<<"$T"))"
    else
        bad "sshd -T does not read the token from §5's file (rc=$rc): $(grep -i 'setenv\|error\|bad' <<<"$T" | head -3)"
    fi
    T="$("$SSHD" -T -f "$P/without" -C user=claude,host=localhost,addr=127.0.0.1 2>&1)"; rc=$?
    if (( rc == 0 )) && ! grep -qi '^setenv' <<<"$T"; then
        ok "sshd -T without the file: it starts (a missing Include is no error) and sets no GH_TOKEN"
    elif (( rc != 0 )) && grep -qi 'privilege separation' <<<"$T"; then
        echo "  SKIP  sshd -T without the file (test mode cannot run here)"
    else
        bad "sshd -T without the file failed or still sets an environment (rc=$rc): $(head -3 <<<"$T")"
    fi
else
    echo "  SKIP  sshd -T (no sshd or ssh-keygen on this machine; test/smoke.sh runs the real one)"
fi

echo
echo "git-unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
