## Volume / mount reference

| Path in container | Source | Scope | Holds |
|---|---|---|---|
| `/auth` | `claude-auth` volume | shared | `.credentials.json` (OAuth) |
| `/etc/ssh/host-keys` | `claude-sshkeys` volume | shared | SSH host keys (stable fingerprint) |
| `/home/claude/.claude` | `claude-config-<proj>` volume | per container | Sessions, history, merged config, plugins |
| `/workspace` | `claude-ws-<proj>` volume *or* `--workspace` bind | per container | The git repo |
| `/var/lib/docker` | `claude-docker-<proj>` volume | per container, `--docker` only | Inner Docker image store: pulled base images + built layers. Can reach tens of GB; `claude-rm --purge` deletes it |
| `/scratch` | `claude-scratch-<proj>` volume | per container | **`TMPDIR`**: disk-backed temp. Cleared on every boot; `claude-rm --purge` deletes it |
| `/tmp` | tmpfs (**RAM**, 1 GB) | per container | Small temp only. Charged to the memory cgroup: big writes belong in `/scratch` |
| `/etc/claude/authorized_keys` | host `SSH_AUTHORIZED_KEYS` | read-only | Who may SSH in |
| `/etc/claude/git-key` | host `GIT_SSH_KEY` | read-only | Git push key |
| `/opt/claude-config` | baked into image | image | Bake-in template merged on start |

Anything baked in is overridable by mounting onto the target path (e.g. mount
your own `CLAUDE.md` onto `/home/claude/.claude/CLAUDE.md`).
