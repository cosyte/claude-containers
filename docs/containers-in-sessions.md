# Containers in sessions (prototype results)

Sessions cannot build or run containers today: no Docker socket, no `--privileged`, and Docker's
default seccomp profile refuses the namespace syscalls a rootless engine needs without
`CAP_SYS_ADMIN`. The retired Sysbox path ([legacy-sysbox-broker.md](legacy-sysbox-broker.md))
was one answer and had many issues. This page records a prototype of another: **rootless podman
run by the `claude` user inside a session container that keeps production's hardening**, plus a
few named options. Nothing here ships: the image and the launchers are unchanged, and choosing
an option is a separate decision for the owner.

## How it was proven

[`.github/workflows/containers-proto.yml`](../.github/workflows/containers-proto.yml) (manual, and
on PRs touching it or `test/containers-proto/`) runs on `ubuntu-24.04`:

1. `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0` on the runner (a host setting).
2. Builds the session image, then adds podman 5.4.2, crun 1.21, conmon, netavark 1.14, nftables,
   passt, uidmap, the docker CLI 26.1 and docker-compose 2.26 in a throwaway stage
   ([`test/containers-proto/Dockerfile`](../test/containers-proto/Dockerfile)).
3. [`test/containers-proto/run.sh`](../test/containers-proto/run.sh) starts the image with
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

Run: [actions/runs/38970936952](https://github.com/cosyte/claude-containers/actions/runs/38970936952)
on commit `1d9596e`, kernel 6.17 (Azure), 2026-10-16. The run's logs (one per step) are its
`containers-proto-results` artifact. The job took 6 min 14 s, of which the three modes 5 min 17 s.

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
| Mode **helper**: a root daemon writes the map | `newuidmap` is setuid (or file-capability); under `no-new-privileges` neither gains anything, and podman fails outright. | A root process on a socket in the session (~100 lines, [`uidmap-helper.py`](../test/containers-proto/uidmap-helper.py)). |
| Mode **fcaps**: `no-new-privileges` off | Lets the `cap_setuid`/`cap_setgid` file capabilities on `newuidmap`/`newgidmap` work. | `no-new-privileges` for that session: any setuid or file-capability binary in the image works again (still bounded by production's cap set). |

The vendored profile is [`test/containers-proto/seccomp.json`](../test/containers-proto/seccomp.json),
containers/common `pkg/seccomp/seccomp.json` at commit `82146f3` (tag v0.64.2), unmodified.

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
| `podman build`, `RUN apt-get install curl` | **FAIL** (2 s): apt's `setgroups`/`seteuid` to `_apt` | PASS (5 s) | PASS (4 s) |
| `podman run` postgres 17, ready | **FAIL** (97 s): `chown /var/lib/postgresql/data` | PASS (5 s) | PASS (5 s) |
| `podman run` nginx, page over a published port | **FAIL** (62 s): `chown(..., 101)` | PASS (3 s) | PASS (3 s) |
| `docker compose up` via `podman system service` (podman API 5.4.2), service DNS | **FAIL** (106 s): db's `chown` | PASS (6 s) | PASS (6 s) |

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

## Not prototyped, and the owner's host checks

- **A privileged Docker-in-Docker sidecar** (`docker:dind` with `--privileged`, the session given
  `DOCKER_HOST=tcp://...`): works with any image, but the sidecar is root on the host in all but
  name and every session sharing it shares its daemon. An option to weigh, not tried here.
- **Sysbox**: retired (see above), out of scope.
- **GPU sessions**: CDI mounts `/proc/driver/nvidia/params` over `/proc`; with
  `systempaths=unconfined` and a nested `/proc` mount, check on the host that a nested container
  starts and the GPU session still sees its card.
- **Egress lockdown**: the firewall is iptables in the session's network namespace; pasta
  traffic leaves through that namespace, so the rules should still apply. Check on the host that
  a nested container cannot reach a denied host under `CLAUDE_EGRESS_LOCKDOWN=1`.
- **The host's AppArmor**: on an Ubuntu 23.10+ host, `apparmor_restrict_unprivileged_userns`
  must be 0 (or a profile written for the session); Debian hosts do not set it.
- **Storage**: podman's store needs a volume (overlay on the container's own overlayfs is
  refused); in production that is a per-container volume, sized and reaped like `/scratch`.
