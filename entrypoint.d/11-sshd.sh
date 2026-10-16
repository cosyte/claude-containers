# shellcheck shell=bash
# --- 11. Start sshd ----------------------------------------------------------
/usr/sbin/sshd -e
log "sshd listening on container port 22"
