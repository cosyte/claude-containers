# shellcheck shell=bash
# --- 2. Fix ownership of mounted volumes -------------------------------------
mkdir -p "$AUTH_DIR" "$HOSTKEY_DIR" "$WORKSPACE"
# The config dir and ~/.ssh are in the agent's home (the config dir is a volume in a stack, a
# plain directory in a bare `docker run`): the agent makes them, removes a link at ~/.ssh, and
# root never creates or removes by a name there. (An operator's CLAUDE_CONFIG_DIR outside the
# agent's home, where the agent cannot make it, root makes: no agent can write where it goes.)
if ! as_agent mkdir -p "$CLAUDE_CONFIG_DIR" 2>/dev/null; then
    [[ "$CLAUDE_CONFIG_DIR/" != "$CLAUDE_HOME/"* ]] && mkdir -p "$CLAUDE_CONFIG_DIR" \
        || die "could not make the config dir $CLAUDE_CONFIG_DIR"
fi
# ~/.ssh is agent-owned and lives in the container layer, so a session can replace it with a
# symlink that survives a restart. Remove a symlink here (never follow it) before the real
# directory is made again; a real ~/.ssh is left as is. [[ -L ]] tests the link itself.
[[ -L "$CLAUDE_HOME/.ssh" ]] && as_agent rm -f "$CLAUDE_HOME/.ssh"
as_agent mkdir -p "$CLAUDE_HOME/.ssh"
own_tree "$CLAUDE_CONFIG_DIR" "$CLAUDE_HOME/.ssh"
chown "$CLAUDE_UID:$CLAUDE_GID" "$WORKSPACE" 2>/dev/null || true
# Its mode by the agent itself (as_agent): ~/.ssh is an entry in the agent's home, so a root
# chmod by that name would follow a symlink swapped in after the check above.
as_agent chmod 700 "$CLAUDE_HOME/.ssh"
