aimgr — Local AI Model Manager
1. Purpose
Offline-first terminal application for discovering, understanding, launching, downloading, updating, and deleting local language models managed by Ollama and the llama distribution of llama.cpp.
2. Scope
- Linux first, Ubuntu 24.04 target; portable backend design.
- Zig implementation with a pure-Zig (libvaxis) TUI, plus noninteractive commands.
- Installed models are authoritative from each backend, not the catalog.
- TOML metadata database supplies friendly names, use cases, notes, aliases, and recommended launch profiles.
- No cloud inference or telemetry. Network used only for explicit catalog search, pull, and update checks.
3. Features
Inventory
- Detect executable availability and version; mark backend unavailable if missing.
- Enumerate `ollama list` and `llama cli --cache-list` (see docs/decisions/0001); verify output format against installed versions and fail visibly if parsing unsupported.
- Preserve backend-specific IDs and distinguish variants, quantizations, and duplicate models across backends.
- Show installed size where reported; avoid invented metadata.
- Merge catalog metadata by exact backend+ID first, then explicit aliases; unknown models remain visible.
Launch
- Ollama chat: ollama run <model>; llama chat: llama cli -hf <repo> or supported local model selector.
- Ollama API: detect existing shared daemon, start ollama serve only when needed; model selection/preload is separate.
- llama API: llama serve with selected model and configured host/port.
- Launch profiles for context, GPU layers, host, port, and backend-specific flags; validate each backend's supported flags.
- Default API bind 127.0.0.1, never public interfaces without explicit confirmation.
- CLI mode restores terminal after child exits. Server mode shows status/logs and offers controlled stop.
- Launch installed models offline; no implicit download.
Model management
- ollama pull, ollama rm using argv-based child processes.
- `llama download -hf`; removal/update must use supported CLI mechanisms confirmed at runtime. If unavailable, disable action with explanation; never delete cache internals by guessing.
- Update = explicitly re-pull selected identifier; display warning that mutable tags may change. Never claim revision checks without evidence.
- Catalog search optional, explicit and network-dependent. No auto-pull.
- Show progress and errors from subprocesses; cancellation sends graceful termination then escalation with user approval.
- Confirm deletion with exact backend and identifier; warn when duplicates exist.
Agent mode (tool use)
- `aimgr agent <ollama|llama> <model> [--dir DIR]...` lets a tool-capable model inspect the computer through a fixed set of tools (list_dir, read_file, search, stat, run_command, write_file) in a loop: the model asks, aimgr decides, aimgr executes and returns the result.
- Only models that report tool support are used: Ollama's `tools` capability (`ollama show`), or, for llama, `chat_template_caps.supports_tools` from the llama server's /props once it is running. Both backends are supported. For llama, aimgr starts a private llama server for the session (loopback, free port 19900-19999, started through `setpriv --pdeathsig TERM` so it dies with aimgr even on SIGKILL) and stops it when the session ends.
- Every request goes through the policy engine (section 6). Nothing the model writes can approve itself: approvals come only from the user's keypress, and the prompt shows the exact argv/path/diff, never the model's description of it.
- Autonomy is a per-model setting ("level"): `off` (chat only), `read-only` (file tools inside the allowed directories), `inspect` (adds an allowlist of read-only commands), `ask` (adds any other command or file write, each needing approval). Defaults are derived from what the model can do (no tools -> off; small models -> read-only; mid-size -> inspect; large -> ask) and every default can be overridden per model: level, allowed directories, step limit, command timeout, output cap, extra allowed read-only commands, sandbox, and whether root commands may even be requested.
- Commands run as argument vectors, never through a shell; a plan that needs a pipe or `&&` is split into separately approved steps. Optional `bwrap` (bubblewrap) sandbox: read-only view of the allowed directories, no network.
- Privilege escalation (`sudo`, `su`, `doas`, `pkexec`) and shell interpreters (`sh -c`, `bash -c`, ...) are denied unless the model's setting `allow_root` is explicitly true, in which case they are still approval-gated with a warning.
- Every tool request, decision (auto/asked/denied/approved) and result size is appended to an audit log in the state directory.
- File and command output returned to the model is untrusted data (prompt injection): it can never raise the autonomy level or approve an action.
TUI
- Tabs: Installed, Discover, Transfers, Servers, Settings.
- Keyboard: arrows/j/k, Enter, / search, c CLI, s server, d download, u update, x delete, r refresh, q quit.
- Detail panel: name, backend, exact ID, description, use cases, size, quantization if known, hardware fit estimate and profile.
- Search/filter/sort; accessibility: high contrast, no reliance on color, respect NO_COLOR.
- All errors remain visible and actionable.
Hardware
- Read Linux memory from /proc/meminfo; GPU from system tools when available.
- VRAM estimation is advisory, includes context/KV-cache overhead and quantization uncertainty.
- Do not promise full GPU fit or use fixed layer count as universal setting.
4. Architecture
- src/main.zig: CLI entry and dispatch.
- src/backend.zig: backend interface, typed model records and capability flags.
- src/backends/ollama.zig: Ollama adapter.
- src/backends/llama.zig: llama.cpp adapter.
- src/inventory.zig: discovery and merge.
- src/catalog.zig: TOML metadata loading and matching.
- src/process.zig: safe argv process execution and supervision.
- src/launcher.zig: launch profiles and validation.
- src/hardware.zig: RAM/VRAM inspection.
- src/agent/: agent mode (policy.zig: command/path classification; tools.zig: tool schemas and execution with limits; chat.zig: Ollama chat API with tools; run.zig: the loop, approvals, audit log). Per-model settings live in config.toml.
- src/tui/: terminal interface (term.zig backend wrapper, model, draw, app, jobs).
- src/config.zig: user settings and XDG paths.
- config/models.toml: bundled seed descriptions.
Backend interface concepts: probe, list, pull, remove, launch_chat, launch_server, capabilities, inspect. Unsupported operations must be explicit.
5. Configuration
- User config: $XDG_CONFIG_HOME/aimgr/config.toml or ~/.config/aimgr/config.toml.
- User catalog overlay: $XDG_CONFIG_HOME/aimgr/models.toml.
- Cache/state: XDG cache/state locations, not model blob duplication.
- Per-model agent settings: `[[agent]]` tables in config.toml (backend, id, level, dirs, max_steps, timeout_s, max_output_kb, allow_commands, sandbox, allow_root).
- Backend profiles stored separately; retain user overrides across catalog updates.
- TOML parser must be vendored and pinned, or implemented internally; never silently fetch dependencies during build.
6. Security
- No shell interpolation for identifiers, paths or arguments; spawn via argv.
- Confirm destructive operations and public server binding.
- Treat model metadata, catalog results, and subprocess output as untrusted data.
- Never auto-execute model-supplied instructions, with one bounded exception: agent mode (section 3). There, read-only operations inside the user-chosen directories (and, at level `inspect`, allowlisted read-only commands) run without a prompt; everything else needs per-action approval or is denied outright. The policy engine is a pure, unit-tested module (src/agent/policy.zig); the model cannot change its own level, directories or allowlists.
- Protect terminal state on errors and signals; avoid logging secrets.
- Avoid arbitrary model-file deletion; use supported backend operations.
7. Build and dependencies
- Zig version pinned after inspecting developer environment; avoid unsupported stdlib assumptions.
- TUI backend: libvaxis (pure Zig), vendored and pinned under vendor/ together with its dependency uucode; no system terminal library is required. src/tui/term.zig is the only file that touches the backend.
- Other third-party source dependencies vendored and license-checked.
- zig build, zig build test, zig build run -- ....
- Library-like modules independent of TUI; no unnecessary global mutable state.
8. Delivery milestones
1. CLI foundation: probe/list, typed backend adapters, tests with fixtures for real command output.
2. TOML catalog and human-readable descriptions, CLI filtering.
3. Safe launch chat/server, supervision and logs.
4. Pull/update/remove with confirmation and progress.
5. TUI, search, shortcuts, error recovery.
6. Hardware advice, online discovery, polishing and packaging.
9. Acceptance criteria
- Correctly discovers installed models from both backends with no network.
- Unknown models display with exact identifier.
- Running chat restores terminal afterward.
- Starting server defaults to localhost and reports listening status accurately.
- Pull/update/remove show exact backend and do not operate on another backend's storage.
- Unsupported llama deletion is disabled rather than guessed.
- Parser fixtures and process error cases are tested.
- Agent mode: a model without tool support is refused; read-only requests inside the allowed directories run without a prompt; writes, deletions, unknown commands and anything outside the directories are asked or denied; sudo/su and shell interpreters are denied by default; the audit log records every request; policy tests cover traversal, symlinks and argument tricks.
- TUI remains responsive during long downloads and handles resize and cancellation.
10. Open validation items
- Capture llama ls --help, llama ls, llama pull --help, llama serve --help from installed version.
- Capture ollama list, ollama --version, ollama show --help.
- Confirm Zig version (done: 0.17.1).
- Verify exact llama cache removal facilities before enabling delete.
