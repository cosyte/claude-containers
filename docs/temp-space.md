# Temp space: `/scratch`, not `/tmp`

`/tmp` is a **tmpfs**: it lives in RAM, is capped at 1 GB, and every page is charged to the
container's memory cgroup. With `TMPDIR` unset, everything large defaults there: `pip`/`uv`
building wheels, big archives, compiler temp files. The result is an install that dies at
1 GiB with a confusing
`ENOSPC` while the host has terabytes free, or, worse, a session that OOM-kills itself
because a build filled RAM it was accounted for.

So every container gets a **disk-backed `claude-scratch-<name>` volume mounted at
`/scratch`, and `TMPDIR` points at it**. Temp writes land on disk, where the space actually
is; `/tmp` stays a small, fast tmpfs for what a tmpfs is good at. Every process inherits
`TMPDIR` from the entrypoint, and `bash_profile` re-exports it, so an SSH login gets
the same behaviour as the agent (sshd builds a fresh environment and would otherwise fall
back to `/tmp`).

It is scratch, not state: the entrypoint **clears it on every boot**. A volume: unlike a
tmpfs: survives restarts, so without that it would accumulate abandoned wheel builds and
half-written tarballs until the pool filled. `claude-rm --purge` deletes it.

Raising the `/tmp` tmpfs instead would have been the wrong fix: it is RAM, so a 10 GB `/tmp`
would simply move the failure from `ENOSPC` to an OOM kill inside the session's own cgroup.

## The exception: GPU and browser services put `/scratch` on RAM

Two kinds of session get a **RAM tmpfs at `/scratch`** instead of the disk volume, with
`TMPDIR` still pointing at it:

- **GPU** (`claude-launch --gpu`, `claude-compose-gen --gpu REPO`): `CLAUDE_GPU_SCRATCH_TMPFS`,
  default `4g`. Blender's render temp, its kernel caches and throwaway CUDA or VTK venvs
  churn here.
- **Browser** services from `claude-compose-gen --browser REPO`: `CLAUDE_BROWSER_SCRATCH_TMPFS`,
  default `3g`, with a harder pids cap (`CLAUDE_BROWSER_PIDS_LIMIT`, default `1024`). Chromium,
  Lighthouse and ffmpeg temp churn here. A service that is both gets the larger size.

One service's size: `claude-compose-gen --scratch-size REPO=SIZE` (e.g. `render=8g`) overrides
both stack-wide sizes for that service alone. It is refused for a service whose `/scratch` is the
disk volume, which has no size to set.

The reason is the disk: on a spinning pool, that much small-file churn starved I/O until
processes wedged in uninterruptible sleep and the container could not be killed. RAM avoids it,
at the cost described above: every page written is charged to the service's memory cgroup
(`CLAUDE_MEM_LIMIT`, default `4g`) alongside `/tmp`. The sizes are ceilings, not reservations,
but a session that fills its scratch can reach the limit, so raise its limit (`--mem REPO=SIZE` in
`claude-compose-gen`, `CLAUDE_MEM_LIMIT` for `claude-launch`) when it renders or builds big. The tmpfs is empty on every start, like the volume.

## Two kinds of `/scratch`

| Kind | Who gets it | Size | Cleared |
|---|---|---|---|
| Disk volume `claude-scratch-<name>` | every session by default | the volume's pool | on every boot |
| RAM tmpfs | GPU and browser services | set by the stack: `CLAUDE_GPU_SCRATCH_TMPFS`, `CLAUDE_BROWSER_SCRATCH_TMPFS`; one service: `--scratch-size REPO=SIZE` | on every start |

Either way it is per container but **shared by every session in it**, and Claude Code gives each
session its own folder there, `/scratch/claude-<uid>/<project>/<session-id>/`. A container that
lives for weeks collects hundreds of them (one had about 538 at once), and the boot wipe is the
only other cleanup: `claude-disk-gc` never touches `/scratch`. When a 24G RAM `/scratch` reached
100%, Claude Code's own temp writes failed and every Bash call in about 10 sessions broke.

## The reaper: gone sessions' folders

`claude-scratch-reap` frees them. The sessions supervisor (`claude-sessions supervise`) runs it
every `CLAUDE_SCRATCH_REAP_MIN` minutes (default 15), and its lines land in `docker logs` as
`[scratch-reap] ...`. It removes a session folder only when **all** of these hold:

- the session is not live: no live Claude process names it in `~/.claude/sessions/<pid>.json`
  (an idle session's id is only there: Claude Code sets `CLAUDE_CODE_SESSION_ID` on the commands
  it runs, not on itself), and no process has it in its environment (`/proc/*/environ`, those
  commands and everything they start) or command line (`/proc/*/cmdline`, `claude --resume <id>`);
- no process has its working directory or an open file under the folder (`/proc/*/cwd`, `/proc/*/fd`);
- nothing in it was modified in the last 6 hours;
- it is not the caller's own session, and it is not reached through a symlink.

Anything else under `/scratch` (a `mktemp` dir, a build's temp tree) is never touched. Then, when
`/scratch` is fuller than `CLAUDE_SCRATCH_WARN_PCT` percent (default 85), it logs a warning naming
the 5 largest top-level folders, so the session filling it can be found.

`CLAUDE_SCRATCH_REAP` sets what it does:

- `report` (the default): logs `would remove <folder> (<size>)` and removes nothing.
- `on`: removes them.
- `off`: does nothing, not even the warning.

**Switching it on:** the owner reads a week of reports first (`docker logs <container> 2>&1 | grep
scratch-reap`), checks that no listed folder belonged to a live session, then sets
`CLAUDE_SCRATCH_REAP=on` in `.env` and recreates the containers. To see what it would remove right
now, inside a container: `claude-scratch-reap --dry-run`.
