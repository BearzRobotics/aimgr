# 0008: Hardware advice, online discovery, packaging (milestone 6)

Status: accepted. Date: 2026-11-08.

## Hardware (`src/hardware.zig`)
- RAM from /proc/meminfo. GPUs: `nvidia-smi --query-gpu=name,memory.total,memory.used` when
  installed (NVIDIA's driver exposes no VRAM in sysfs), otherwise `/sys/class/drm/card*/device/`
  `mem_info_vram_{total,used}` (amdgpu). GPUs with < 1 GiB VRAM are treated as integrated and ignored.
  Intel/other GPUs without those files are not reported.
- Earlier in the project a "no GPU" conclusion was drawn from missing nvidia-smi/rocm-smi; this
  machine has an AMD RX 7800 XT (12.9 GB). The abliteration venv installs CPU-only torch, so it
  does not use that GPU (a ROCm torch build would, but is a much larger download; not done).
- Fit estimate = range, never a promise. Weights: reported size when the backend gives one
  (Ollama), else parameter count parsed from the name x bits per weight of the quant in the
  id (flagged "estimated"). KV cache: 0.01-0.075 MiB per token per billion parameters (strong
  GQA .. full multi-head) at 4096 context; runtime overhead 0.3-0.8 GB. Verdicts: fits in GPU,
  may fit, needs CPU/RAM offload, CPU only, unlikely, unknown. MoE and unusual architectures
  are not modelled (e.g. gpt-oss-20b is judged as a dense 20B). "8x7b" style names are not guessed.
- Surfaces: `aimgr hardware`, `aimgr list --fit`, TUI detail panel and Settings.

## Online discovery (`src/discover.zig`)
- `aimgr search TEXT` calls `https://huggingface.co/api/models?search=..&filter=gguf&sort=downloads`
  with `std.http.Client`. Explicit only. Ids must pass the repo-id validator; text is
  percent-encoded; the JSON strings are copied (a use-after-free was found and fixed:
  std.json returns slices into the response buffer).
- Ollama: no documented public search API, so none is offered.
- TUI: key `n` on Discover runs `aimgr search` as a job (UI stays responsive) and loads the
  tab-separated output into the list as "online" rows; `d` downloads the default quant.
- Results can contain any third-party repo; nothing is downloaded without the usual confirmation.

## Packaging
- `zig build` installs `bin/aimgr`, `share/aimgr/{abliterate,llama-convert}` and
  `share/doc/aimgr/` (man page source in pandoc markdown). `zig build -Doptimize=ReleaseSafe`
  gives an 11 MB static binary; resources are found relative to the executable.
- README.md and docs/manpages/aimgr.1.md added.

## Not done / not verified
- No `.deb`/tarball scripts, no rendered man page (pandoc not required or invoked), no shell completion.
- Fit estimates were only sanity-checked against this machine's models, not measured.
- TUI resize, chat inside the TUI, and the `setup` job from the TUI remain unexercised.
- SIGKILL escalation prompt never exercised.
