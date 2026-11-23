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
