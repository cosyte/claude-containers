# Several repos in one container

A session normally owns one repo, cloned into `/workspace`. When the work spans repos (a
part, the board it mounts to, the notes about both), one container can hold several: each
is cloned into `/workspace/<repo>` and the session starts in `/workspace`, so it reads,
edits and commits across all of them. Every repo keeps its own git history and remote;
each repo's own `CLAUDE.md` still applies inside it.

```
# a stack service (scenario .conf, or the generator's command line)
--group maker=you/home,you/3d,you/keys:dev
--active maker
# a standalone container
claude-launch maker --repo git@github.com:you/home.git --repo git@github.com:you/3d.git
```

The group's name is the service (`claude-maker`, its Remote Control session name) and
takes every per-repo flag (`--active`, `--gpu`, `--cpu`, `--mem`, ...); it must not also be
one of the stack's single-repo services. A branch is `repo:branch` in `--group` and
`URL#BRANCH` with `--repo`. Each boot clones only the repos that are missing, so adding one
to the list and restarting brings it in, and an existing checkout is never touched. The
container passes the list as `GIT_REPOS`; it cannot be combined with a single-repo
workspace (a repo at `/workspace` itself), so a multi-repo service starts from a fresh
workspace volume.

