#!/usr/bin/env bash
# Unit tests for the SSH key inputs: NO docker daemon, NO root.
#
# GIT_SSH_KEY is the private key sessions push with. The entrypoint holds it in a root
# ssh-agent, so every session can SIGN with it. SSH_AUTHORIZED_KEYS is who may log in over SSH.
# A key in both lets every session log in to every container that accepts it, and a key file
# the agent can read off its mount is not brokered at all. These pin that:
#   - bin/_common.sh: a git key's public half (from the key, or its .pub), and whether an
#     authorized_keys file lists it, by fingerprint as sshd reads the file (options, another
#     key-type name for the same key, CRLF, comments)
#   - claude-compose-gen and claude-launch REFUSE a git key that is also a login key, write
#     or start nothing, and say why; another container on the host that would let a session
#     in (or the reverse) is named; --mount cannot cover /etc/claude
#   - entrypoint.sh §4, run for real in a sandbox: the key directory is set to mode 700, the git
#     key's public half is written to sshd's RevokedKeys file (always written, empty without
#     one), a git key also in authorized_keys is named loudly, and a brokered key the agent user
#     could still read stops the boot (only the opt-out passes)
#   - the image bakes /etc/claude root-owned, mode 700, and an empty RevokedKeys file, and
#     sshd_config names it
# Real keys come from ssh-keygen (throwaway, in a temp dir). The one fake is gosu: the sandbox
# cannot switch users, so a stub answers "can the agent user read this file", per case.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

PASS=0 FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

GEN="$REPO_ROOT/bin/claude-compose-gen"
LAUNCH="$REPO_ROOT/bin/claude-launch"
ENTRYPOINT="$REPO_ROOT/entrypoint.sh"

if ! command -v ssh-keygen >/dev/null 2>&1; then
    bad "ssh-keygen is unavailable: every key test below would be theater"
    echo; echo "keys-unit: $PASS passed, $FAIL failed"; exit 1
fi

# Throwaway keys: the git key, the owner's login key, and a passphrase-protected key.
K="$TMPD/keys"; mkdir -p "$K"
ssh-keygen -q -t ed25519 -N '' -C 'git@example' -f "$K/git" </dev/null
ssh-keygen -q -t ed25519 -N '' -C 'owner@laptop' -f "$K/login" </dev/null
ssh-keygen -q -t ed25519 -N 'secret' -C 'locked' -f "$K/locked" </dev/null
GIT_BLOB="$(awk '{ print $2 }' "$K/git.pub")"
LOGIN_LINE="$(cat "$K/login.pub")"

# ======================================================================================
echo "== bin/_common.sh: the git key's public half, and whether a file accepts it =="
common() { ( set +u; source "$REPO_ROOT/bin/_common.sh" >/dev/null 2>&1; set +e; "$@" ) 2>&1; }
pub="$(common ssh_public_of "$K/git")"
[[ "$pub" == "ssh-ed25519 $GIT_BLOB" ]] \
    && ok "ssh_public_of derives 'type key' from the private key itself (no comment)" \
    || bad "ssh_public_of gave '$pub'"
cp "$K/locked" "$K/locked-nopub"
common ssh_public_of "$K/locked-nopub" >/dev/null && bad "a passphrase-protected key with no .pub must give nothing" \
    || ok "a passphrase-protected key with no .pub gives nothing (and never prompts)"
[[ "$(common ssh_public_of "$K/locked")" == "$(awk '{ print $1, $2 }' "$K/locked.pub")" ]] \
    && ok "a passphrase-protected key falls back to its .pub" \
    || bad "ssh_public_of did not fall back to the .pub beside a locked key"

AKF="$TMPD/ak"
akcase() {  # akcase <want 0|1> <label> <authorized_keys text>
    printf '%s\n' "$3" > "$AKF"
    common key_in_authorized_keys "ssh-ed25519 $GIT_BLOB" "$AKF" >/dev/null; local rc=$?
    [[ "$rc" == "$1" ]] && ok "$2" || bad "$2 (rc=$rc)"
}
akcase 0 "a plain line with the git key is a match" "ssh-ed25519 $GIT_BLOB some comment"
akcase 0 "the same key under another comment is a match" "ssh-ed25519 $GIT_BLOB other@host"
akcase 0 "a line with options before the key is a match" "restrict,command=\"echo hi\" ssh-ed25519 $GIT_BLOB"
akcase 0 "a match among other keys, blank and comment lines" "$(printf '# mine\n\n%s\nssh-ed25519 %s\n' "$LOGIN_LINE" "$GIT_BLOB")"
akcase 1 "only the login key: no match" "$LOGIN_LINE"
akcase 0 "a CRLF line is a match" "$(printf 'ssh-ed25519 %s\r' "$GIT_BLOB")"
akcase 0 "a cert-authority line for the git key is a match (it could sign login certificates)" "cert-authority ssh-ed25519 $GIT_BLOB"
akcase 1 "a commented-out git key is not accepted, so not a match" "# ssh-ed25519 $GIT_BLOB"
akcase 1 "an indented comment is not a match" "   # ssh-ed25519 $GIT_BLOB"
akcase 1 "the git key's text inside another key's command option is not a match" "command=\"echo ssh-ed25519 $GIT_BLOB\" $LOGIN_LINE"
akcase 1 "an empty file: no match" ""
# The same RSA key under the rsa-sha2-512 name: sshd accepts it, so it must match.
ssh-keygen -q -t rsa -b 2048 -N '' -f "$K/rsa" </dev/null
printf 'rsa-sha2-512 %s\n' "$(awk '{ print $2 }' "$K/rsa.pub")" > "$AKF"
common key_in_authorized_keys "$(awk '{ print $1, $2 }' "$K/rsa.pub")" "$AKF" >/dev/null \
    && ok "an RSA key listed under its rsa-sha2-512 name is a match" \
    || bad "an RSA key under the rsa-sha2-512 name was missed"

# ======================================================================================
echo "== claude-compose-gen: a git key that is also a login key is refused =="
STUBD="$TMPD/stub"; mkdir -p "$STUBD"
# docker stub: no containers unless FLEET names some. `ps -aq` lists their ids and the mounts
# query prints "/name<TAB>g:<git-key source><TAB>a:<authorized_keys source>" per container.
cat > "$STUBD/docker" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    ps)      [[ -n "${FLEET:-}" ]] && printf 'id1\n'; exit 0 ;;
    inspect) if [[ "$*" == *Mounts* ]]; then [[ -n "${FLEET:-}" ]] && printf '%b\n' "$FLEET"; exit 0; fi
             [[ -e "${STUB_STATE:-/nonexistent}/created" ]] && { echo running; exit 0; }; exit 1 ;;
    image)   [[ "$*" == *Labels* ]] && echo 0; exit 0 ;;
    run)     shift; printf '%s\n' "$@" > "$STUB_STATE/run-args"; touch "$STUB_STATE/created"; echo deadbeef ;;
    *)       exit 0 ;;
esac
STUB
chmod +x "$STUBD/docker"

gen() {  # gen <git key> <authorized_keys> <out> [args...]
    local gk="$1" ak="$2" out="$3"; shift 3
    GIT_SSH_KEY="$gk" SSH_AUTHORIZED_KEYS="$ak" PATH="$STUBD:$PATH" CLAUDE_PORTS_USED_OVERRIDE="" \
        "$GEN" --out "$out" "$@" acme/api 2>&1
}
printf '%s\n%s\n' "$LOGIN_LINE" "$(cat "$K/git.pub")" > "$TMPD/ak-both"
printf '%s\n' "$LOGIN_LINE" > "$TMPD/ak-login"
GIT_FP="$(ssh-keygen -lf "$K/git.pub" | awk '{ print $2 }')"

out="$(gen "$K/git" "$TMPD/ak-both" "$TMPD/both.yml")"; rc=$?
(( rc != 0 )) && [[ ! -e "$TMPD/both.yml" ]] \
    && ok "the git key in SSH_AUTHORIZED_KEYS: refused, nothing written (rc=$rc)" \
    || bad "compose-gen must refuse a git key that is also a login key (rc=$rc): $out"
[[ "$out" == *"the git key is also an SSH login key"* && "$out" == *"$K/git"* \
   && "$out" == *"$TMPD/ak-both"* && "$out" == *"$GIT_FP"* ]] \
    && ok "the refusal names both files and the key's fingerprint" \
    || bad "the refusal must name GIT_SSH_KEY, SSH_AUTHORIZED_KEYS and the fingerprint: $out"
! grep -q 'PRIVATE KEY' <<<"$out" \
    && ok "the refusal prints no private key material" || bad "the refusal printed private key material"

printf 'restrict,pty %s\n' "$(cat "$K/git.pub")" > "$TMPD/ak-opts"
out="$(gen "$K/git" "$TMPD/ak-opts" "$TMPD/opts.yml")"; rc=$?
(( rc != 0 )) && [[ ! -e "$TMPD/opts.yml" ]] \
    && ok "the git key behind authorized_keys options is refused too" \
    || bad "options before the key must not hide it (rc=$rc): $out"

out="$(gen "$K/git" "$TMPD/ak-login" "$TMPD/ok.yml")"; rc=$?
if (( rc == 0 )) && [[ -s "$TMPD/ok.yml" ]]; then
    ok "separate keys: the stack is written"
    grep -qxF "      - $TMPD/ak-login:/etc/claude/authorized_keys:ro" "$TMPD/ok.yml" \
        && grep -qxF "      - $K/git:/etc/claude/git-key:ro" "$TMPD/ok.yml" \
        && ok "each input is mounted read-only at its own path" \
        || bad "the two key inputs must be mounted at /etc/claude/authorized_keys and /etc/claude/git-key"
    grep -q '#   4. SSH login keys (your own public keys only)' "$TMPD/ok.yml" \
        && grep -q '#   5. Git key (for git alone, never in the file above)' "$TMPD/ok.yml" \
        && ok "the generated header tells the two inputs apart" \
        || bad "the generated header must say which file holds login keys and which the git key"
    ! grep -q 'also an SSH login key\|could not read the public half' <<<"$out" \
        && ok "no refusal and no warning about the keys" || bad "separate keys still warned: $out"
else
    bad "separate keys must generate (rc=$rc): $out"
fi

out="$(gen "$K/locked-nopub" "$TMPD/ak-both" "$TMPD/locked.yml")"; rc=$?
(( rc == 0 )) && [[ "$out" == *"could not read the public half of the git key"* ]] \
    && ok "a git key whose public half cannot be read is warned about, not silently passed" \
    || bad "an unreadable public half must warn (rc=$rc): $out"

out="$(gen "$K/git" "$TMPD/ak-login" "$TMPD/mnt.yml" --mount api=somevol:/etc/claude)"; rc=$?
(( rc != 0 )) && [[ "$out" == *"would shadow a mount"* ]] \
    && ok "--mount over /etc/claude itself is refused (it would replace the root-only directory)" \
    || bad "--mount api=somevol:/etc/claude must be refused (rc=$rc): $out"

# ======================================================================================
echo "== the same rule across the host: another container that would let a session in =="
printf '%s\n' "$(cat "$K/git.pub")" > "$TMPD/other-ak"
out="$(FLEET="/claude-other\\tg:\\ta:$TMPD/other-ak" gen "$K/git" "$TMPD/ak-login" "$TMPD/f1.yml")"; rc=$?
(( rc == 0 )) && [[ "$out" == *"container claude-other accepts this git key"* ]] \
    && ok "a container elsewhere that accepts this stack's git key for SSH is named (a warning)" \
    || bad "another container accepting this git key must be named (rc=$rc): $out"
out="$(FLEET="/claude-other\\tg:$K/login\\ta:" gen "$K/git" "$TMPD/ak-login" "$TMPD/f2.yml")"; rc=$?
(( rc == 0 )) && [[ "$out" == *"container claude-other pushes with a git key ($K/login)"* ]] \
    && ok "a container elsewhere whose git key this stack accepts for SSH is named (a warning)" \
    || bad "another container's git key in this authorized_keys must be named (rc=$rc): $out"
out="$(FLEET="/claude-other\\tg:$K/git\\ta:$TMPD/ak-login" gen "$K/git" "$TMPD/ak-login" "$TMPD/f3.yml")"; rc=$?
(( rc == 0 )) && ! grep -q 'container claude-other' <<<"$out" \
    && ok "a container with the same, separate inputs is not named" \
    || bad "a clean fleet must stay quiet (rc=$rc): $out"

# ======================================================================================
echo "== claude-launch: the same refusal before any container exists =="
mkdir -p "$TMPD/ws"
launch() {  # launch <git key> <authorized_keys>
    rm -f "$TMPD/run-args" "$TMPD/created"
    GIT_SSH_KEY="$1" SSH_AUTHORIZED_KEYS="$2" STUB_STATE="$TMPD" PATH="$STUBD:$PATH" \
        CLAUDE_PORTS_USED_OVERRIDE="" CLAUDE_GPU= \
        "$LAUNCH" keytest --workspace "$TMPD/ws" --port 2298 2>&1
}
out="$(launch "$K/git" "$TMPD/ak-both")"; rc=$?
(( rc != 0 )) && [[ ! -e "$TMPD/run-args" ]] && [[ "$out" == *"the git key is also an SSH login key"* ]] \
    && ok "claude-launch refuses a git key that is also a login key and runs no container" \
    || bad "claude-launch must refuse before docker run (rc=$rc): $out"
out="$(launch "$K/git" "$TMPD/ak-login")"; rc=$?
args="$(cat "$TMPD/run-args" 2>/dev/null)"
(( rc == 0 )) && grep -qxF "$K/git:/etc/claude/git-key:ro" <<<"$args" \
    && grep -qxF "$TMPD/ak-login:/etc/claude/authorized_keys:ro" <<<"$args" \
    && ok "claude-launch with separate keys mounts both, read-only" \
    || bad "claude-launch with separate keys must launch (rc=$rc): $out"

# ======================================================================================
echo "== entrypoint.sh §4, run in a sandbox: a root-only key directory, the git key refused =="
BLOCK4="$(awk '/^# --- 4\. Key inputs/{f=1} /^# --- 5\. /{exit} f' "$ENTRYPOINT")"
REAL_DIE="$(awk '/^die\(\)/{f=1} f{print; if (/\}[[:space:]]*$/) exit}' "$ENTRYPOINT")"
mkdir -p "$TMPD/bin"
# The one fake: whether the agent user can read a file, which the sandbox (one user, no root)
# cannot ask the kernel. AGENT_READS=1 answers yes. Any other gosu use runs the command.
cat > "$TMPD/bin/gosu" <<'STUB'
#!/usr/bin/env bash
shift
if [[ "${1:-}" == test && "${2:-}" == -r ]]; then [[ "${AGENT_READS:-0}" == 1 ]]; exit; fi
exec "$@"
STUB
chmod +x "$TMPD/bin/gosu"
b4() { printf '%s\n' "$BLOCK4" | sed -e "s#^KEYS_DIR=.*#KEYS_DIR=\"$1/etc-claude\"#" \
                                     -e "s#^AUTHKEYS_DST=.*#AUTHKEYS_DST=\"$1/home/.ssh/authorized_keys\"#" \
                                     -e "s#^REVOKED_KEYS=.*#REVOKED_KEYS=\"$1/revoked_keys\"#"; }
probe="$(b4 "$TMPD/probe")"
if [[ -n "$BLOCK4" && -n "$REAL_DIE" ]] && grep -qxF "KEYS_DIR=\"$TMPD/probe/etc-claude\"" <<<"$probe" \
   && grep -qxF "AUTHKEYS_DST=\"$TMPD/probe/home/.ssh/authorized_keys\"" <<<"$probe" \
   && grep -qxF "REVOKED_KEYS=\"$TMPD/probe/revoked_keys\"" <<<"$probe" \
   && ! grep -qE '^(KEYS_DIR|AUTHKEYS_DST|REVOKED_KEYS)=' <<<"$(grep -vF "$TMPD/probe" <<<"$probe")"; then
    ok "§4 extracted from entrypoint.sh, its three root-only paths pointed at a sandbox"
else
    bad "§4 did not extract, or its paths did not redirect: these tests would target /etc"
fi

# run4 <case> <git key file or -> <authorized_keys text or -> [VAR=VAL ...]: the shipped block
# under the entrypoint's shell options; prints the boot log and "rc=<n>" last.
run4() {
    local sb="$TMPD/$1" gk="$2" ak="$3"; shift 3
    rm -rf "$sb"; mkdir -p "$sb/etc-claude" "$sb/home/.ssh"; chmod 755 "$sb/etc-claude"
    [[ "$gk" == - ]] || cp "$gk" "$sb/etc-claude/git-key"
    [[ "$ak" == - ]] || printf '%s\n' "$ak" > "$sb/etc-claude/authorized_keys"
    local blk; blk="$(b4 "$sb")"
    ( unset CLAUDE_BROKER_GIT_KEY AGENT_READS
      export PATH="$TMPD/bin:$PATH" CLAUDE_USER="$(id -un)" CLAUDE_UID="$(id -u)" CLAUDE_GID="$(id -g)" \
             CLAUDE_HOME="$sb/home" GITKEY_SRC="$sb/etc-claude/git-key" AUTHKEYS_SRC="$sb/etc-claude/authorized_keys"
      if [[ $# -gt 0 ]]; then export "$@"; fi
      log() { echo "[entrypoint] $*"; }
      eval "$REAL_DIE"
      set -euo pipefail
      eval "$blk" ) 2>&1
    echo "rc=$?"
}
installed() { cat "$TMPD/$1/home/.ssh/authorized_keys" 2>/dev/null; }
revoked()   { cat "$TMPD/$1/revoked_keys" 2>/dev/null; }
GIT_PUB2="ssh-ed25519 $GIT_BLOB"

AK_BOTH="$(printf '# the owner\n%s\n%s' "$LOGIN_LINE" "$(cat "$K/git.pub")")"
out="$(run4 both "$K/git" "$AK_BOTH")"
[[ "$out" == *"rc=0"* ]] && ok "the default (brokered, agent cannot read the key) boots" || bad "§4 failed: $out"
[[ "$(stat -c %a "$TMPD/both/etc-claude")" == 700 ]] \
    && ok "the key directory is set to mode 700" || bad "§4 must chmod the key directory 700"
[[ "$(revoked both)" == "$GIT_PUB2" ]] \
    && ok "sshd's RevokedKeys file holds exactly the git key's public half" \
    || bad "RevokedKeys must hold the git key: '$(revoked both)'"
[[ "$(stat -c %a "$TMPD/both/revoked_keys")" == 644 ]] \
    && ok "the RevokedKeys file is mode 644 (written by root, which owns it)" \
    || bad "RevokedKeys mode: $(stat -c %a "$TMPD/both/revoked_keys")"
[[ "$(installed both)" == "$AK_BOTH" ]] \
    && [[ "$(stat -c '%u %a' "$TMPD/both/home/.ssh/authorized_keys")" == "$(id -u) 600" ]] \
    && ok "authorized_keys is installed as mounted, owned by the agent user, mode 600" \
    || bad "authorized_keys must be installed as mounted: $(installed both)"
[[ "$out" == *"GIT KEY IN AUTHORIZED_KEYS"* && "$out" == *"$GIT_FP"* ]] \
    && grep -q 'Installed authorized_keys for SSH (1 login key(s))' <<<"$out" \
    && grep -q "Git key for SSH     : refused for SSH logins here ($GIT_FP" <<<"$out" \
    && ok "the boot log names the git key in authorized_keys (fingerprint) and counts the login keys left" \
    || bad "the boot log must name the git key and count the login keys: $out"
! grep -q 'PRIVATE KEY' <<<"$out" && ! grep -qF "$(sed -n 2p "$K/git")" <<<"$out" \
    && ok "the boot log carries no private key material" || bad "the boot log printed private key material"

out="$(run4 opts "$K/git" "$(printf '%s\nrestrict,command="true" %s' "$LOGIN_LINE" "$(cat "$K/git.pub")")")"
[[ "$out" == *"GIT KEY IN AUTHORIZED_KEYS"* ]] && grep -q '(1 login key(s))' <<<"$out" \
    && ok "the git key behind options is found too" || bad "options hid the git key: $out"

out="$(run4 only "$K/git" "$(cat "$K/git.pub")")"
[[ "$out" == *"rc=0"* ]] && grep -q 'authorized_keys holds no login key sshd will accept' <<<"$out" \
    && [[ "$(revoked only)" == "$GIT_PUB2" ]] \
    && ok "only the git key mounted: SSH is said to be unusable, the key revoked, the boot goes on" \
    || bad "a git-key-only authorized_keys must warn and boot: $out"

out="$(run4 clean "$K/git" "$LOGIN_LINE")"
[[ "$out" == *"rc=0"* && "$(installed clean)" == "$LOGIN_LINE" && "$(revoked clean)" == "$GIT_PUB2" ]] \
    && ! grep -q 'GIT KEY IN AUTHORIZED_KEYS' <<<"$out" && grep -q '(1 login key(s))' <<<"$out" \
    && ok "separate keys: authorized_keys as given, the git key still revoked, no banner" \
    || bad "separate keys must install quietly and still revoke the git key: $out"

out="$(run4 nogit - "$(cat "$K/git.pub")")"
[[ "$out" == *"rc=0"* && -e "$TMPD/nogit/revoked_keys" && -z "$(revoked nogit)" ]] \
    && [[ "$(installed nogit)" == "$(cat "$K/git.pub")" ]] && ! grep -q 'GIT KEY\|derive' <<<"$out" \
    && ok "no git key mounted: an EMPTY RevokedKeys file still exists (sshd needs it), keys as given" \
    || bad "without a git key RevokedKeys must exist and be empty: $out"

out="$(run4 locked "$K/locked" "$(cat "$K/locked.pub")")"
[[ "$out" == *"rc=0"* && -e "$TMPD/locked/revoked_keys" && -z "$(revoked locked)" ]] \
    && grep -q "could not derive the git key's public half" <<<"$out" \
    && ok "a git key whose public half cannot be derived: not revoked, and said so" \
    || bad "an underivable git key must warn: $out"

out="$(run4 noak "$K/git" -)"
[[ "$out" == *"rc=0"* && "$(revoked noak)" == "$GIT_PUB2" ]] && grep -q 'no authorized_keys mounted' <<<"$out" \
    && ok "no authorized_keys mounted: the old warning, the git key still revoked" || bad "no authorized_keys: $out"

# FAIL CLOSED: a key to be brokered that the agent user could still read off the mount.
for v in unset 1 O; do
    if [[ "$v" == unset ]]; then out="$(run4 "readable-$v" "$K/git" "$LOGIN_LINE" AGENT_READS=1)"
    else out="$(run4 "readable-$v" "$K/git" "$LOGIN_LINE" AGENT_READS=1 "CLAUDE_BROKER_GIT_KEY=$v")"; fi
    [[ "$out" != *"rc=0"* && "$out" == *"is readable by"* && "$out" == *"CLAUDE_BROKER_GIT_KEY=0"* ]] \
        && [[ ! -e "$TMPD/readable-$v/home/.ssh/authorized_keys" ]] \
        && ok "CLAUDE_BROKER_GIT_KEY=$v and a key the agent can read: the boot stops before the agent" \
        || bad "CLAUDE_BROKER_GIT_KEY=$v with an agent-readable key must stop the boot: $out"
done
for v in 0 false no off; do
    out="$(run4 "optout-$v" "$K/git" "$LOGIN_LINE" AGENT_READS=1 "CLAUDE_BROKER_GIT_KEY=$v")"
    [[ "$out" == *"rc=0"* && "$(revoked "optout-$v")" == "$GIT_PUB2" ]] \
        && ok "CLAUDE_BROKER_GIT_KEY=$v (a readable key by choice) boots, the git key still refused for SSH" \
        || bad "the explicit opt-out $v must not be stopped: $out"
done

# ======================================================================================
echo "== the image and the order of the boot =="
grep -qxF 'RUN install -d -o root -g root -m 700 /etc/claude' "$REPO_ROOT/Dockerfile" \
    && ok "the image bakes /etc/claude root-owned, mode 700 (protected before the entrypoint runs)" \
    || bad "the Dockerfile must create /etc/claude root-owned, mode 700"
n4="$(grep -n '^# --- 4\. Key inputs' "$ENTRYPOINT" | cut -d: -f1)"
n5="$(grep -n '^# --- 5\. Git SSH key' "$ENTRYPOINT" | cut -d: -f1)"
n12="$(grep -n '^# --- 12\. Launch Claude Code' "$ENTRYPOINT" | cut -d: -f1)"
[[ -n "$n4" && -n "$n5" && -n "$n12" ]] && (( n4 < n5 && n5 < n12 )) \
    && ok "§4 runs before the broker (§5) and before any session starts (§12)" \
    || bad "§4 must come before §5 and §12 (lines: $n4 $n5 $n12)"
grep -qxF 'RUN install -o root -g root -m 644 /dev/null /etc/ssh/revoked_keys' "$REPO_ROOT/Dockerfile" \
    && grep -qxF 'RevokedKeys /etc/ssh/revoked_keys' "$REPO_ROOT/sshd_config" \
    && ok "sshd_config names the RevokedKeys file, and the image bakes it empty (sshd never starts without it)" \
    || bad "sshd_config must set RevokedKeys /etc/ssh/revoked_keys and the Dockerfile bake it"
grep -q 'Deploy key readable : NO. .*root-only directory' "$ENTRYPOINT" \
    && ok "the brokered boot log line names the root-only directory" \
    || bad "the 'Deploy key readable : NO' line must say the mounted key is in a root-only directory"

echo
echo "keys-unit: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
