# Containers in sessions (`--containers`)

Sessions cannot build or run containers by default: no Docker socket, no `--privileged`, and
Docker's default seccomp profile refuses the namespace syscalls a rootless engine needs without
`CAP_SYS_ADMIN`. The retired Sysbox path ([legacy-sysbox-broker.md](legacy-sysbox-broker.md))
was one answer and had many issues. `--containers` is the other: **rootless podman run by the
`claude` user inside a session container that keeps production's hardening**, with `docker` and
`docker compose` driving it through `podman system service`. This page records the decision,
what ships, and the prototype it rests on.

## The decision

The prototype (below) proved two modes that run the whole matrix, so the owner was asked, on
2026-10-16, "How should sessions get containers?", with five options: (a) rootless podman,
single uid only (failed the matrix, offered only as "Other"); (b) rootless podman, multi-uid
through a root uid-map helper, keeping `no-new-privileges`; (c) rootless podman, multi-uid with
`no-new-privileges` off; (d) a privileged Docker-in-Docker sidecar behind its own flag; (e) none,
documenting the workarounds (Jib, crane, ko, apko). The owner's answer:

> "(b) Helper (Recommended)"

So `--containers` is the **helper** mode, opt-in per session, default off.

## Using it

```bash
claude-launch myproj --repo git@github.com:me/x.git --containers
claude-compose-gen --out /srv/claude/compose.yml --containers x me/x     # per service
```

Inside the session `podman`, `docker build`, `docker run` and `docker compose up` work as the
agent; `DOCKER_HOST` is `unix:///run/user/1000/podman/podman.sock` in every pane and SSH login,
and the session's managed memory carries a short note saying so. Short image names resolve on
Docker Hub. A published port (`-p 8080:80`) listens inside the session's network namespace.

What `--containers` adds to a session, and nothing else (`containers_run_args` in
`bin/_common.sh`; `claude-compose-gen` emits the same as YAML; `test/launch-unit.sh` asserts
the exact list for both):

| Added | Why |
|---|---|
| `--security-opt seccomp=containers/seccomp.json` | podman's profile with three syscalls made unconditional; see the options table below |
| `--security-opt apparmor=unconfined` | `docker-default` denies `mount` |
| `--security-opt systempaths=unconfined` | a nested container mounts a fresh `/proc` |
| `--device /dev/net/tun` | pasta, podman's rootless network |
| `-v claude-containers-<name>:/home/claude/.local/share/containers` | the image store: overlay on the container's own overlayfs is refused. `claude-rm --purge` and `compose down -v` delete it |
| `-e CLAUDE_CONTAINERS=1` | the entrypoint's §2d (below) |

Kept as in every session: `--cap-drop ALL` with production's minimal cap set, `no-new-privileges`,
no `--privileged`, no `CAP_SYS_ADMIN`, no host Docker socket. A session without `--containers`
gets none of the above (asserted by the unit suites and by smoke).

The image (every variant) ships podman, crun, conmon, netavark, aardvark-dns, nftables, passt,
catatonit, the docker CLI and compose, but no `uidmap`: its setuid `newuidmap` gains nothing
under `no-new-privileges`. In its place `/usr/local/bin/newuidmap` and `newgidmap` are the
client of the uid-map helper ([`containers/newidmap-client.py`](../containers/newidmap-client.py)).
In a session without `--containers` they are inert: Docker's seccomp profile stops podman at
its first `unshare`.

The entrypoint's §2d (`entrypoint.d/02d-containers.sh`), only when `CLAUDE_CONTAINERS=1`:

1. writes one subordinate range for the agent, `claude:100000:65536`, to `/etc/subuid` and
   `/etc/subgid`;
2. starts the uid-map helper as root on `/run/claude-containers/uidmap.sock`
   ([`containers/uidmap-helper.py`](../containers/uidmap-helper.py)), restarted if it exits;
3. clears the agent's runtime dir `/run/user/1000` (it is in the container layer, not a tmpfs,
   so it would carry the last boot's podman state) and starts `podman system service` as the
   agent on a socket in it, restarted if it exits;
4. exports `XDG_RUNTIME_DIR` and `DOCKER_HOST`, and writes them to
   `/etc/profile.d/claude-containers.sh` for SSH logins.

Logs: `/var/log/claude-containers/`. The boot log's `Containers` line says whether both sockets
came up within 10 seconds.

### Host requirements

`claude-launch --containers` refuses, and `claude-compose-gen` warns, when the host lacks one:

- `/dev/net/tun` (the `tun` module);
- on Ubuntu 23.10 and later, `kernel.apparmor_restrict_unprivileged_userns=0` (as root:
  `sysctl -w kernel.apparmor_restrict_unprivileged_userns=0`, persisted in `/etc/sysctl.d/`).
  Debian hosts do not set it.

CI's `smoke` job sets the sysctl on its runner and runs smoke's section 19 as required: a
`--containers` session started with exactly the launcher's options and the real entrypoint,
whose agent builds an image with an apt `RUN` and brings up a two-service compose stack, plus
the posture checks (not privileged, `CapDrop` ALL, `no-new-privileges`, `CapEff` 0 for the
agent, the helper refusing host uid 0).

## The prototype it rests on

The prototype was a throwaway workflow, `containers-proto.yml`, with its own stage and runner
script under `test/containers-proto/` (both removed once smoke's section 19 replaced them; they
are in the history of the prototype's PR). It ran on `ubuntu-24.04`:

1. `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0` on the runner (a host setting).
2. Builds the session image, then adds podman 5.4.2, crun 1.21, conmon, netavark 1.14, nftables,
   passt, uidmap, the docker CLI 26.1 and docker-compose 2.26 in a throwaway stage
   (`test/containers-proto/Dockerfile`).
3. `test/containers-proto/run.sh` starts the image with
   `docker run` and production's hardening exactly as `claude-launch` builds it
   (`harden_run_args` from `bin/_common.sh`: `--cap-drop ALL`, the minimal cap set the entrypoint's
   `gosu` needs, `no-new-privileges`) and its other run flags at their defaults (`--init`,
   `--cpus 2`, `--memory 4g`, `--pids-limit 2048`, `--shm-size 2g`, a 1 GiB `/tmp` tmpfs), plus
   the options below, with podman's storage on a volume.
   The entrypoint is replaced by `sleep` (a prototype needs no login); root-side setup a real
   entrypoint would do runs as `docker exec -u 0`, and every test runs as `docker exec -u claude`.
4. Per mode, as `claude`: `podman build` of a Dockerfile whose `RUN` does
   `apt-get update && apt-get install -y curl`; `podman run` postgres 17 until `pg_isready`;
   nginx with a published port until `curl` gets its page; and `docker compose up` of a two-service
   file (postgres, plus a client that waits for `db` by name) through `DOCKER_HOST` pointed at
   `podman system service`.
5. Security checks: without the options `unshare -U` fails; `docker inspect` shows
   `Privileged=false`, `CapDrop=ALL` and no capability beyond production's set; the `claude`
   user's `CapEff` is 0.

Run: [actions/runs/38972393766](https://github.com/cosyte/claude-containers/actions/runs/38972393766)
on commit `dc3e419`, kernel 6.17 (Azure), 2026-10-16. The run's logs (one per step) are its
`containers-proto-results` artifact. The job took 6 min 15 s, of which the three modes 5 min 26 s.

## The options

| Option | Why | What it gives up |
|---|---|---|
| `--security-opt seccomp=<podman's profile>` | Docker's profile refuses `unshare`, `mount`, `clone` with namespace flags, `setns` and more without `CAP_SYS_ADMIN`; podman's allows them, the kernel then checks caps per namespace. | A wider syscall surface reachable from the session (namespace and mount code in the host kernel). |
| ...with `sethostname`, `setdomainname`, `setns` allowed unconditionally | Docker resolves a profile's `includes.caps` once, against the container's caps; with no `CAP_SYS_ADMIN` these stay refused even inside podman's own namespaces (`crun: sethostname: Operation not permitted`). moby's default already allows the first two. The kernel still needs `CAP_SYS_ADMIN` over the target namespace. | Nothing beyond the row above. `run.sh` derives this from the vendored file with one `jq` filter. |
| `--security-opt apparmor=unconfined` | `docker-default` denies `mount`. | The AppArmor layer for the whole session. |
| `--security-opt systempaths=unconfined` | Masked and read-only `/proc` paths stop a nested container from mounting a fresh `/proc`. | Docker's masks and read-only `/proc` paths (`/proc/sys`, `/proc/sysrq-trigger`, `/proc/kcore`, ...). The agent (`claude`, `CapEff` 0) still cannot write them, but the container's root (the entrypoint, the helper daemon) is host root to them: host-wide sysctls and sysrq become one root-side bug away. The weightiest row. |
| `--device /dev/net/tun` | pasta, podman's rootless network, needs a tap device. | A tun device in the session. |
| Host: `kernel.apparmor_restrict_unprivileged_userns=0` | Ubuntu 23.10 and later let only AppArmor-profiled programs create user namespaces. | Host-wide: any unconfined program may create one. |
| `/etc/subuid` and `/etc/subgid` lines (`claude:100000:65536`) | Images own files as many uids (postgres 999, nginx 101, apt's `_apt` 42). | Nothing by themselves; how the map gets written is the mode. |
| Mode **helper**: a root daemon writes the map | `newuidmap` is setuid (or file-capability); under `no-new-privileges` neither gains anything, and podman fails outright. | A root process on a socket in the session (~100 lines, [`uidmap-helper.py`](../containers/uidmap-helper.py)). |
| Mode **fcaps**: `no-new-privileges` off | Lets the `cap_setuid`/`cap_setgid` file capabilities on `newuidmap`/`newgidmap` work. | `no-new-privileges` for that session: any setuid or file-capability binary in the image works again (still bounded by production's cap set). |

The vendored profile is [`containers/seccomp-upstream.json`](../containers/seccomp-upstream.json),
containers/common `pkg/seccomp/seccomp.json` at commit `82146f3` (tag v0.64.2), unmodified. The
profile sessions get, [`containers/seccomp.json`](../containers/seccomp.json), is that file through
the one filter in [`containers/seccomp.jq`](../containers/seccomp.jq) (the second row above);
`test/launch-unit.sh` rebuilds it and fails on any difference.

## Results

The modes all keep `--cap-drop ALL` and production's cap set:

- **single**: `no-new-privileges`, no subuid lines, so podman maps the one uid it has
  (`ignore_chown_errors` set).
- **helper**: `no-new-privileges`, subuid lines, and `newuidmap`/`newgidmap` on `PATH` replaced
  by a client of a root daemon. The daemon reads the caller from `SO_PEERCRED`, refuses a pid the
  caller does not own or a range outside its own id and subuid lines, and writes the map from a
  child running as the caller with only `CAP_SETUID` and `CAP_SETGID` (the kernel lets only the
  namespace's owner, or a holder of `CAP_SYS_ADMIN`, write it).
- **fcaps**: `no-new-privileges` off, subuid lines, `newuidmap`/`newgidmap` with file capabilities
  instead of setuid.

| Step | single | helper | fcaps |
|---|---|---|---|
| not privileged, no cap beyond production, user `CapEff` 0 | PASS | PASS | PASS |
| `no-new-privileges` | kept | kept | **off** |
| `unshare -U` | PASS | PASS | PASS |
| helper refuses to map host uid 0 | | PASS | |
| `podman info` (uid map) | PASS (1 uid) | PASS (0 to 1000, 1 to 100000 x 65536) | PASS (same) |
| `podman build`, `RUN apt-get install curl` | **FAIL** (2 s): apt's `setgroups`/`seteuid` to `_apt` | PASS (5 s) | PASS (6 s) |
| `podman run` postgres 17, ready | **FAIL** (98 s): `chown /var/lib/postgresql/data` | PASS (7 s) | PASS (7 s) |
| `podman run` nginx, page over a published port | **FAIL** (63 s): `chown(..., 101)` | PASS (3 s) | PASS (4 s) |
| `docker compose up` via `podman system service` (podman API 5.4.2), service DNS | **FAIL** (110 s): db's `chown` | PASS (4 s) | PASS (4 s) |

Baseline (production hardening only, no options): `unshare -U` as `claude` fails with
`Operation not permitted`, not privileged, `CapDrop=ALL`, no extra capability, `CapEff` 0. All PASS.

Seconds include image pulls; single's failures include the wait loop running out. Without the
seccomp change in the second row of the options table, single and fcaps failed at
`crun: sethostname: Operation not permitted`, and without nftables in the image compose failed at
`netavark: ... unable to execute nft`
([the first run on this PR](https://github.com/cosyte/claude-containers/actions/runs/38969035663)).

**Reading it:** single-uid mode is not enough for typical images, as the research predicted.
Both multi-uid modes run the whole matrix. The helper mode does it with every production flag
kept, at the price of a root daemon in the session; fcaps does it with no extra process, at the
price of `no-new-privileges`.

## Not shipped, and the owner's host checks

- **The other options**: (c) `no-new-privileges` off and (d) a privileged DinD sidecar were not
  chosen; (d) would make the sidecar root on the host in all but name and bypass the session's
  egress firewall. Sysbox stays retired.
- **GPU sessions**: `--gpu` and `--containers` combine (one `devices:` list). CDI mounts
  `/proc/driver/nvidia/params` over `/proc`; check on the host that a nested container starts
  and the GPU session still sees its card.
- **Egress lockdown**: the firewall is iptables in the session's network namespace; pasta
  traffic leaves through that namespace, so the rules should still apply. Check on the host that
  a nested container cannot reach a denied host under `CLAUDE_EGRESS_LOCKDOWN=1`.
- **Storage**: the store volume is not sized or reaped; a session that pulls many images fills
  the pool like any volume. `podman system prune` inside, or `claude-rm --purge`.
- **Enabling it on the owner's stacks**: a `--containers` line in that deployment's scenario
  `.conf`, the owner's change, after this merges.
