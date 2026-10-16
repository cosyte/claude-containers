# GPU sessions (optional)

Off by default. A session that renders (Blender Cycles, EEVEE, Workbench), previews CAD
through OpenGL/EGL (VTK, PyVista, build123d), or runs CUDA can be given the host's GPU.
**NVIDIA only**, through the NVIDIA Container Toolkit's CDI spec; there is no `/dev/dri`
path and no per-device selection (the session gets `nvidia.com/gpu=all`).

**Host prerequisites:** the NVIDIA driver, the NVIDIA Container Toolkit, and its CDI spec
(`nvidia-ctk cdi generate --output=/var/run/cdi/nvidia.yaml`, or the toolkit's refresh
unit), on a Docker with CDI (28 or newer enables it by default). Check with
`docker info | grep nvidia.com/gpu`: you want `nvidia.com/gpu=all`.

**Turning it on for a stack service** (GPU access is fixed at container creation, so it
is always regenerate + recreate):

```
# 1. in the stack's scenario .conf
--gpu myrepo
# 2. regenerate, then recreate just that service
claude-compose-gen --scenario /srv/claude/personal/personal.conf
docker compose -f /srv/claude/personal/docker-compose.yml up -d myrepo
```

For a standalone container: `claude-launch <name> --gpu ...` (or `CLAUDE_GPU=1` in `.env`,
with `--no-gpu` to opt one out). Removing it is the same in reverse.

**What the service gets, and what it does not:**

- the CDI device `nvidia.com/gpu=all` on the default `runc` runtime. CDI injects the device
  nodes, the driver's user libraries (CUDA, OptiX, the EGL/GLX vendor libraries, the Vulkan
  ICD) and `nvidia-smi`, matched to the host driver. No `runtime: nvidia`, no extra
  capability, no privilege: `cap_drop: ALL`, the minimal set and `no-new-privileges` stay
  exactly as on every other session. `NVIDIA_DRIVER_CAPABILITIES` has no effect in CDI mode
  (the spec decides what is mounted).
- `/scratch` (`TMPDIR`) on a RAM tmpfs (`CLAUDE_GPU_SCRATCH_TMPFS`, 4g) instead of the disk
  volume, so render temp and kernel caches stay off a spinning pool. With the 1g `/tmp`
  that can reach 5g, more than the 4g default `CLAUDE_MEM_LIMIT`: a tmpfs is charged only as
  it fills, but raise `--mem` for a service that renders, so the session and the render's
  own memory fit beside it (`--mem` in compose-gen, `CLAUDE_MEM_LIMIT` for `claude-launch`).
- `CLAUDE_GPU=1`, which turns on the boot probe, the GPU line in `claude-healthcheck`, and
  a short GPU note in the session's managed memory (`/etc/claude-code/CLAUDE.md`, after the
  container facts every session gets), so the agent finds the tooling on its own.

Every image variant ships the vendor-neutral GL side (glvnd `libEGL`/`libGL`/`libOpenGL`,
Mesa llvmpipe as the software fallback, and the X client libraries Blender links even
headless). glvnd picks NVIDIA's EGL vendor when the device is attached and Mesa when it is
not. The image never carries NVIDIA driver libraries.

**The guard, `claude-gpu`.** The card is usually shared (a media server's NVENC transcodes,
an exporter), so GPU work goes through a polite preflight:

```
claude-gpu status            # ok | degraded (<reason>) | off, with card, driver, VRAM, NVENC, utilization
claude-gpu run -- <cmd>      # waits for the card, else runs on CPU; says which device ran and why
claude-gpu blender <args>    # Blender through the guard: Cycles on OptiX, else CUDA, else CPU
```

`run` checks the device-wide numbers (other tenants' usage included): at least
`CLAUDE_GPU_MIN_FREE_MIB` (2048) MiB free, utilization at most `CLAUDE_GPU_MAX_UTIL` (80%),
at most `CLAUDE_GPU_MAX_NVENC` (2) NVENC sessions. The 2048 MiB default is a modest
render (about 1 GiB) plus a reserve for new transcodes, which hold a few hundred MiB each.
A busy card is polled for `CLAUDE_GPU_WAIT` (120) seconds, then the job runs on CPU. A GPU
run that fails with an out-of-memory error is retried once on CPU. The child gets
`CLAUDE_GPU_DEVICE=gpu|cpu`; on CPU also `CUDA_VISIBLE_DEVICES=` and glvnd pointed at Mesa
(`__EGL_VENDOR_LIBRARY_FILENAMES`), so EGL programs render in software.
`claude-gpu env cpu` prints that contract.

**Blender.** `claude-blender-install` downloads the pinned Blender LTS for Linux x64,
verifies its SHA-256 before extracting (a mismatch deletes it and fails), and installs it
rootless and atomically into the shared `/cache/blender/<version>` under a lock, so one
install serves every container on the host; `blender` on `PATH` then runs it. It tries
blender.org, then two of its official mirrors (the checksum, not the host, is the trust).
Headless device choice uses Cycles' own `--cycles-device`, never a GUI preferences file;
`--log-level info` makes Cycles name the device it used (`Path tracing on: <card> (OptiX)`).
EEVEE and Workbench render with `-b` and no X server, through EGL. **Bumping Blender:**
pick the newest LTS, run Cycles' device list for CUDA and OptiX and a test render on each
on the oldest card you support, and update `BLENDER_VERSION`, `BLENDER_SHA256` and the
`PIN_EVIDENCE` note in `bin/claude-blender-install` together.

**When the GPU is unusable.** If the driver breaks under a running host (typically a driver
update without a reboot: `NVML: Driver/library version mismatch`), a GPU session still
boots: the log carries a `GPU DEGRADED` banner, the tmux status line shows it,
`claude-healthcheck` reports `gpu: degraded (<reason>)` without failing health, and GPU work
falls back to CPU. A **missing CDI spec** is different: Docker refuses to create the
container at all, which no image can degrade around. Regenerate the spec, or drop `--gpu`
and regenerate. Runbook: [docs/troubleshooting.md](troubleshooting.md#gpu-sessions---gpu).

