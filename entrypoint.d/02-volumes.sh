# shellcheck shell=bash
# --- 2. Fix ownership of mounted volumes -------------------------------------
mkdir -p "$CLAUDE_CONFIG_DIR" "$AUTH_DIR" "$HOSTKEY_DIR" "$WORKSPACE"
# ~/.ssh is agent-owned and lives in the container layer, so a session can replace it with a
# symlink that survives a restart. The root mkdir/chmod below would then act on the link's
# target, not on ~/.ssh. Remove a symlink here (never follow it) before recreating the real
# directory; a real ~/.ssh is left as is. [[ -L ]] tests the link itself, rm -f unlinks it.
[[ -L "$CLAUDE_HOME/.ssh" ]] && rm -f "$CLAUDE_HOME/.ssh"
mkdir -p "$CLAUDE_HOME/.ssh"
own_tree "$CLAUDE_CONFIG_DIR" "$CLAUDE_HOME/.ssh"
chown "$CLAUDE_UID:$CLAUDE_GID" "$WORKSPACE" 2>/dev/null || true
chmod 700 "$CLAUDE_HOME/.ssh"
