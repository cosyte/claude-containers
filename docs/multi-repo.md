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

## An umbrella repo with submodules

When one repo already pins the others as git submodules (an umbrella), clone that one and let
its submodules come with it, rather than listing the repos as siblings:

```
# a standalone container
claude-launch acme --repo git@github.com:acme/umbrella.git --env GIT_UMBRELLA=1
# a stack service (scenario .conf, or the generator's command line): the service is the repo's name
acme/umbrella
--env umbrella=GIT_UMBRELLA=1
```

`/workspace` is the umbrella, each submodule is checked out at its pinned commit inside it,
and every session sees `COSYTE_UMBRELLA=/workspace`. Every github.com SSH URL (the umbrella's
and its submodules') goes over HTTPS with `GH_TOKEN`, since a deploy key reaches one repo
only, so set a `GH_TOKEN` that reaches every submodule ([github-token.md](github-token.md)).
Each boot checks out the submodules not checked out yet (a pin added since, or one that could
not be fetched before, which the boot log names in a `WARNING`) and never touches one that is.
Each submodule's fetch is bounded by `GIT_SUBMODULE_TIMEOUT` (300 s by default); one stopped
there is a `WARNING` too, and the boot goes on.
`GIT_UMBRELLA` cannot be combined with `GIT_REPOS`. The decision and its reasons are in
[architecture.md](architecture.md).

Plugins that the umbrella's own `.claude/settings.json` declares (`extraKnownMarketplaces` and
`enabledPlugins`) load whole from the first session, a fresh config included: before the
sessions start, `claude-kit warm` makes one throwaway start in `/workspace` when the config has
not registered those marketplaces yet ([kits.md](kits.md)).

