# shellcheck shell=bash
# --- 3. SSH host keys (persistent) -------------------------------------------
if [[ ! -f "$HOSTKEY_DIR/ssh_host_ed25519_key" ]]; then
    log "Generating persistent SSH host keys"
    ssh-keygen -q -t ed25519 -f "$HOSTKEY_DIR/ssh_host_ed25519_key" -N ''
    ssh-keygen -q -t rsa -b 4096 -f "$HOSTKEY_DIR/ssh_host_rsa_key" -N ''
fi
chmod 600 "$HOSTKEY_DIR"/ssh_host_*_key
chmod 644 "$HOSTKEY_DIR"/ssh_host_*_key.pub
