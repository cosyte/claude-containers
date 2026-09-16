## Unattended autopilot

A container has two modes, selected by `CLAUDE_AUTOPILOT`:

- **interactive** (default): the main tmux pane is a Remote Control + SSH
  session (`claude-session`), as above.
- **autopilot** (`CLAUDE_AUTOPILOT=1`): the main pane instead runs a **headless
  Claude loop** (`claude-autopilot`): every `CLAUDE_AUTOPILOT_INTERVAL` seconds
  it fires `claude -p "$CLAUDE_AUTOPILOT_CMD"` and prints the result. No Remote
  Control link (the watchdog is skipped); SSH still attaches to the live pane so
  you can watch it. Each run is a fresh session, which suits a session-independent
  command that recovers its state from disk.

> **`CLAUDE_AUTOPILOT_CMD` is required and has no default.** It used to default to a
> slash command that existed only in the maintainer's own repo. That was wrong: this
> is a *generic* image: it bakes no such command, and the workspace you mount is
> arbitrary, so on almost every container the default resolved to nothing at all.
> With no command set, the autopilot now refuses to run (or idles, if it is a queue
> consumer). **No command, no run.**
>
> **Set it to a command your workspace actually defines.** On the pinned CLI, `claude -p`
> does *not* error on an unknown slash command: it returns a **zero-turn "success"**
> (`num_turns: 0`, `is_error: false`, exit 0, `$0`, the model never invoked, `result:
> "Unknown command: /typo"`). The autopilot therefore treats a zero-turn
> `Unknown command:` result as a **failure**: it says so loudly, files a queued task
> under `failed/` rather than `done/`, and stops (or, if it is also a queue consumer,
> drops the broken fallback and keeps draining the queue). Without that check a typo'd
> command would have produced a container that logs a healthy `$0` run every interval,
> forever, having done nothing.

Point one autopilot container at a repo, with a command *that repo defines*:

```bash
CLAUDE_AUTOPILOT=1 CLAUDE_AUTOPILOT_CMD='/my-build-command' CLAUDE_AUTOPILOT_INTERVAL=3600 \
  ./bin/claude-launch builder --repo git@github.com:<org>/<repo>.git
```

On a rate/usage-limit failure the loop parses the actual reset time (from the
run output or a reset epoch in the JSON) and sleeps until then: better shared-
quota throughput than blind waiting, and falls back to exponential backoff (up
to `CLAUDE_AUTOPILOT_BACKOFF_MAX`, default 6h) when no reset time is found, so a
hot error loop still can't burn your quota. Each run logs its `total_cost_usd`
(plus turns and duration) so the shared subscription's spend is attributable per
container. Per-run JSON logs land in `CLAUDE_AUTOPILOT_LOG_DIR` (default
`~/.claude/autopilot-logs`); `claude-logs` still shows the entrypoint/sshd log.

By default each cycle is a fresh session (suits session-independent commands that
recover state from disk). Set `CLAUDE_AUTOPILOT_RESUME=1` to
instead carry the exact conversation forward via `--resume <session_id>` (the ID
is captured from each run's JSON and persisted on the container's config volume).
Use it for a single stateful long-running task rather than a queue-driven one.

**Durable task queue.** A blind timer is the wrong primitive for fleet work, so
`CLAUDE_AUTOPILOT_QUEUE=1` turns the loop into a queue consumer: it claims the
oldest pending prompt file (atomic `mv`, so it's restart- and race-safe), runs it
as a one-shot task, and files it under `done/` or `failed/`. When the queue
drains it falls back to `CLAUDE_AUTOPILOT_CMD` on the interval, so a queued
container is *also* a continuous-build container. Leave `CLAUDE_AUTOPILOT_CMD`
unset and it is a **pure queue consumer**: on an empty queue it simply idles,
rather than inventing a prompt to fill the gap. Enqueue from inside the
container (SSH in, then):

```bash
claude-enqueue "Upgrade the lockfile and make the tests pass"
echo "Triage the failing CI run and open a fix PR" | claude-enqueue
claude-enqueue --priority 0 "Urgent: patch the CVE in deps"   # lower = sooner
```

The queue lives on the per-container config volume (`~/.claude/autopilot-queue/`)
so it survives restarts; `CLAUDE_AUTOPILOT_QUEUE_DELAY` (default 10s) paces tasks
while draining.

**Event-driven routing.** `CLAUDE_SCM_OBSERVER=1` runs a poller (tmux window
`scm`) that turns the queue from pull to push: every `CLAUDE_SCM_INTERVAL`
(default 300s) it lists the workspace repo's open PRs via `gh` and enqueues a
task for each **new** actionable event: a failing CI check, a *changes
requested* review, or a merge conflict, so the container reacts to repo events
instead of only a clock. Events are keyed by PR + head commit, so a given
failure is routed once and re-fires only when new commits land (never every
poll). Polling (not webhooks) keeps the outbound-only posture: no inbound port.
Choose signals with `CLAUDE_SCM_EVENTS=ci,review,conflict`, scope with
`CLAUDE_SCM_PR_FILTER` (e.g. `--author @me`); it needs a GitHub remote and, for
private repos, `GH_TOKEN`. Pair it with `CLAUDE_AUTOPILOT=1` +
`CLAUDE_AUTOPILOT_QUEUE=1` so the same container consumes what it observes.

**Fleet observability.** Set `CLAUDE_OTEL_ENABLED=1` (or just an
`OTEL_EXPORTER_OTLP_ENDPOINT`) to export Claude Code's native per-call cost/token
telemetry to any OpenTelemetry backend: Langfuse, an OTel collector, Grafana.
Each container is tagged `service.instance.id=<project>` so the fleet view
separates agents, and the auth header stays in process env (never written to the
config volume). `CLAUDE_OTEL_TRACES=1` adds the (beta) trace export that
trace-first backends like Langfuse need. Full var list in `.env.example`.

**Auth + quota.** Autopilot uses the same Max-subscription OAuth as every other
container (the entrypoint refuses `ANTHROPIC_API_KEY`). A single Max plan is
shared across all running containers via the converged `claude-auth` volume, so
mind the plan's 5-hour and weekly limits when choosing the interval and how many
autopilot containers run at once: a too-tight cadence exhausts the subscription.

**Controller mode is gone.** `CLAUDE_CONTROLLER=1` used to be a third main-pane mode
that dispatched nested worker containers. When that dispatch tier was retired the mode
became a byte-identical pass-through to `CLAUDE_AUTOPILOT=1`: a mode whose only job was
selecting another mode, so it was removed along with `bin/claude-controller` and
`claude-reaper`. **Setting `CLAUDE_CONTROLLER=1` now refuses to boot**, pointing at
`CLAUDE_AUTOPILOT=1`, rather than silently starting an *interactive* session in an
unattended container nobody is watching. Use `CLAUDE_AUTOPILOT=1`; it is the same loop,
and always was.
