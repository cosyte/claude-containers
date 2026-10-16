<!-- claude-containers: containers session note. Written to /etc/claude-code/CLAUDE.md at boot
     because this container has CLAUDE_CONTAINERS=1; do not edit it here, it is rewritten. -->
## Containers (this session runs rootless podman)

- `podman` works as you, and `docker` / `docker compose` drive it: `DOCKER_HOST` points at
  `podman system service` in this container. Build, run and compose as usual, e.g.
  `docker build -t app .`, `docker compose up -d`, `podman run --rm debian:trixie-slim true`.
- It is rootless: root inside a container is your own uid outside it, and other uids map to a
  private range. There is no `--privileged`, no host Docker socket and no host network: a
  published port (`-p 8080:80`) is reachable inside this session only.
- Images and volumes live on this container's own store (a volume, kept across restarts):
  clean up what you no longer need (`podman system prune`), it fills the host's disk.
- Short names resolve on Docker Hub (`postgres:17`). If podman fails at its first step with
  `Operation not permitted`, say so: the host's setup is the cause, not your command.
