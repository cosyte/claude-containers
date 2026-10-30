# shellcheck shell=bash
# --- 2e. KVM (CLAUDE_KVM=1, a --kvm session) ------------------------------------------------
# A --kvm session has the host's /dev/kvm, with the host's group id on it, so a hardware-
# accelerated emulator can run as the agent. Put the agent in the group that owns the device:
# the container's /etc/group, never a compose group_add, since gosu and SSH logins take their
# groups from it. /etc/group is in the container layer, so this is idempotent across restarts.
# Never root's group 0. A device that is missing or still unusable DEGRADES the session loudly
# and never stops the boot: everything else works, and emulators run without acceleration.
# KVM_DEV is named (not inlined), and stat, getent, groupadd, usermod, asclaude and log are
# called by name, so test/kvm-unit.sh can run this exact block unprivileged against stubs.
KVM_DEV=/dev/kvm
if [[ "${CLAUDE_KVM:-0}" =~ ^(1|true|yes|on)$ ]]; then
    if [[ ! -c "$KVM_DEV" ]]; then
        log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        log "KVM MISSING: $KVM_DEV is not a character device"
        log "This --kvm session is starting WITHOUT KVM. Everything else works, and emulators"
        log "run without acceleration until the host is fixed (KVM enabled in the BIOS, the"
        log "kvm_intel or kvm_amd module loaded) and this container is recreated."
        log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    else
        # `|| ...` keeps every failure here from tripping `set -e`: the check below reports it.
        kvm_gid="$(stat -c %g "$KVM_DEV")" || kvm_gid=""
        kvm_name=""
        if [[ "$kvm_gid" == 0 ]]; then
            log "KVM: $KVM_DEV is owned by group 0; the agent is not added to root's group"
        elif [[ -n "$kvm_gid" && "$kvm_gid" != "$CLAUDE_GID" ]]; then
            kvm_name="$(getent group "$kvm_gid" | cut -d: -f1)" || kvm_name=""
            if [[ -z "$kvm_name" ]]; then
                if getent group kvm >/dev/null; then kvm_name=claude-kvm; else kvm_name=kvm; fi
                groupadd -g "$kvm_gid" "$kvm_name" || log "KVM: groupadd -g $kvm_gid $kvm_name failed"
            fi
            usermod -aG "$kvm_name" "$CLAUDE_USER" || log "KVM: usermod -aG $kvm_name $CLAUDE_USER failed"
        fi
        if asclaude test -r "$KVM_DEV" -a -w "$KVM_DEV"; then
            log "KVM                 : ok ($KVM_DEV, group ${kvm_name:-$kvm_gid})"
        else
            log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            log "KVM UNUSABLE: the agent cannot read and write $KVM_DEV (group ${kvm_gid:-unknown})"
            log "This --kvm session is starting WITHOUT KVM. Everything else works, and emulators"
            log "run without acceleration. A device owned by group 0, or a rootless or userns-"
            log "remapped Docker that maps its group to nogroup, cannot be shared with the agent."
            log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        fi
        unset kvm_gid kvm_name
    fi
fi
