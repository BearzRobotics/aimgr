# aimgr handoff (2026-11-08, after release 0.2.0)

Read this first, then `ai/AGENTS.md` (how to work here) and `ai/SPEC.md` (what aimgr must do). Design decisions
with their reasons are in `docs/decisions/0001`-`0012`; the user-facing reference is
`docs/manpages/aimgr.1.md`.

## What aimgr is
An offline-first manager for local language models on **Ollama** and **llama.cpp** (the unified `llama`
command), for Linux and Windows. Zig 0.17.1, GPL-2.0-only, no system libraries; every dependency is vendored
under `vendor/` (toml-zig, libvaxis, uucode, md-zig, llama-convert; each has a `VENDORED.txt` pin).
Repository: https://github.com/BearzRobotics/aimgr (public). Owner: BearzRobotics (Dakota).

Main features: TUI (Installed, Discover, Transfers, Servers, Settings tabs) and CLI; a bundled ~150-model
catalog with access level (open / signin / cloud) and good-for tags; sources; hardware fit estimates;
download / update / remove through the backends; abliteration (Linux); and **agent mode**: tool-using local
models under a policy engine, with a Claude Code style full-screen session.

## State
- **Release:** v0.2.0 is published: source tarball, static Linux x86_64 build, Windows x86_64 zip (with .pdb)
  and SHA256SUMS. Both binaries were built from the source tarball. Everything is committed and pushed to
  `main`; the working tree is clean.
- **Tests:** `zig build test` passes 145/145 (debug build: leaks and safety checks are on).
- **Version:** `src/root.zig` (`version`), `build.zig.zon`, and line 1 of the man page. Bump all three.

## Code map (src/, ~15k lines)
| Area | Files |
|---|---|
| Entry, commands | `main.zig` (dispatch, usage), `*_cmd.zig` (agent, schedule, sources, launch, manage, abliterate) |
| Backends | `backends/ollama.zig`, `backends/llama.zig` (CLI adapters), `backend.zig`, `inventory.zig`, `launcher.zig`, `supervise.zig` (foreground chat/serve, signals) |
| Catalog, sources | `catalog.zig`, `catalog_io.zig`, `sources*.zig`, `discover.zig` (HF search/browse), `http.zig` |
| Platform | `platform.zig` (pids, kill, interrupts, PATH, terminal size, Windows job object), `config.zig` (XDG / APPDATA paths), `hardware.zig` (/proc, /sys, nvidia-smi, Windows registry), `netstat.zig` |
| Windows setup | `setup_backends.zig` (pinned Ollama v0.40.15 and llama.cpp b12211 zips, SHA-256 checked) |
| TUI | `tui/` (libvaxis; `term.zig` is the backend, `app.zig` keys/actions, `draw.zig`, `settings_view.zig`) |
| Agent core | `agent/policy.zig` (pure policy: levels, paths incl. Windows, command classification, package/gh/git rules, allow/deny rules), `agent/tools.zig` (tool schemas and implementations, sandbox argv, PDF/OCR), `agent/calls.zig` (dispatch, approvals `ask()`), `agent/extra.zig`, `agent/workflow.zig` (background tasks, worktrees) |
| Agent session | `agent/run.zig` (system prompt, `converse` loop, slash commands, `!command`, cancellable model request), `agent/ui.zig` (**full-screen UI**), `agent/activity.zig` (live status + Esc cancel flag), `agent/env.zig` (Env, Input, State, audit log), `agent/chat.zig` (Ollama and OpenAI-style request/response, 4096-token reply cap), `agent/llama_server.zig` (private llama server) |
| Other agent | `mcp.zig` (stdio MCP client), `schedule*.zig` (unattended runs, systemd user timer), `agent/pkghint.zig` (install hints per distro), `agent/settings.zig`, `agent/capcache.zig` |

### How a session runs
`agent_cmd.launch` checks the backend, picks the sandbox, starts a private llama server if needed, then
`finish`. On a colour terminal `fullScreen` starts `ui.Ui` on the main thread and runs `run.session` on a
worker thread: the worker writes to the transcript through `Ui.writer()` (ANSI colour codes become styles),
blocks in `Ui.nextLine` / `Ui.choose` for input and approval menus, and `!command` hands the terminal over with
`suspendTerm` / `resumeTerm`. Without a colour terminal the same `run.session` runs line-oriented (`you>`).
`aimgr chat` is the same session at level `off` (no tools); `aimgr chat --raw` runs the backend's own CLI.

## How to build, test and check
```
zig build                          # zig-out/bin/aimgr (+ share/aimgr)
zig build test                     # 145 tests
zig build -Dtarget=x86_64-windows  # cross-compile; check this after any platform-touching change
```
- **Interactive testing:** use GNU `screen` in a real pty (not tmux), with isolated `XDG_CONFIG_HOME` /
  `XDG_STATE_HOME` in a scratch folder (never isolate `XDG_CACHE_HOME`: llama then finds no models). Example:
  `screen -dmS s -L -Logfile LOG bash -c "aimgr agent ollama gemma4:12b 2>ERR"`, send keys with
  `screen -S s -X stuff '...'`, run `screen -S s -X logfile flush 1`, then render the screen with
  `tools/vt-render.py LOG 80 24`. screen's log lags; flush before reading. A mouse click can be sent as
  `screen -S s -X stuff $'\e[<0;COL;ROWM\e[<0;COL;ROWm'`.
- **Always read stderr** of every run (debug builds print leaks and safety traces there). A grep for
  "error|failed" is not enough: check the files are empty apart from `debug(vaxis)` lines.
- **Do not delete files inside `.zig-cache/o/`**: the cache index keeps pointing at them and `zig build test`
  then reports "run test failure ... FileNotFound". If it happens, delete the whole `.zig-cache`.
- **Windows:** a Windows 11 VM (`win11`, libvirt `qemu:///system`, IP 192.168.122.202) has OpenSSH and a local
  test account `aimgr` (ask the user for the password; it is deliberately not written down). It has Ollama and
  llama.cpp installed by `setup-backends`, models `qwen3:1.7b` (Ollama) and `ggml-org/Qwen3.5-0.8B-GGUF:Q8_0`
  (llama; this one loops while thinking, use a bigger one to test llama chat). SSH has no console, so the
  full-screen UI and TUI can only be tested by the user in Windows Terminal. For readable crash traces, copy
  the debug `aimgr.exe` **and** `aimgr.pdb` into one folder (the .pdb must keep its name).
- Machine: AMD RX 7800 XT (12.9 GB VRAM), 32 GB RAM, Ubuntu; bubblewrap works (sandbox on).

## Rules the user cares about
- Commit and push only when asked; the user usually asks for commit + push at the end of a piece of work.
  Releases: source tarball plus Windows and Linux x86_64 builds built from it, with SHA256SUMS.
- Offline-first means nothing leaves the machine and nothing acts unattended without explicit approval; it
  does not mean "no network, no agents, no scheduling".
- Keep docs complete: man page, README, SPEC, and a decision record for design changes.
- The user tests by hand and reports what they see; treat pasted output as the source of truth and reproduce
  before fixing. Report honestly what was and was not verified.
- Agent UX target is Claude Code: full screen, clear separation of user and model text, menus for approvals,
  scrollback, Esc to interrupt, `!command`, folder trust, project notes.
- The user's own Zig libraries are preferred where they fit (toml-zig, md-zig; also gtroff-zig, dkman exist).
  Their shell `dksh` is supported as an agent shell.
- Never delete model files directly; clean up test downloads with exact paths; kill only verified PIDs.

## Known limits and open items
- **Windows:**
  - no agent sandbox (every shell command is shown as NOT SANDBOXED and approved);
  - no scheduled runs (would need Task Scheduler);
  - no abliteration;
  - full-screen UI and TUI on Windows are untested by me;
  - GPU detection on real Windows hardware is untested (the VM has no GPU).
- **Esc** drops the reply but the model server keeps generating it in the background (no cancel API used).
  Ctrl-C while the model is busy ends the session immediately.
- **OCR** covers only the first 8 pages of a scanned PDF; most of the user's `/stuff/Books` library (28k PDFs)
  is scanned. Paging further into a scanned book is not implemented.
- **search_files** skips PDFs and other binary types by name; searching inside a whole library still means a
  long walk (progress is shown).
- **Not verified live:** `web_search` (needs an endpoint), `notify`, `schedule install` with a real systemd
  timer, gh commands, winget on the VM (the test account never had a desktop login when tested), abliteration
  on non-Qwen2 models, TUI resize.
- Ideas raised and not built: a generic OpenAI-compatible backend (LM Studio, Jan, LocalAI, KoboldCpp, vLLM:
  one adapter would cover them all); persistent "always" answers beyond the session (rules exist for that);
  streaming replies token by token in the full-screen UI.

## Suggested next steps
1. Ask the user to try the 0.2.0 full-screen session in Windows Terminal (VM or laptop) and fix what they see.
2. Streaming replies in the UI (Ollama `stream: true`, OpenAI SSE) so long answers appear as they are written;
   this also allows a real cancel by closing the connection.
3. Generic OpenAI-compatible backend.
4. OCR beyond page 8 (a `pages` argument for read_file on PDFs).
5. Windows scheduled runs via Task Scheduler, if the user wants them there.
