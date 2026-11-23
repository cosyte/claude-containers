# shellcheck shell=bash
# --- 0a. Root and the agent's files --------------------------------------------
# Root never acts by name in a directory the agent can write (its config dir, ~/.ssh, the CLI's
# prefix): between any two of root's steps on a name there (create, write, chown, chmod, read),
# a session can rename a symlink over it, and root would follow it to any file in the container.
# So the agent reads and writes there itself, and the kernel checks each path against the
# agent's own rights. as_agent runs a command as the agent user (its uid and groups) on root's
# system-only PATH: system tools, never one from a directory the agent can write. Root hands
# content over on stdin (agent_put) and takes it back on stdout (agent_cat), through pipes,
# never a here-string or here-document: bash keeps one bigger than a pipe in a temp file under
# TMPDIR, which is the agent's /scratch, and opens it again by name.
as_agent() { gosu "$CLAUDE_USER" "$@"; }
# agent_cat <file>: the regular file at <file>, as the agent reads it; fails when it cannot.
agent_cat() { as_agent sh -c '[ -f "$1" ] && exec cat -- "$1"' agent_cat "$1"; }
# agent_put <file> <mode>: stdin becomes <file>, the agent's own: a fresh temp file beside it,
# renamed onto the name itself (mv -T), so a reader never sees it half-written.
agent_put() {
    as_agent sh -c 't="$(mktemp "$1.XXXXXX")" || exit 1
        cat > "$t" && chmod "$2" "$t" && mv -fT "$t" "$1" && exit 0
        rm -f "$t"; exit 1' agent_put "$1" "$2"
}
# lock_master <dir> [fresh]: a credential master (an auth volume's root) root's, mode 700, then
# its two files root's, mode 600. First the directory: once it is root's (this process's own uid,
# root's in a container), no agent can change what is in it, and nothing else runs until it is.
# Then each name: anything that is not a regular file (a link, a FIFO, a directory) is removed,
# never followed or opened (only a login writes these names), and so is a file over 1 MiB (a
# master is a few KB; copying a huge sparse file would fill the disk). A file root does not own,
# or with a second hard link, is written again as a new file of root's (root_put), its mtime kept
# (the credential sync compares it), so a descriptor the agent opened while it was the agent's
# writes nowhere. With `fresh` (once, at a start or a login) every file is written again, also one
# an older image's lock made root's in place. Modes are set with a leading 00, which also clears a
# setgid or setuid bit. Checked first, so a master that is already right is not touched. The
# names are handled under the master's lock (with_master_lock), so a rewrite never undoes a login
# or a credential sync that writes meanwhile, and a copy is bounded to 1 MiB whatever happens to
# the file between its stat and the copy.
lock_master() {
    local f p u h a s m
    if [[ "$(stat -c '%u %a' "$1" 2>/dev/null)" != "$EUID 700" ]]; then
        chown root:root "$1" 2>/dev/null || true
        chmod 00700 "$1" 2>/dev/null || true
        [[ "$(stat -c '%u %a' "$1" 2>/dev/null)" == "$EUID 700" ]] || return 0
    fi
    _lock_master_names() {
        for f in .credentials.json .claude.json; do
            p="$1/$f"
            if [[ -L "$p" ]] || { [[ -e "$p" ]] && [[ ! -f "$p" ]]; }; then
                rm -rf -- "$p" 2>/dev/null || true
            elif [[ -f "$p" ]]; then
                read -r u h a s m < <(stat -c '%u %h %a %s %.9Y' "$p" 2>/dev/null) || continue
                if (( s > 1048576 )); then
                    rm -f -- "$p" 2>/dev/null || true
                    log "WARNING: $p was over 1 MiB, not a credential master: removed"
                elif [[ "$u" != 0 || "$h" != 1 || "${2:-}" == fresh ]]; then
                    root_put "$p" "$m" < <(head -c 1048576 -- "$p") || true
                elif [[ "$a" != 600 ]]; then
                    chmod 00600 "$p" 2>/dev/null || true
                fi
            fi
        done
    }
    with_master_lock "$1" _lock_master_names "$@" || true
    return 0
}
# with_master_lock <dir> <command...>: the command under an exclusive lock on the master's
# directory (flock; it holds across every container on this host that mounts the volume), so
# no two writes of a master interleave: a login, a credential sync, a rewrite. The directory is
# locked, not a file in it, so no name an older login left there is ever opened. Bounded: a
# lock not had in 30 s is a failed command, never a boot that waits for ever.
with_master_lock() {
    local d="$1"; shift
    ( flock -x -w 30 9 || exit 1; "$@" ) 9<"$d"
}
# root_put <file> [mtime]: stdin becomes <file>, root's own, mode 600, in a directory root keeps
# (the credential masters), with that mtime if one is given. Its temp file is created exclusively
# (dd conv=excl opens no name that exists, a symlink included), given its mtime, and renamed onto
# the name: root never reopens a name there, and no reader ever sees it with another mtime.
root_put() {
    local t; t="$(mktemp -u "$1.XXXXXX")" || return 1
    if ( umask 077; dd of="$t" conv=excl status=none 2>/dev/null ) \
       && { [[ -z "${2:-}" ]] || touch -h -d "@$2" "$t"; } && mv -fT "$t" "$1"; then
        return 0
    fi
    rm -f "$t"
    return 1
}
