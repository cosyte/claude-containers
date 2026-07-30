# Interactive SSH logins attach to the live 'claude' tmux session so a
# disconnect never kills Claude Code. Non-interactive SSH (scp/sftp/rsync,
# `ssh host cmd`) is left alone.
[ -f ~/.bashrc ] && . ~/.bashrc

# Disk-backed TMPDIR. The container's env carries TMPDIR=/scratch, and the tmux session
# inherits it from PID 1, but sshd builds a FRESH environment, so an SSH login (and any
# `ssh host cmd`) would silently fall back to /tmp, a 1g tmpfs in RAM, and a big pip/npm
# install run by hand would die with ENOSPC while the session's own installs succeed.
# Re-export it here so both paths behave the same. Guarded on the dir existing, so this
# stays correct on a container launched without the scratch volume.
[ -d /scratch ] && export TMPDIR=/scratch

if [[ $- == *i* && -z "${TMUX:-}" && -z "${CLAUDE_NO_TMUX:-}" ]]; then
    if tmux has-session -t claude 2>/dev/null; then
        exec tmux attach-session -t claude
    else
        exec tmux new-session -s claude /usr/local/bin/claude-session
    fi
fi
