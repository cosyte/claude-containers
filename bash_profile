# Interactive SSH logins attach to the live 'claude' tmux session so a
# disconnect never kills Claude Code. Non-interactive SSH (scp/sftp/rsync,
# `ssh host cmd`) is left alone.
[ -f ~/.bashrc ] && . ~/.bashrc

if [[ $- == *i* && -z "${TMUX:-}" && -z "${CLAUDE_NO_TMUX:-}" ]]; then
    if tmux has-session -t claude 2>/dev/null; then
        exec tmux attach-session -t claude
    else
        exec tmux new-session -s claude /usr/local/bin/claude-session
    fi
fi
