% AIMGR(1) Version 0.1.0 | aimgr Manual
% aimgr contributors
% 2026-11-08

NAME
aimgr - local AI model manager for Ollama and llama.cpp (llama)

SYNOPSIS
aimgr
aimgr COMMAND [ARGUMENTS]

DESCRIPTION
aimgr discovers, inspects, launches, downloads, updates, and removes local language models that are managed by Ollama and by the llama distribution of llama.cpp, can create abliterated copies of models, and can let a tool-capable local model work in a folder under guardrails (AGENT MODE). It runs on Linux and Windows. Installed models are always read from the backends themselves; a TOML catalog only adds friendly names, use cases, notes and tags. aimgr never sends telemetry. The network is used only for commands that say so: pull, update, search, browse, sources refresh, setup-backends, abliterate and abliterate setup, and for agent tools you approve one by one (web_fetch, web_search, gh, winget search).

With no arguments on a terminal, aimgr starts the interactive interface (tabs: Installed, Discover, Transfers, Servers, Settings; press ? for keys). Otherwise it prints help.

COMMANDS
tui
: Start the interactive interface. Needs a terminal on standard output.

version, --version
: Print the version, CPU and operating system.

probe
: Show whether each backend is available and its version.

list [--backend ollama|llama] [--filter TEXT] [--abliterated] [--use TAG] [--access open|signin|cloud] [--fit]
: List installed models, tab-separated, with catalog metadata (including access= and offline=). --use keeps models tagged good for TAG; --fit adds an advisory hardware-fit column.

hardware
: Show RAM and GPUs (NVIDIA via nvidia-smi if installed; AMD and others via /sys/class/drm) and how fit estimates are computed.

browse [--sort trending|downloads|recent] [--limit N]
: List GGUF text-generation repositories on Hugging Face without a query (network). Results are unvetted third-party repositories.

search TEXT [--limit N]
: Search Hugging Face for GGUF repositories (network). Results are untrusted data. Ollama has no documented public search API, so only llama results are offered.

chat BACKEND MODEL
: Talk to an installed model in the same interface as agent sessions (input between two rules, your messages shaded, Markdown replies, /clear, /compact, !command), without any tools: the model cannot see or change anything on the computer. For llama, aimgr starts a private loopback server for the session. Press c in the TUI.

chat --raw BACKEND MODEL [--ctx N] [--gpu-layers N|auto|all]
: The backend's own chat (ollama run, llama cli; llama with --offline). --ctx and --gpu-layers imply --raw. Options a backend cannot apply are rejected.

serve BACKEND [MODEL] [--host H] [--port P] [--ctx N] [--gpu-layers N|auto|all]
: Run an API server in the foreground. The default bind is 127.0.0.1; any other host requires an interactive confirmation. For ollama no model is given and a running daemon is reused. llama defaults to port 9931.

pull BACKEND ID, update BACKEND ID, remove BACKEND ID [--yes] [--dry-run]
: Download, re-download, or delete a model through the backend's own commands. Each prints backend, exact id and command and asks for confirmation unless --yes. remove is disabled for llama because it has no supported removal command.

agent ollama|llama MODEL [--dir DIR]... [--level LEVEL] [--steps N] [--timeout S] [--sandbox MODE], agent show|set|settings|reset
: Let a tool-capable model (Ollama capability `tools`) work in a folder: read files and, depending on its level, run commands and change files, each change approved by you. Without --dir it uses the current folder. See AGENT MODE.

schedule add|list|enable|disable|remove|run|run-due|results|install|uninstall
: Saved agent requests that run unattended (level read-only or inspect only; no shell, web, notifications or questions; anything needing approval is denied and shown in the result). `install` writes a systemd user timer that calls `run-due` every 15 minutes (you enable it). Linux only. See SCHEDULED TASKS.

setup-backends [ollama|llama|all] [--cpu] [--yes] [--dry-run]
: Windows only: download Ollama and/or llama.cpp from their official GitHub releases into aimgr's data folder (no installer, no admin rights), after showing the files and sizes and asking once. Without a name, whatever is missing. Each archive is checked against a SHA-256 pinned in aimgr before it is unpacked. Ollama: a discrete AMD GPU also gets the ROCm add-on. llama.cpp (build b12211): the Vulkan build when there is a real GPU (NVIDIA, AMD or Intel, normal drivers, no CUDA install), otherwise the CPU build; --cpu forces the CPU build. aimgr finds ollama.exe and llama.exe automatically; models for llama are downloaded with `aimgr pull llama OWNER/REPO:QUANT` into the Hugging Face cache (%USERPROFILE%\.cache\huggingface\hub).

abliterate setup, abliterate run OWNER/REPO [options]
: Create an abliterated copy (refusal direction removed by weight editing) of a full-precision safetensors model. See ABLITERATION.

SOURCES
`aimgr sources` manages where models are discovered: the bundled catalog, your models.toml, extra catalog files, catalog URLs (downloaded only by `aimgr sources refresh`, validated before replacing the cached copy) and Hugging Face compatible endpoints used by search and browse. Each can be enabled or disabled (also from the Settings tab: Enter or space toggles, u downloads a catalog URL); the list order is the precedence for catalog entries.

CATALOG
The bundled catalog (config/models.toml) is a dated snapshot of about 150 models generated by tools/catalog-gen/gen.py from ollama.com/library, registry.ollama.ai and the Hugging Face API; aimgr never contacts those services unless you ask it to. Each entry has an access field: open (no account needed to download; runs fully offline afterwards), signin (gated Hugging Face repo: account, accepted license and HF_TOKEN needed to download; offline afterwards), or cloud (Ollama cloud: runs remotely, needs sign-in and API usage, never offline; aimgr will not launch these). use_cases are derived hints (name patterns, registry capability badges, Hugging Face tags, GGUF context length), not benchmark results: coding, reasoning, vision, tools, chat, long-context, small, math, multilingual, creative-writing. About 47 abliterated community models are included and tagged abliterated; they are unvetted third-party uploads.

AGENT MODE
`aimgr agent ollama|llama MODEL` starts a session in the current folder (or the --dir folders). The first time a folder is used on a terminal, aimgr asks "Do you trust this folder?" and remembers the answer in $XDG_CONFIG_HOME/aimgr/trusted-dirs (never inside the project, so a cloned repository cannot trust itself); trusting a folder covers everything below it. Plain chat (`aimgr chat`) has no tools.

Levels. Each model has a level: `off` (chat only), `read-only` (file tools), `inspect` (plus read-only commands), `ask` (plus changes and other commands, each approved by you). Defaults follow the model: no tools -> off; under 7B -> read-only; 7B-30B -> inspect; 30B and up -> ask. Change them in the TUI Settings tab (on a model row: Enter = level, x = sandbox auto/bwrap/none, h = shell, w = web) or with `aimgr agent set ollama MODEL level=ask dirs=/a,/b steps=20 timeout=20 output_kb=64 allow=cmd sandbox=auto root=false shell=bash web=false subagents=true plan=false search_url=https://host/?q={q}`. `aimgr agent show` prints the effective values.

The session. On a terminal, chat and agent sessions take the whole screen (your previous screen comes back when you leave), like Claude Code: the conversation scrolls in the upper part, and the input box (two rules, the line you type, a status line) stays at the bottom. Your messages are shaded and marked ❯, the model's replies start with ● and are rendered as Markdown. While the model thinks or a tool runs, the status line shows a spinner, what is happening and for how long (and how many files a search has looked at). Keys: Esc while the model thinks or a tool runs interrupts that request (the reply is dropped, the session goes on; searches and OCR stop at the next file or page), Enter sends, Shift+Enter (or Alt+Enter) starts a new line, Up/Down recall earlier messages, PgUp/PgDn or the mouse wheel scroll the conversation (Ctrl+Home / Ctrl+End jump to the top / bottom), Ctrl-C clears the box or, on an empty box, ends the session, Ctrl-L repaints. You can type while the model works; Enter then queues the message. Without a terminal (pipes, NO_COLOR) the session is line-oriented: a "you>" prompt and plain replies. Commands:

    /help                 list the commands
    /mode [default|edits|plan]   bare /mode cycles default -> edits -> plan (like shift-tab in Claude Code)
    /plan                 plan mode: read tools and submit_plan only until you approve the plan
    /add-dir PATH         let the model use another folder too, for this session
    /clear                forget the conversation (settings and approvals stay)
    /compact              replace the conversation with a short summary written by the model
    /status               model, level, mode, folders, sandbox, shell, project notes, context size
    /rules                your allow/deny rules and this session's "always" answers
    /todos                the model's task list
    !COMMAND              run a command yourself in your shell, in the first folder, on the normal terminal screen
                          (sudo and installers can ask their questions; press Enter to come back); the model is told
                          it ran and its exit code
    /exit                 end the session

Approvals. Every change and every risky action shows exactly what will happen (diffs for edits, the full command for shells) and then a menu: 1. Yes, 2. Yes and don't ask again for this exact action this session (for file edits: allow all edits in these folders this session), 3. No. Choose with the arrow keys and Enter, the number keys, y / a / n, Esc (= No), or a mouse click. In a line-oriented session the same question is asked as `[y/N/a]`. Answering a on a file edit turns on edits mode: later edits inside the allowed folders are approved automatically (deletes, plan approval and worktree switches are always asked). Nothing is remembered across sessions; for that write rules (below).

Project notes. If the first folder contains AIMGR.md (or else AGENTS.md, or else CLAUDE.md), it is added to the instructions at the start of the session, like CLAUDE.md in Claude Code. Use it for build commands and conventions.

Files outside the folders. Reading outside the allowed folders is never automatic but never forbidden: you are asked each time (at every level). Secret-looking files (.env, keys, .ssh, ...) are refused below level ask and asked at ask. Writes stay inside the folders.

Tools. Reading: list_dir, read_file (text files; PDFs are converted with pdftotext, and a scanned PDF is OCRed with tesseract, first 8 pages), search_files (literal text), find_files (glob), ask_user (the model asks you), update_todos, load_skill (instruction files in ~/.config/aimgr/skills/*.md), spawn_agent (a read-only sub-agent in a fresh context; never more autonomy than its parent, no shell or web). Inspect: run_command (one command, no shell syntax) and notify. Ask: write_file, edit_file, move_file (never overwrites), make_dir, delete_file, edit_notebook_cell (Jupyter), run_shell (a real shell: bash, sh or dksh on Linux, PowerShell 5.1, pwsh or cmd on Windows), run_background / check_background / stop_background (long-running commands, at most 4, stopped when the session ends), enter_worktree / exit_worktree (an isolated git worktree on branch aimgr/NAME). With web=true: web_fetch and, with a search_url, web_search (https only, every request asked, results marked untrusted). MCP servers add their own tools (see MCP SERVERS).

Commands that run without asking (inspect and ask). File and text tools: ls, cat, head, tail, grep, find, wc, file, stat, du, df, pwd, tree, sort, uniq, cut, diff, cmp, comm, nl, tac, rev, strings, column, fold, fmt, jq, echo, printf, seq, checksums (md5sum, sha*sum, b2sum, cksum), pdftotext (to standard output), pdfinfo, ps, lscpu, lspci, lsusb, date, uname, whoami, id, hostname, which, nproc, uptime, free, lsblk, and the names in allow=. Their file arguments must be inside the folders (outside: asked); forms that write files are not automatic (sort -o, uniq IN OUT, pdftotext to a file, find -exec/-delete, tail -f, date -s). git: status, log, diff, show, blame, grep, ls-files, ls-tree, cat-file, rev-parse, describe, shortlog, show-ref, for-each-ref, merge-base, name-rev, count-objects, whatchanged, and the listing forms of branch, tag, remote and reflog (git branch NAME, git tag NAME, git remote add and similar are approvals). Package queries: apt (search, show, policy, list, depends, rdepends, madison), apt-cache, dpkg (-l, -L, -S, -s), dpkg-query, apk (search, info, list, policy), rpm (-q..., -V), dnf and yum (search, info, list, provides, repoquery, repolist), pacman (-Q..., -Ss, -Si, -Sl, -Sg, -Fl, -Fx, -Fo), zypper (search, info, packages, patterns, repos, what-provides) and winget list; in the sandbox they see the package databases read-only. Installing, removing and updating packages is never automatic: the model suggests the command and you run it (for example with !sudo apt install tesseract-ocr), or approve it at level ask. When a tool aimgr needs is missing (pdftotext, tesseract), the model is given the install command for your system (apt, dnf, pacman, zypper, apk, winget).

Commands that ask first. gh read-only views (repo view/list, issue and pr list/view/diff/checks/status, release/run/workflow list/view, search, status, api without -X/-f) because they contact GitHub, and run outside the network-less sandbox once approved; winget search and show (online sources). Other gh commands (pr merge, issue create, api -X ...) and --web are approvals at level ask and refused below it.

Rules. `aimgr agent set ollama MODEL allow_rule='run_command(git status*)' deny_rule='*(*.pem)'` adds rules of the form tool(pattern) where * matches any text. A matching deny rule always wins; an allow rule answers an approval prompt automatically (and says which rule did) but never overrides a refusal; a wildcard allow-rule for a shell command is ignored if the command contains ; | & < > $ ( ) ` { } ! ^ % \ or a newline. `rules=clear` removes them.

Sandbox. On Linux with bubblewrap, commands and shells run with read-only /usr and /etc, the folders writable only at level ask, a private /tmp and no network (sandbox=auto uses it when available, bwrap requires it, none turns it off). Windows has no sandbox: every shell command is shown with "NOT SANDBOXED" and asked. sudo, su, doas, pkexec, run0, gsudo and runas are refused unless root=true (then still asked).

Safety model. The approval prompt is the boundary: model output can never approve an action or change a setting; text it reads (files, command output, web pages, sub-agent reports, MCP results) is data. Every request and decision is appended to the audit log. One reply is capped at 4096 tokens (thinking included), so a model that loops ends on its own. For llama, aimgr starts a private server on a free loopback port, checks that the chat template supports tools, and stops it afterwards (it also dies if aimgr is killed). Models that print tool calls as text are detected and nothing is run. In the TUI press g on an installed model (Enter at the folder question = the folder aimgr was started in).

MCP SERVERS
At level ask, tools of MCP servers listed in $XDG_CONFIG_HOME/aimgr/mcp.toml are offered as mcp__ID__TOOL:

    [[mcp]]
    id = "files"
    command = ["python3", "/path/to/server.py"]
    read_only_tools = ["search"]

Every call asks unless the tool is in read_only_tools. Servers are programs you chose and are not sandboxed. Each call starts the server, sends the request and lets it exit (3x the agent timeout).

SCHEDULED TASKS
`aimgr schedule add ID ollama|llama MODEL --every 6h --dir DIR [--level read-only|inspect] [--steps N] (--task "text" | --task-file FILE)` saves a request; intervals 5m to 30d (or hourly, daily, weekly). `aimgr schedule run ID` runs it now; `run-due` runs every enabled task that is due (one at a time, guarded by a lock file); results are Markdown files in $XDG_STATE_HOME/aimgr/schedule/ID/ (`schedule results ID`). Nothing runs on its own until you `schedule install` and enable the systemd user timer yourself. Not available on Windows yet.

WINDOWS
Unzip the release and run aimgr.exe (no installer, no admin rights). `aimgr setup-backends` installs Ollama; `aimgr serve ollama` starts it. Settings are in %APPDATA%\aimgr, data and logs in %LOCALAPPDATA%\aimgr. Hardware detection uses GlobalMemoryStatusEx, nvidia-smi and the display-adapter registry. Agent sessions use PowerShell 5.1 by default (shell=pwsh or shell=cmd to change), paths look like C:/Users/name, and every shell command is asked because there is no sandbox. Colour and the boxed prompt are used in Windows Terminal (WT_SESSION); the old console gets the plain prompt. `aimgr setup-backends` installs Ollama and llama.cpp; aimgr's private llama server is placed in a job object so it ends when aimgr ends, even if aimgr is killed. Not available on Windows yet: scheduled runs, abliteration.

ABLITERATION
setup creates a Python virtual environment under the data directory and installs torch (CPU), transformers and helpers from PyPI (about 1.4 GB, network). run downloads the source model, measures the refusal direction with two prompt sets (public datasets mlabonne/harmful_behaviors and mlabonne/harmless_alpaca at pinned revisions, or --harmful/--harmless files), edits the weights, converts to GGUF with the bundled llama.cpp converter pinned to the commit of the installed llama build, quantizes with llama quantize, and registers the result in Ollama (--register none keeps only the GGUF). Options: --name, --quant, --layer-frac, --n-prompts, --holdout, --check-quality (perplexity before/after on wikitext-2), --ppl-text, --ppl-chunks, --force, --yes, --dry-run. The source model is never modified and existing models are never overwritten. Supported architectures: llama, mistral, qwen2, qwen3, gemma, gemma2 (only qwen2 has been tested); mixture-of-experts models are refused.

EXIT STATUS
0
: Success.

1
: Failure (backend unavailable, action refused or failed, cancelled by a declined prompt).

2
: Invalid command-line usage.

130
: A transfer or abliteration stage was cancelled.

ENVIRONMENT
XDG_CONFIG_HOME, XDG_DATA_HOME, XDG_STATE_HOME, XDG_CACHE_HOME, HOME
: Locate configuration, data, state and cache (fallbacks ~/.config, ~/.local/share, ~/.local/state, ~/.cache). On Windows: APPDATA (configuration), LOCALAPPDATA (everything else), USERPROFILE (home).

COLUMNS, WT_SESSION
: Width for agent replies when the terminal cannot be asked; WT_SESSION (Windows Terminal) enables colour on Windows.

NO_COLOR
: Respected: no colour in the interface or in agent sessions (plain prompt and plain replies).

AIMGR_RESOURCES
: Directory containing abliterate/ and llama-convert/ (default: ../share/aimgr relative to the executable).

FILES
$XDG_CONFIG_HOME/aimgr/models.toml
: User catalog overlay: [[model]] tables with backend, id, name, description, notes, use_cases, aliases, tags. Overrides bundled entries for the same backend and id. An invalid overlay is ignored with a visible message.

$XDG_CONFIG_HOME/aimgr/config.toml
: Sources ([[source]]), per-model agent settings ([[agent]]) and schedules ([[schedule]]); rewritten by aimgr (comments are not kept).

$XDG_CONFIG_HOME/aimgr/trusted-dirs
: Folders you trusted for agent sessions, one per line.

$XDG_CONFIG_HOME/aimgr/mcp.toml
: MCP servers for agent sessions.

FOLDER/AIMGR.md (or AGENTS.md, CLAUDE.md)
: Project notes read at the start of an agent session in that folder.

$XDG_STATE_HOME/aimgr/agent-audit.log
: JSON lines, one per agent tool request (time, model, tool, arguments, decision, reason, result size).

$XDG_STATE_HOME/aimgr/logs/
: Logs of server and background jobs.

$XDG_DATA_HOME/aimgr/abliterate/ and $XDG_DATA_HOME/aimgr/models/
: Abliteration environment, working files, and output GGUF files.

SECURITY CONSIDERATIONS
Subprocesses are started from argument vectors, never through a shell. Model ids, hosts, repos and paths are validated. Catalog text, backend output and search results are treated as untrusted and sanitized before display. aimgr never deletes model files itself. Public binding and every download or deletion need explicit confirmation. Abliterated models have no refusal behavior built in; detection of them (tag or name containing "abliterat") is a heuristic.

PRIVACY
No telemetry. Network use is limited to the commands listed in DESCRIPTION; hosts contacted are the backends' registries, huggingface.co, PyPI and download.pytorch.org.

LIMITATIONS
Hardware-fit numbers are advisory ranges at 4096 context. The llama backend cannot delete models. Windows: no agent sandbox, no scheduled runs, no abliteration; tested in a Windows 11 virtual machine without a GPU. OCR covers the first 8 pages of a scanned PDF. TUI resize handling has not been exercised in automated tests.

SEE ALSO
ollama(1), the llama.cpp documentation, https://github.com/ggml-org/llama.cpp

COPYRIGHT
Copyright 2026 aimgr contributors. SPDX-License-Identifier: GPL-2.0-only

LICENSE
aimgr is licensed under the GNU General Public License, version 2 only. The complete text is in the LICENSE file. Vendored components keep their own licenses (MIT: toml-zig, libvaxis, uucode, md-zig, llama.cpp converter; see vendor/*/LICENSE) and are GPL-2.0-compatible.
