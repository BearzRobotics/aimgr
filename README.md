# aimgr

Local AI model manager for **Ollama** and the **llama** distribution of llama.cpp.
Linux and Windows, Zig 0.17.1, no system libraries. See `docs/manpages/aimgr.1.md` for the full reference
and `ai/SPEC.md` for the requirements.

```
zig build                 # binary in zig-out/bin, resources in zig-out/share/aimgr
zig build test
zig build -Doptimize=ReleaseSafe
./zig-out/bin/aimgr       # TUI on a terminal; 'aimgr help' for commands
```

Highlights: a ~150-model bundled catalog with access (open / sign-in / cloud) and good-for tags, `aimgr browse`, `aimgr list --fit`, `aimgr hardware`, `aimgr search`, `aimgr chat|serve|pull|update|remove`,
`aimgr agent` (let a tool-capable local model inspect a directory under strict, per-model guardrails), `aimgr abliterate` (create an abliterated copy of a model).

## Chat and agent sessions

`aimgr chat <backend> <model>` (or `c` in the TUI) and `aimgr agent <backend> <model>` (or `g`) share one
full-screen interface like Claude Code: the conversation scrolls (PgUp/PgDn, mouse wheel) above an input box pinned at the bottom with a live status line; approvals are a menu you answer with arrows, numbers or the mouse; your sent messages are shaded and marked `❯`,
replies start with `●` and are rendered as Markdown. Chat has no tools; `aimgr chat --raw` runs the backend's own chat.

### Agent

`aimgr agent <ollama|llama> <model>` (or `g` in the TUI) works in the current folder after you trust it once.
Like Claude Code: `AIMGR.md` / `AGENTS.md` / `CLAUDE.md` project notes, approvals with `y` / `a` (always this
session), `/mode` (default, edits, plan), `/add-dir`, `/compact`, `/status`, `/rules`, `!command` to run your own
command, Markdown replies, PDF reading (with OCR via tesseract), read-only package queries (apt, dnf, pacman, apk,
rpm, zypper, winget), git and gh. Per-model level, sandbox, shell and web are set in the TUI Settings tab.

## Windows

`zig build -Dtarget=x86_64-windows`, or use the release zip. `aimgr setup-backends` downloads Ollama (official
release, SHA-256 pinned) into aimgr's own folder; no admin rights needed. The agent uses PowerShell 5.1 by default
(`pwsh` and `cmd` are options). Windows has no sandbox, so every command the model runs is shown and approved.
`aimgr setup-backends` also installs llama.cpp (Vulkan build with a GPU, CPU build otherwise). Not on Windows yet:
scheduled agent runs, abliteration.

Vendored, pinned sources (no network at build time): `vendor/toml-zig`, `vendor/libvaxis`,
`vendor/uucode`, `vendor/llama-convert`, `vendor/md-zig` (see each `VENDORED.txt`). Design decisions: `docs/decisions/`.

License: GPL-2.0-only (see `LICENSE`). Vendored components keep their own licenses.
