# aimgr

Local AI model manager for **Ollama** and the **llama** distribution of llama.cpp.
Linux, Zig 0.17.1, no system libraries. See `docs/manpages/aimgr.1.md` for the full reference
and `ai/SPEC.md` for the requirements.

```
zig build                 # binary in zig-out/bin, resources in zig-out/share/aimgr
zig build test
zig build -Doptimize=ReleaseSafe
./zig-out/bin/aimgr       # TUI on a terminal; 'aimgr help' for commands
```

Highlights: a ~150-model bundled catalog with access (open / sign-in / cloud) and good-for tags, `aimgr browse`, `aimgr list --fit`, `aimgr hardware`, `aimgr search`, `aimgr chat|serve|pull|update|remove`,
`aimgr agent` (let a tool-capable local model inspect a directory under strict, per-model guardrails), `aimgr abliterate` (create an abliterated copy of a model).

Vendored, pinned sources (no network at build time): `vendor/toml-zig`, `vendor/libvaxis`,
`vendor/uucode`, `vendor/llama-convert` (see each `VENDORED.txt`). Design decisions: `docs/decisions/`.

License: GPL-2.0-only (see `LICENSE`). Vendored components keep their own MIT licenses.
