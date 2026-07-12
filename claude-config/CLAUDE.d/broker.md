# Broker mode — dispatching nested workers

This container was launched with the **worker broker** enabled
(`CLAUDE_WORKER_BROKER=1` and `/run/claude/broker` present) — typically via
`claude-launch --broker` for an interactive lead, or `CLAUDE_CONTROLLER=1` for a
headless dispatch loop. The root-owned broker is running and waiting for
requests.

## The dispatch channel — `claude-worker-request`

`claude-worker-request` is the **only** way to spawn a nested worker from this
session:

```
claude-worker-request <repo> <item-id>          # optional: --timeout SECS
```

- **One request = one Sysbox-nested one-shot `/work-on <repo> <item-id>`**
  container. It builds, verifies, passes its gates, ships (per `/work-on`
  Steps 9–10), and `--rm`s itself on exit.
- The broker validates every request (deny-by-default) and answers
  `ok <container>` or `error <reason>`. It is the narrow channel by design —
  a request carries **exactly two sanitized values (repo + item-id)**, nothing
  else. The launch template is fixed and root-owned.
- **Never touch the inner Docker socket directly.** `docker run`,
  `docker exec`, `docker cp`, and any direct write to `/run/claude/broker` all
  bypass the launch template's hardening. The socket is `root:root 0600` by
  §5c's lockdown; the broker is the only channel that can produce a worker.

## Backpressure — WIP=K is enforced

The broker is capped at **K** in-flight workers, sourced from the umbrella's
`operations/parallel.config.json`. A request that would exceed K comes back as
an `error` — treat that as **backpressure (wait and retry)**, not as a failure.
It has a distinct shape from a validation refusal; use `--timeout` to bound the
wait per call.

## When to dispatch — you decide

There is **no default dispatch loop** in this session. Reading
`operations/BACKLOG.md`, picking the next actionable item, and calling
`claude-worker-request` is a deliberate act — the operator, the session
prompt, or (in headless controller mode) the `claude-controller` loop drives
it. This fragment documents the mechanism, not a default policy: it teaches
*how* to dispatch, never *when*.

## The full model

- `docs/substrate.md` → **"Interactive lead that spawns workers —
  `claude-launch --broker`"** — the substrate design, the isolation guarantees,
  the CC-3 sizing envelope, and the CC-2 broker's protocol.
- `bin/claude-worker-request` — the client's argv contract and error grammar.
- `bin/claude-worker-broker` — the root-owned server (for reference; agents
  never touch it directly).
