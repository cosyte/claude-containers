<!-- claude-containers: GPU session note. Written to /etc/claude-code/CLAUDE.md at boot
     because this container has CLAUDE_GPU=1; do not edit it here, it is rewritten. -->
## GPU (this session has the host's NVIDIA GPU)

- Check it first: `claude-gpu status`. `ok` names the card, driver, free VRAM, NVENC
  sessions and utilization; `degraded (<reason>)` means the GPU is unusable right now
  and GPU work falls back to CPU. The card is shared with other tenants (for example a
  media server's hardware transcodes): never assume it is idle or yours alone.
- Run GPU work through the guard: `claude-gpu run -- <cmd>`. It waits for free VRAM,
  falls back to CPU when the card stays busy, retries a GPU out-of-memory failure once
  on CPU, and prints which device ran. Your program reads `CLAUDE_GPU_DEVICE`
  (`gpu`|`cpu`) to pick its backend. Keep jobs modest: minutes, not hours, and well
  under the card's VRAM.
- Blender: `claude-blender-install` once (a pinned, checksum-verified build into the
  shared `/cache`), then `claude-gpu blender -b file.blend -f 1`: Cycles on OptiX, else
  CUDA, else CPU. Add `--log-level info` to see Cycles name the device it used.
  EEVEE and Workbench render headless on the GPU through EGL (no X, leave DISPLAY
  unset).
- OpenGL/EGL offscreen (VTK, PyVista, build123d previews): EGL picks the NVIDIA driver;
  on CPU the guard points it at Mesa llvmpipe. The image ships GL (glvnd + Mesa): do not
  put your own libGL/libEGL on `LD_LIBRARY_PATH`, a private copy shadows the NVIDIA one.
- CUDA: use userspace built for a CUDA version that still supports this card
  (`nvidia-smi --query-gpu=compute_cap --format=csv`; CUDA 13 dropped compute capability
  below 7.5, so an older card needs CUDA 12.x wheels such as `cupy-cuda12x`).
- Temp and throwaway venvs go under `/scratch` (TMPDIR, a RAM tmpfs of a few GiB) or the
  shared `/cache`, never `/workspace`.
