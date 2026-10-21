# Several sessions in one container

Every container runs its own session in tmux window `main` (Remote Control name = the
project). It can run more, started at boot: each in its own tmux window, with its own
Remote Control link (`<project>-<name>`, so each shows up separately in the Claude app;
`main` becomes `<project>-main` alongside them, or `CLAUDE_MAIN_NAME`),
working directory, model, permission mode, and an optional first prompt or `/goal`. They
share the container's workspace, tools, credentials and resources, which makes this the
natural shape for several lanes of work over one checkout, or one session per repo of a
multi-repo container.

```
# a standalone container: main + one session per repo, plus a read-only reviewer
claude-launch maker --repo git@github.com:you/api.git --repo git@github.com:you/web.git \
    --session '*' --session 'review dir=api model=sonnet mode=plan'

# a stack service (scenario .conf lines, or the generator's command line)
--group maker=you/api,you/web,you/docs
--session maker=api goal=docs/first.goal.txt
--session maker=web
--session maker=review dir=api model=sonnet mode=plan
--env maker=CLAUDE_MAIN_RESUME=1
```

A session spec is `NAME [key=value ...]`, several separated by `;` (the flag repeats too):

| Key | Meaning |
|---|---|
| `NAME` | lowercase letters, digits, `-`, `_`: the tmux window and the Remote Control suffix. `main`, `dev`, `scm` are taken. `*` is one session per git repo directly under `/workspace`, named after the repo (a named entry wins its name). |
| `dir=` | working directory, absolute or relative to `/workspace`. Default: `/workspace/NAME` when it is a directory, else `/workspace`. |
| `model=` / `mode=` | model alias or id / permission mode for this session (default: the container's). |
| `goal=FILE` | on its **first** start, begin with `/goal <contents of FILE>` (FILE relative to `dir`). |
| `prompt-file=FILE` | on its first start, begin with the contents of FILE. |
| `rc=off` | no Remote Control link (SSH / tmux only). |
| (names) | every session is named `<project>-<window>`, as its Remote Control name and its display name (`--name`), on every start: a resumed conversation reuses its old Remote Control session and would otherwise keep that session's old name in the app. |
| `resume=off` | a fresh conversation on every boot. By default a named session **resumes its last conversation** when the container restarts; main does not unless `CLAUDE_MAIN_RESUME=1`. |

`claude-launch` and `claude-compose-gen` validate the spec with the container's own
parser, so a typo fails the launch or the generation, not the boot. One removed
setting is the exception: `chain` (and `claude-sessions new --chain`, and the
`CLAUDE_GOAL_CHAIN_REVIEW` variable) belonged to a goal runner that no longer ships in this
image. A container still declared with them boots as before, each such session as a plain
session, with a warning in the boot log and from the generator; drop the word at the next
regeneration. A tool of that kind now comes in from outside the image. Inside, and from the
host with `claude-sessions -C <project> …`:

```
claude-sessions                        # ls: every session, its state (busy/idle/exited/stopped), dir, Remote Control, conversation
claude-sessions new review --dir home --model sonnet --prompt "Review the last 5 commits"
claude-sessions attach home            # or Ctrl-b w in tmux, or from the host: claude-attach maker home
claude-sessions send home "Run the tests and fix what fails"
claude-sessions restart home [--fresh] # resume its conversation in a new process (or start over)
claude-sessions restart home --resume ID   # take over conversation ID (e.g. one copied in from another container)
claude-sessions stop home              # stays stopped across restarts, until: claude-sessions start home
claude-sessions reset home             # forget its conversation; the next start re-sends its first prompt
claude-sessions rm review              # a `new` session only; a declared one is stopped instead
```

Sessions from `--session` (`CLAUDE_SESSIONS`) are the container's declaration: reconciled
on every boot, so an entry dropped from it is unregistered on the next recreate. Sessions
from `claude-sessions new` persist on the config volume and come back after a restart. A
first prompt or goal is sent exactly once (the start is recorded before Claude runs), so
a restart never replays goal 1 over a session that is on goal 4. What keeps several
sessions honest:

- **Resume is exact.** A supervisor records which conversation each window runs (from
  Claude Code's own `sessions/<pid>.json`, so it follows a `/clear`), and a restart resumes
  that one with `--resume <id>`. `--continue` is only a fallback, and only when no other
  session works in the same directory, where it could pick up a sibling's conversation.
- **Recovery is per session.** Every session with a Remote Control link gets its own RC
  watchdog, debug log (`/tmp/claude-rc-debug-<name>.log`) and respawn lock, and a restart
  kills only its own pane's processes. The usage-limit watchdog resumes every session that
  hit the limit, each with its own conversation.
- **Health stays about the container.** `docker ps` / `claude-list` read
  `healthy; sessions: 2/3 up (3d: claude exited)`: a named session never makes the
  container unhealthy (that would restart every session in it); main still does.
- **Capacity is shared.** The boot log says what each session gets (`Capacity: 4 Claude
  sessions share 16384 MiB (~4096 MiB each)`) and warns under 1 GiB each: a Claude process
  alone uses 300-600 MiB, and an OOM kill lands on whichever session the kernel picks.
  Raise `--mem` / `CLAUDE_MEM_LIMIT` with the session count. Pids too: threads count as pids,
  so give a multi-session container thousands per session (`CLAUDE_PIDS_LIMIT`). Library thread
  pools are capped per process (`CLAUDE_THREADS_PER_PROCESS`, default 4) because they size
  themselves to the host, and the supervisor warns in `claude-logs` near either limit. GNU
  `nproc` would print that cap (it honours `OMP_NUM_THREADS`), so the image's `nproc` prints
  the container's CPU quota (`/sys/fs/cgroup/cpu.max`) instead; `nproc --all` is the host's
  count, and `$OMP_NUM_THREADS` is the cap. A container started before this keeps GNU's
  until it restarts.
  Gradle builds get a third of the quota in workers (at least 2) and daemons stop after 30
  minutes idle, through `GRADLE_OPTS` (`CLAUDE_GRADLE_WORKERS`, `CLAUDE_GRADLE_IDLE_MS`), so
  several sessions' builds at once no longer throttle the whole container.
- **A crashed session comes back.** If Claude exits abnormally (an abort, a segfault, an OOM
  kill, a failed thread create), its window relaunches it after a backoff, resuming the same
  conversation, up to 5 times in 15 minutes. `/exit`, Ctrl-C and `claude-sessions stop` still
  mean stop.

Sessions share one checkout per directory. Two sessions writing the same git tree race on
its index, so give concurrent writers their own directories (one per repo, or a `git
worktree` each) and keep extra sessions in a shared directory to reading and reviewing
(`mode=plan`).

