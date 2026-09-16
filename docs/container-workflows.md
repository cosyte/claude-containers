## Container workflows (optional)

Off by default. When a session's job involves containers: writing a Dockerfile,
bringing up a `compose` stack, running testcontainers: give it **its own Docker
engine**:

```bash
make build-docker                             # tags claude-code-box:docker
./bin/claude-launch api --docker --workspace ./api
```

Inside, the agent is a normal Docker user: `docker build`, `docker run`,
`docker compose up`, `docker buildx` all work, as itself (the unprivileged
`claude` user), with no `sudo`.

**How this stays safe.** The daemon runs *inside* the session container, and the
container runs under **Sysbox** (`--runtime=sysbox-runc`), which puts it in a user
namespace: container-root maps to an unprivileged host uid. On this host, measured:

| | capabilities | uid map |
|---|---|---|
| ordinary session (`runc`) | Docker's default 14 | `0 → 0` (container-root **is** host root) |
| `--docker` session (`sysbox-runc`) | full set | `0 → 165536` (container-root is a host nobody) |

The full capability set looks alarming and isn't: those are powers over the
container's *own* namespace. This is why `--docker` needs **no `--privileged` and
no host docker-socket mount**: both are forbidden here, and either would hand a
prompt-injectable agent root on the host. `claude-launch --docker` refuses to run
if the Sysbox runtime is missing rather than falling back to something unsafe.

**What it does cost you, stated plainly.** A docker socket is a path to root
*inside* the container (`docker run -v /:/rootfs …`). Sysbox keeps that root off
the host, so the boundary that matters holds, but two in-container controls
assume root is separate from the agent, and on a `--docker` session they no longer
bind:

- **`CLAUDE_BROKER_GIT_KEY=1`** hides the deploy key in a root-owned `ssh-agent`;
  an agent with Docker can read the key file straight off the filesystem.
- **`CLAUDE_EGRESS_LOCKDOWN=1` (and `=strict`)** filters the `OUTPUT` chain; inner
  containers' traffic is `FORWARD`ed, and container-root can flush the rules
  anyway. `strict` does not refuse a `--docker` session over this: its ruleset
  still applies inside the session's own namespace, it just does not reach what
  the inner daemon forwards. The launcher warns for either spelling.

Egress lockdown is off by default; git-key brokering is **on** by default, so the
first bullet applies to a plain `--docker` session unless you opted out. The
caveat itself is unchanged: under `--docker`, treat the deploy key as readable by
the agent. The launcher warns if you combine either with `--docker`.
Also: `--cap-drop ALL` is skipped for these containers (an inner daemon cannot
start under the minimal set), while `no-new-privileges` is kept: its one real
cost is that setuid binaries *inside an inner container* (`sudo`, `ping`) can't
elevate.

**Sizing.** Inner containers live in the session's cgroup, so `CLAUDE_MEM_LIMIT` /
`CLAUDE_CPU_LIMIT` / `CLAUDE_PIDS_LIMIT` have to cover the whole stack. The 4g
default is tight for building images or running a compose stack; 8g+ is a saner
floor, and the launcher warns below it.

**Disk.** The inner image store persists in a per-project `claude-docker-<name>`
volume, so a recreate doesn't re-pull every base image. It holds every layer the
session builds or pulls and can reach tens of GB; `claude-rm --purge` deletes it
(and prints its size first).

Both variants compose: `make build-docker-browser` bakes the engine *and*
Chromium, for a session that runs a containerized stack and debugs its frontend
(`--docker --browser`). For a whole fleet, `claude-compose-gen --docker REPO`
emits `runtime: sysbox-runc` on just those services, a lean sibling in the same
stack keeps its full `cap_drop`.

Not to be confused with the retired nested-Sysbox **worker broker**
([docs/legacy-sysbox-broker.md](legacy-sysbox-broker.md)): this reuses that
era's runtime and nothing else: no broker, no worker plane, no spool.
