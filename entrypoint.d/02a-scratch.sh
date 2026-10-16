# shellcheck shell=bash
# --- 2a. Disk-backed scratch (TMPDIR) ----------------------------------------
# /tmp is a tmpfs: RAM, ~1g, charged to the memory cgroup. With TMPDIR unset everything
# large lands there: pip/uv wheel builds, big archives, compiler temp files, and dies at
# the cap with an ENOSPC that reads like a bug, while the host has terabytes free. So point
# TMPDIR at a disk-backed volume. TMPDIR is exported by the launcher/compose (so every
# child inherits it); this block just makes the directory usable, and tolerates its
# absence so an older container (or a plain `docker run` of this image) still boots with
# the historical /tmp behaviour.
SCRATCH_DIR="${TMPDIR:-}"
if [[ -n "$SCRATCH_DIR" && "$SCRATCH_DIR" != "/tmp" ]]; then
    if mkdir -p "$SCRATCH_DIR" 2>/dev/null; then
        # 1777 like /tmp: the agent is unprivileged, but root writes here too.
        chown "$CLAUDE_UID:$CLAUDE_GID" "$SCRATCH_DIR" 2>/dev/null || true
        chmod 1777 "$SCRATCH_DIR" 2>/dev/null || true
        # Clear stale contents on boot. This is scratch, not state: a volume (unlike a tmpfs)
        # survives restarts, so without this it accumulates every abandoned wheel build and
        # half-written tarball forever, and slowly fills the pool. Deleting only at boot means
        # nothing in flight is ever pulled out from under a running process.
        find "$SCRATCH_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
        # Say what it really is: --browser and --gpu services mount a RAM tmpfs here.
        if [[ "$(stat -f -c %T "$SCRATCH_DIR" 2>/dev/null)" == tmpfs ]]; then
            log "Scratch (TMPDIR)    : $SCRATCH_DIR (RAM tmpfs, $(df -h --output=size "$SCRATCH_DIR" 2>/dev/null | tail -1 | tr -d ' '); cleared on boot)"
        else
            log "Scratch (TMPDIR)    : $SCRATCH_DIR (disk-backed; cleared on boot)"
        fi
    else
        log "WARNING: TMPDIR=$SCRATCH_DIR is not creatable, falling back to /tmp (a 1g tmpfs)."
        log "WARNING: Large installs/builds may fail with ENOSPC. Mount a scratch volume there."
        unset TMPDIR
    fi
fi
