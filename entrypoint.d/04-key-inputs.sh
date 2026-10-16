# shellcheck shell=bash
# --- 4. Key inputs: a root-only directory, and the git key refused for SSH ---
# The host mounts two key inputs into $KEYS_DIR, read-only: authorized_keys (the owner's SSH
# login keys) and git-key (the private key git pushes with, §5). A bind mount keeps the HOST
# file's owner and mode, and on a single-user host that owner's UID is the agent's (1000), so a
# key the owner keeps at 0600 would be readable by the agent straight off the mount. The
# DIRECTORY stops that: root-owned, mode 700, baked so in the image and re-asserted here before
# any agent process starts. Opening a path needs search permission on every directory in it,
# so the agent cannot open either file whatever their own owner and mode. Root (this script
# and the broker) still reads them; the agent gets its copy of authorized_keys below and the
# broker's relay socket (§5), never the key file.
#
# FAIL CLOSED: a key that is to be brokered but that the agent user can still read is not
# brokered at all, so the boot stops here, before the agent exists. That happens when
# $KEYS_DIR is not the image's root-only directory, e.g. a whole host directory mounted on it.
# Only the explicit CLAUDE_BROKER_GIT_KEY=0 opt-out (a readable key by choice) passes.
#
# THE GIT KEY IS NEVER A LOGIN KEY. Every session can sign with it through its agent (§5), so
# a container that accepts it for SSH logins can be entered from every session that holds it,
# in any container. claude-launch and claude-compose-gen refuse a configuration that names one
# key for both. Here sshd refuses it whatever any authorized_keys file says: its public half is
# written to $REVOKED_KEYS, sshd_config's RevokedKeys, which is root's alone (the agent owns
# its authorized_keys and could add the key back; it cannot touch this file). The file is
# written on every boot, empty without a git key: sshd refuses ALL public-key logins when it
# cannot read it. A git key that is also in authorized_keys is named in the boot log.
#
# KEYS_DIR, AUTHKEYS_DST and REVOKED_KEYS are named on their own lines so test/keys-unit.sh can
# run this exact block unprivileged against a sandbox.
KEYS_DIR="/etc/claude"
AUTHKEYS_DST="$CLAUDE_HOME/.ssh/authorized_keys"
REVOKED_KEYS="/etc/ssh/revoked_keys"
chmod 700 "$KEYS_DIR" 2>/dev/null || log "WARNING: could not set $KEYS_DIR to mode 700"
gitkey_pub=""
gitkey_fp=""
if [[ -s "$GITKEY_SRC" ]]; then
    if [[ ! "${CLAUDE_BROKER_GIT_KEY:-}" =~ ^(0|false|no|off)$ ]] \
       && gosu "$CLAUDE_USER" test -r "$GITKEY_SRC" 2>/dev/null; then
        die "the git key at $GITKEY_SRC is readable by $CLAUDE_USER, so brokering it would not keep it from the agent.
       $KEYS_DIR must be the image's root-only directory (here: $(stat -c 'owner %U, mode %a' "$KEYS_DIR" 2>/dev/null)).
       Mount the key FILE at $GITKEY_SRC, never a host directory at $KEYS_DIR.
       CLAUDE_BROKER_GIT_KEY=0 accepts an agent-readable key instead."
    fi
    # Its public half ("type key"), derived as root from the key itself. -P '' never prompts:
    # a passphrase-protected key gives nothing, and the broker cannot load one either.
    gitkey_pub="$(ssh-keygen -y -P '' -f "$GITKEY_SRC" 2>/dev/null </dev/null \
        | awk 'NR == 1 && $2 ~ /^AAAA/ { print $1, $2 }' || true)"
    gitkey_fp="$(ssh-keygen -lf - <<<"$gitkey_pub" 2>/dev/null | awk '{ print $2; exit }' || true)"
    if [[ -n "$gitkey_pub" ]]; then
        log "Git key for SSH     : refused for SSH logins here ($gitkey_fp, sshd RevokedKeys)"
    else
        log "WARNING: could not derive the git key's public half (passphrase-protected?), so sshd"
        log "WARNING: here is not told to refuse it for SSH logins."
    fi
fi
install -m 644 <(if [[ -n "$gitkey_pub" ]]; then printf '%s\n' "$gitkey_pub"; fi) "$REVOKED_KEYS"
if [[ -s "$AUTHKEYS_SRC" ]]; then
    install -o "$CLAUDE_UID" -g "$CLAUDE_GID" -m 600 "$AUTHKEYS_SRC" "$AUTHKEYS_DST"
    # Fingerprints, as sshd reads the file: options, cert-authority, every key-type name.
    authkeys_fps="$(ssh-keygen -lf "$AUTHKEYS_DST" 2>/dev/null | awk '{ print $2 }' || true)"
    authkeys_n="$(grep -c . <<<"$authkeys_fps" || true)"
    authkeys_git=0
    [[ -z "$gitkey_fp" ]] || authkeys_git="$(grep -cxF -- "$gitkey_fp" <<<"$authkeys_fps" || true)"
    if (( authkeys_git > 0 )); then
        log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        log "GIT KEY IN AUTHORIZED_KEYS: the git key ($gitkey_fp) is also in the mounted"
        log "authorized_keys. Every session signs with the git key through its agent, so a container"
        log "that accepts it for SSH can be entered from every session. sshd here refuses it (see"
        log "above), but keep it out: put only your own login keys in SSH_AUTHORIZED_KEYS, never"
        log "the git key's public half. How: docs/security-notes.md, SSH keys."
        log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    fi
    if (( authkeys_n - authkeys_git > 0 )); then
        log "Installed authorized_keys for SSH ($(( authkeys_n - authkeys_git )) login key(s))"
    else
        log "WARNING: authorized_keys holds no login key sshd will accept: SSH will be unusable;"
        log "         Remote Control still works."
    fi
else
    log "WARNING: no authorized_keys mounted at $AUTHKEYS_SRC"
    log "         SSH will be unusable; Remote Control still works."
fi
unset gitkey_pub gitkey_fp authkeys_fps authkeys_n authkeys_git
