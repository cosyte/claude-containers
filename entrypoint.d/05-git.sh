# shellcheck shell=bash
# --- 5. Git SSH key + identity -----------------------------------------------
# A mounted deploy key is BROKERED BY DEFAULT: it is loaded into a ROOT-owned
# ssh-agent and only a relay socket is exposed to the claude user, so git can
# sign/push with the key while the unprivileged (prompt-injectable) agent can
# never read the private key bytes and so cannot exfiltrate it. An operator who
# needs the historical readable ~/.ssh/id_ed25519 opts OUT explicitly with
# CLAUDE_BROKER_GIT_KEY=0. Either way the key is never baked into the image.
#
# THE VALUE RULE, and why it is written as "opt out" rather than "opt in":
# only a RECOGNISED disabling value (0/false/no/off) selects the readable file.
# Unset brokers, an enabling value brokers, and anything unrecognised (a typo,
# an empty value, "yes please") ALSO brokers. Containment must never be
# downgraded by a value nobody meant, so the fallible direction is the safe one.
#
# FAIL CLOSED. When brokering is engaged and cannot be established there is NO
# readable-file fallback: no key file is installed, git is left unable to
# authenticate with that key for this boot, and the failure is logged loudly.
# A failed push is recoverable; an exfiltrated deploy key is not. Only an
# operator who explicitly recorded CLAUDE_BROKER_GIT_KEY=0 ever gets a readable
# key file.
#
# Every path below (brokered, readable file, broker failed, no key mounted)
# ends with a "Deploy key readable :" line stating in plain language whether the
# agent user can read the key right now, so an operator scanning the boot log
# never has to infer it from which other line appeared.
#
# BROKER_RUN_DIR / BROKER_PROFILE_D are named here rather than inlined below
# because they are the two ROOT-ONLY paths in this section: naming them lets
# test/unit.sh run this exact block, unmodified in every decision it makes,
# against a sandbox instead of needing root.
git_brokered=0                                            # outcome flag; test/unit.sh reads it
BROKER_RUN_DIR="/run/claude"                              # root-owned socket dir
BROKER_PROFILE_D="/etc/profile.d/claude-ssh-agent.sh"     # login-shell SSH_AUTH_SOCK export
if [[ -s "$GITKEY_SRC" ]]; then
    # ~/.ssh is a real agent-owned directory by here (§2 removed any symlink at it). Its
    # entries are still the agent's, though, so remove a symlink the agent may have left at
    # config before writing, or the root `cat >`/`chown`/`chmod` below would act on its
    # target. rm -f unlinks a symlink without following it; `cat >` then creates a fresh file.
    rm -f "$CLAUDE_HOME/.ssh/config"
    cat > "$CLAUDE_HOME/.ssh/config" <<EOF
Host *
    StrictHostKeyChecking accept-new
    UserKnownHostsFile ~/.ssh/known_hosts
EOF
    if [[ "${CLAUDE_BROKER_GIT_KEY:-}" =~ ^(0|false|no|off)$ ]]; then
        # THE EXPLICIT OPT-OUT, and the only path that writes a readable key.
        # Drop any relay export a previous brokered boot of THIS container left
        # in /etc/profile.d: `docker restart` keeps the container filesystem, so
        # without this a login shell would point SSH_AUTH_SOCK at a dead socket.
        rm -f "$BROKER_PROFILE_D"
        # Unlink first, never follow: install would otherwise copy the key through a symlink
        # the agent may have planted at id_ed25519, writing the private bytes to its target.
        rm -f "$CLAUDE_HOME/.ssh/id_ed25519"
        install -o "$CLAUDE_UID" -g "$CLAUDE_GID" -m 600 \
            "$GITKEY_SRC" "$CLAUDE_HOME/.ssh/id_ed25519"
        printf 'Host *\n    IdentityFile ~/.ssh/id_ed25519\n' >> "$CLAUDE_HOME/.ssh/config"
        log "Git SSH key         : installed as a readable file at ~/.ssh/id_ed25519 (CLAUDE_BROKER_GIT_KEY=${CLAUDE_BROKER_GIT_KEY} opt-out)"
        log "Deploy key readable : YES. The agent user can read this deploy key's private bytes (mode 600, owned by $CLAUDE_USER). Unset CLAUDE_BROKER_GIT_KEY to broker it instead."
    else
        # Key lives only in a ROOT ssh-agent's memory (+ the root-only mounted
        # key file). ssh-agent rejects cross-uid peers, so a root socat relay
        # exposes a claude-usable socket and forwards to the root agent: claude
        # signs through it (git push works) but can neither extract the key
        # (agent protocol never returns private keys) nor read root's memory.
        #
        # FIRST, delete any readable key file an EARLIER boot of this same
        # container installed. `docker restart` keeps the container filesystem,
        # so a container that once ran with CLAUDE_BROKER_GIT_KEY=0 and is
        # restarted without it would otherwise broker the key AND leave the old
        # agent-readable copy sitting in ~/.ssh. Brokering has to mean the bytes
        # are gone from the agent's home, not merely that this boot did not add
        # them. (The ssh config was rewritten from scratch above, so its
        # IdentityFile line is already gone.)
        rm -f "$CLAUDE_HOME/.ssh/id_ed25519" "$CLAUDE_HOME/.ssh/id_ed25519.pub"
        mkdir -p "$BROKER_RUN_DIR" && chmod 711 "$BROKER_RUN_DIR"
        AGENT_SOCK="$BROKER_RUN_DIR/agent-root.sock"     # root-only
        CLAUDE_SOCK="$BROKER_RUN_DIR/agent.sock"         # claude-usable, via relay
        rm -f "$AGENT_SOCK" "$CLAUDE_SOCK"
        if ssh-agent -a "$AGENT_SOCK" >/dev/null 2>&1; then
            for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -S "$AGENT_SOCK" ]] && break; sleep 0.2; done
        fi
        if [[ -S "$AGENT_SOCK" ]] && SSH_AUTH_SOCK="$AGENT_SOCK" ssh-add "$GITKEY_SRC" >/dev/null 2>&1; then
            socat "UNIX-LISTEN:$CLAUDE_SOCK,fork,mode=0600,user=$CLAUDE_USER" \
                  "UNIX-CONNECT:$AGENT_SOCK" >/dev/null 2>&1 &
            for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -S "$CLAUDE_SOCK" ]] && break; sleep 0.2; done
        fi
        if [[ -S "$CLAUDE_SOCK" ]]; then
            chmod 600 "$AGENT_SOCK" 2>/dev/null || true     # keep the real agent root-only
            export SSH_AUTH_SOCK="$CLAUDE_SOCK"
            printf 'export SSH_AUTH_SOCK=%s\n' "$CLAUDE_SOCK" > "$BROKER_PROFILE_D"
            # shellcheck disable=SC2034  # outcome flag, read by test/unit.sh
            git_brokered=1
            log "Git SSH key broker  : key held in a root ssh-agent (claude signs via relay, cannot read it)"
            log "Deploy key readable : NO. The agent user cannot read this deploy key's private bytes: the mounted key is in a root-only directory (§4), no key file exists under $CLAUDE_HOME, and signing happens inside a root-owned ssh-agent."
        else
            # FAIL CLOSED: no readable-file fallback, ever. Loud, because the
            # operator's git pushes over this key will now fail and the reason
            # has to be on the first screen of `docker logs`.
            rm -f "$AGENT_SOCK" "$CLAUDE_SOCK" "$BROKER_PROFILE_D"
            log "Git SSH key broker  : ERROR, the ssh-agent/relay could not be established."
            log "Git SSH key broker  : ERROR, NOT falling back to a readable key file. git cannot authenticate with this deploy key for this boot."
            log "Git SSH key broker  : ERROR, set CLAUDE_BROKER_GIT_KEY=0 to accept an agent-readable key instead, then restart the container."
            log "Deploy key readable : NO. The agent user cannot read this deploy key's private bytes: brokering failed and no key file was installed, so git has no key to authenticate with."
        fi
    fi
    # config was just created fresh above (symlink removed), so it is a regular file; -h keeps
    # chown off a link's target regardless, and chmod acts on that same fresh regular file.
    chown -h "$CLAUDE_UID:$CLAUDE_GID" "$CLAUDE_HOME/.ssh/config"
    chmod 600 "$CLAUDE_HOME/.ssh/config"
else
    log "No git SSH key mounted at $GITKEY_SRC (https/public repos still work)"
    log "Deploy key readable : n/a, no deploy key is mounted, so there is nothing to read."
fi

# Git identity: env vars win; otherwise inherit whatever the launcher passed
# from the host's git config. Applied to the claude user's global config.
git_id() {
    local k="$1" v="$2"
    [[ -n "$v" ]] && asclaude git config --global "$k" "$v" || true
}
git_id user.name  "${GIT_AUTHOR_NAME:-}"
git_id user.email "${GIT_AUTHOR_EMAIL:-}"
# safe.directory is multi-valued: `--add` every boot would append a duplicate
# line per restart. Add it only if it isn't already present.
asclaude git config --global --get-all safe.directory 2>/dev/null \
    | grep -qxF "$WORKSPACE" \
    || asclaude git config --global --add safe.directory "$WORKSPACE" || true
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

# Secret guard: a fleet-wide pre-commit hook (global core.hooksPath) that blocks
# committing obvious secrets/credentials: important because the agent commits
# and pushes autonomously with a mounted key and one shared credential volume.
# Disable with CLAUDE_SECRET_GUARD=0. The hook chains to a repo's own pre-commit.
HOOKS_DIR="$CLAUDE_HOME/.claude-hooks"
case "${CLAUDE_SECRET_GUARD:-1}" in
    0|false|no|off)
        asclaude git config --global --unset core.hooksPath 2>/dev/null || true
        log "Secret guard         : disabled (CLAUDE_SECRET_GUARD=0)" ;;
    *)
        # ~/.claude-hooks is agent-owned; drop a symlink the agent may have left at it (never
        # follow it) so the root `ln -sf` below plants pre-commit in the real directory.
        [[ -L "$HOOKS_DIR" ]] && rm -f "$HOOKS_DIR"
        asclaude mkdir -p "$HOOKS_DIR"
        ln -sf /usr/local/bin/claude-secret-guard "$HOOKS_DIR/pre-commit"
        chown -h "$CLAUDE_UID:$CLAUDE_GID" "$HOOKS_DIR/pre-commit" 2>/dev/null || true
        asclaude git config --global core.hooksPath "$HOOKS_DIR"
        log "Secret guard         : on (blocks committing secrets; bypass with git commit --no-verify)" ;;
esac

# GitHub HTTPS auth (dynamic, additive): when GH_TOKEN is supplied, wire the
# `gh` CLI in as git's credential helper for github.com so HTTPS clone/push
# also work with the token. SSH remotes keep using the mounted deploy key, so
# a session can use either transport. `gh auth setup-git` resets the helper
# before re-adding its own, so running it on every boot stays idempotent.
if [[ -n "${GH_TOKEN:-}" ]]; then
    if asclaude gh auth setup-git --hostname github.com >/dev/null 2>&1; then
        log "GH_TOKEN set: gh wired in as git credential helper (HTTPS + SSH both usable)"
    else
        log "WARNING: 'gh auth setup-git' failed; HTTPS git auth via GH_TOKEN unavailable"
    fi
else
    log "No GH_TOKEN: git uses the SSH deploy key only; gh CLI is unauthenticated"
fi
