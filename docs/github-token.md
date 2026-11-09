# GitHub token (`GH_TOKEN`)

`GH_TOKEN` is the token every session's `gh` and HTTPS git use. `git push` over SSH uses the
deploy key instead (`GIT_SSH_KEY`), so a push can work while every API write fails: a session
only learns that a token cannot open a PR when `gh pr create` returns 403. This page says which
token to use, which scopes it must never hold, and how to see, at start, what it can do.

## The token: a classic token, narrowed

Use a **classic** token with these scopes (another, such as `gist`, changes nothing here):

| Scope | What a session does with it |
|---|---|
| `repo` | Branches, commits and pushes over HTTPS, pull requests, checks, and commit statuses (read and write), on every repo your account can reach |
| `workflow` | Changing files under `.github/workflows` |
| `read:org` | Reading org membership and teams (`gh` reads them for reviewers and org repo lists) |

And **never** these two:

| Scope | Why a session must not hold it |
|---|---|
| `delete_repo` | It lets a session delete a repository |
| `admin:org` | It changes an org's settings, members, and org rulesets: the rules that guard a branch from a force push or a deletion |

Without them, deleting a repository or changing an org's settings needs you, signed in on
GitHub, and an org ruleset made there cannot be removed by any session. The start-time check
below fails when the token holds either one.

What `repo` still lets a session do: merge a pull request, set a commit status, turn auto-merge
on, and, where your account is a repo admin, change that repo's settings and rulesets. GitHub
gives a classic token no narrower scope for those, so they stay with whatever the session runs
(its permission settings and hooks), not with the token.

A classic token reaches every repo your account can, across your user and every org, so one
token covers a stack whose repos span owners. An org with SSO needs the token authorized for it
(Configure SSO beside the token). To narrow an existing token, edit it on GitHub (Settings,
Developer settings, Personal access tokens, Tokens (classic)), untick `delete_repo` and
`admin:org`, and save; the token's value does not change, and the next check reads the new
scopes.

### A fine-grained token instead

A fine-grained token has permissions, not scopes, and **one resource owner**: either your user
or one org. A container whose repos span your own repos and an org's (`GIT_REPOS` with both)
cannot work with one: on the other owner's repos every write returns 403 `Resource not
accessible by personal access token`, and a stack carries only one `GH_TOKEN`. An org may also
require approval of fine-grained tokens (Settings, Personal access tokens): until an owner
approves it, the token reads public data only.

If every repo a stack works on has one owner, a fine-grained token on that owner needs:

| Permission | Access | What needs it |
|---|---|---|
| Contents | Read and write | Branches and commits over HTTPS, `gh` file edits, squash-merge |
| Pull requests | Read and write | `gh pr create`, `gh pr merge`, comments, reviews |
| Workflows | Read and write | Only to change files under `.github/workflows` |
| Checks | Read | `gh pr checks` |
| Commit statuses | Read and write | `gh pr checks` on repos whose CI reports statuses, and a tool that records a verdict as a status |
| Metadata | Read | Everything (GitHub adds it by itself) |
| Administration | **No access** | The fine-grained counterpart of `delete_repo` and repo settings |

The start-time check cannot read a fine-grained token's permissions as scopes, so its token
line says `?not-classic` there, never `FAIL`; the per-repo lines still probe what it can do.

The repo's own `permissions` field (`gh api repos/o/r`) and GraphQL's `viewerPermission` report
**your account's role**, not the token's, so they say `admin` while the token is refused. Only
a call shows what the token can do, which is what the start-time check makes.

## The start-time check

At every start with `GH_TOKEN` set, the entrypoint runs `claude-gh-check` in the background
(it never blocks or fails the boot) and writes its result to `/run/claude/gh-check.txt`,
readable by every session, the token never in it. First one line for the token, then one line
per github.com repo under `/workspace` (at most 30):

```
github token: scopes ok (repo, workflow, read:org)
github me/x: read ok, contents-write ok, pr ok, checks ok
github myorg/myproj: read ok, contents-write NO, pr NO, checks ok
```

A token that holds a forbidden scope reads:

```
github token: scopes FAIL (holds delete_repo, admin:org; narrow the token: docs/github-token.md)
```

`claude-gh-check` then exits 1 (after printing every line), and the boot log (`claude-logs
<name>`) has one `ERROR: GH_TOKEN holds a scope a session must never have` line. Each repo
with a `NO` logs a `WARNING: GH_TOKEN is missing a permission` line. Run `claude-gh-check` any
time to probe again; it prints the same lines and exits 1 on a forbidden scope, 0 otherwise.

| Field | Probe | What it says |
|---|---|---|
| token scopes | `GET /` on the API, reading the `X-OAuth-Scopes` header (the call `gh auth status` makes) | `ok (<scopes>)`; `FAIL (holds ...)` for `delete_repo` or `admin:org`; `?not-classic` when the header is absent (a fine-grained or app token); `?<code>` for another answer with no header |
| read | `GET /repos/o/r` | `NO`: the token cannot see the repo (`read NO (HTTP 404)`, and nothing else is probed) |
| contents-write | `PUT /repos/o/r/contents/.claude-gh-check`, no body | `NO`: no Contents write. `git push` over SSH may still work: this is the token's, not the push path's |
| pr | `POST /repos/o/r/pulls`, no body | `NO`: no Pull requests write |
| checks | `GET /repos/o/r/commits/HEAD/check-runs` | `NO`: no Checks read: `gh pr checks` fails |

Every probe is read-only: a GET, or a write call with no body, which GitHub refuses as invalid
(400 or 422) once it has checked the permission, before it could change anything. It never
probes the merge endpoint, where an empty body merges an open PR. `?<code>` is an answer it did
not expect (a 5xx, say). `?rate-limited` is GitHub's rate limit, which often answers 403 like a
missing permission: a 403 or 429 with `x-ratelimit-remaining: 0`, a `retry-after` header or a
"rate limit" message (primary or secondary limit, as when a stack sharing one token boots at
once). It never reads as `NO` and logs no warning; run `claude-gh-check` again later.
`github: skipped (...)` means it could not ask (offline, a timeout, no `GH_TOKEN`, no github.com
repo, or a call already rate limited, so nothing after it was checked). A rate-limited answer
that still carries the scopes header is read for the token line first.

On a public repo `read` and `checks` answer 200 to any token, so there they say only that the
call works, not that the token holds the permission; the two write probes are exact everywhere.

A new or changed token reaches a container when it is recreated with the new `GH_TOKEN`; the
check runs at that start. A narrowed scope on the same token needs no recreation: run
`claude-gh-check` to see it.
