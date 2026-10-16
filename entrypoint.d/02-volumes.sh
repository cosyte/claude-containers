# shellcheck shell=bash
# --- 2. Fix ownership of mounted volumes -------------------------------------
mkdir -p "$CLAUDE_CONFIG_DIR" "$AUTH_DIR" "$HOSTKEY_DIR" "$CLAUDE_HOME/.ssh" "$WORKSPACE"
own_tree "$CLAUDE_CONFIG_DIR" "$CLAUDE_HOME/.ssh"
chown "$CLAUDE_UID:$CLAUDE_GID" "$WORKSPACE" 2>/dev/null || true
chmod 700 "$CLAUDE_HOME/.ssh"
