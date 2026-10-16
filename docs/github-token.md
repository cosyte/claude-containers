# GitHub token (`GH_TOKEN`)

`GH_TOKEN` is the token every session's `gh` and HTTPS git use. `git push` over SSH uses the
deploy key instead (`GIT_SSH_KEY`), so a push can work while every API write fails: a session
only learns that a token cannot open a PR when `gh pr create` returns 403. This page lists the
permissions a session needs and how to see, at start, whether the token has them.

## The permissions a session needs

On every repository a session works on, per resource owner (your user, and each org):

| Permission (fine-grained name) | Access | What needs it |
|---|---|---|
| Contents | Read and write | Branches and commits over HTTPS, `gh` file edits, squash-merge |
| Pull requests | Read and write | `gh pr create`, `gh pr merge`, comments, reviews |
| Workflows | Read and write | Only to change files under `.github/workflows` |
| Checks | Read | `gh pr checks` |
| Commit statuses | Read | `gh pr checks` on repos whose CI reports statuses |
| Metadata | Read | Everything (GitHub adds it by itself) |

### Classic or fine-grained

A fine-grained token has **one resource owner**: either your user or one org. A container whose
repos span your own repos and an org's (`GIT_REPOS` with both) cannot work with one
fine-grained token: on the other owner's repos every write returns 403 `Resource not
accessible by personal access token`. Two ways out:

- **A classic token** with scopes `repo`, `workflow` and `read:org`. It reaches every repo your
  account can, across owners. Wider than it must be, but one token.
- **One fine-grained token per resource owner**, each on the stacks (`.env`) whose repos that
  owner holds. Narrower, but a stack can carry only one `GH_TOKEN`, so a mixed stack still needs
  the classic one.

An org may require approval of fine-grained tokens (Settings, Personal access tokens): until an
owner approves it, the token reads public data only. An org with SSO needs the classic token
authorized for it (Configure SSO beside the token).

The repo's own `permissions` field (`gh api repos/o/r`) and GraphQL's `viewerPermission` report
**your account's role**, not the token's, so they say `admin` while the token is refused. Only
a call shows what the token can do, which is what the start-time check makes.

## The start-time check

At every start with `GH_TOKEN` set, the entrypoint runs `claude-gh-check` in the background
(it never blocks or fails the boot) and writes its result to `/run/claude/gh-check.txt`,
readable by every session, the token never in it. One line per github.com repo under
`/workspace` (at most 30):

```
github me/x: read ok, contents-write ok, pr ok, checks ok
github myorg/myproj: read ok, contents-write NO, pr NO, checks ok
```

Each repo with a `NO` also logs a `WARNING: GH_TOKEN is missing a permission` line in the boot
log (`claude-logs <name>`). Run `claude-gh-check` any time to probe again; it prints the same
lines.

| Field | Probe | `NO` means |
|---|---|---|
| read | `GET /repos/o/r` | the token cannot see the repo (`read NO (HTTP 404)`, and nothing else is probed) |
| contents-write | `PUT /repos/o/r/contents/.claude-gh-check`, no body | no Contents write. `git push` over SSH may still work: this is the token's, not the push path's |
| pr | `POST /repos/o/r/pulls`, no body | no Pull requests write |
| checks | `GET /repos/o/r/commits/HEAD/check-runs` | no Checks read: `gh pr checks` fails |

Every probe is read-only: a GET, or a write call with no body, which GitHub refuses as invalid
(400 or 422) once it has checked the permission, before it could change anything. It never
probes the merge endpoint, where an empty body merges an open PR. `?<code>` is an answer it did
not expect (a 5xx, a rate limit); `github: skipped (...)` means it could not ask (offline, a
timeout, no `GH_TOKEN`, no github.com repo).

A new or changed token reaches a container when it is recreated with the new `GH_TOKEN`; the
check runs at that start.
