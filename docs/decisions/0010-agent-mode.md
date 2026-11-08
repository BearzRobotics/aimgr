# 0010: Agent mode (tool use) and the exception to "never auto-execute"

Status: accepted and implemented for Ollama (2026-11-08); llama support is a follow-up.

## Why
Running `ollama run` through aimgr gives a chat that cannot look at the machine ("I can't access
/stuff/Books"). Tool-calling models (Ollama capability `tools`) can ask the host to run functions.
The user wants that, with guardrails: inspect freely, ask before anything destructive.

## Conflict with the spec
SPEC section 6 said aimgr never auto-executes model-supplied instructions. Agent mode needs a
bounded exception, now written into the spec: read-only operations inside user-chosen directories
run without a prompt; everything else needs per-action approval or is denied.

## Design
- **Loop:** user message -> model reply -> if it contains tool calls, the policy engine decides each
  (auto / ask / deny); allowed ones execute with limits; results are fed back; repeat up to
  `max_steps`.
- **Levels (per model):** off | read-only | inspect | ask. See SPEC section 3. Defaults derive from
  capability and size (no tools -> off; < 7B -> read-only; 7-30B -> inspect; >= 30B -> ask) because
  small models are unreliable at tool use; each is overridable per model in config.toml.
- **Policy is data-driven and pure:** classify(argv) -> auto | ask | deny, with reasons; path
  resolution with `..` and symlink checks against the allowed directories. Unit-tested, including
  hostile cases.
- **No shell:** commands are argv lists; `;`, `&&`, `|`, redirects and `$(...)` are never interpreted.
  A request whose argv[0] is a shell interpreter is denied. `sudo/su/doas/pkexec` are denied unless
  `allow_root` is set for that model, and are then approval-gated with a warning (they also cannot
  prompt for a password: stdin is closed).
- **Approvals:** typed by the user at the terminal; the prompt prints the exact argv / path / diff.
  Tool output and file contents are untrusted and can never approve anything.
- **Limits:** per-command timeout, output cap (default 64 KiB returned to the model), file read cap,
  step cap. Optional `bwrap` sandbox (read-only bind of allowed dirs, no network) when installed.
- **Audit log:** JSON lines in `$XDG_STATE_HOME/aimgr/agent-audit.log`.
- **API:** Ollama `/api/chat` with `tools` (non-streaming) over loopback HTTP. llama-server
  (OpenAI-style tools) is a follow-up. Network model downloads are not involved.

## Not goals
No autonomous background agents, no web access tool, no persistent memory, no editing outside the
allowed directories, no `yolo` mode that skips approvals.

## Implementation map
- `src/agent/policy.zig`: levels, defaults, path normalization/containment (rejects `..` even un-normalized),
  secret-looking names, command splitting (no shell syntax), command classification. Pure, heavily tested.
- `src/agent/tools.zig`: tool schemas offered per level, executors with limits, symlink-aware path resolution,
  bubblewrap argv builder and availability probe.
- `src/agent/chat.zig`: Ollama /api/chat with tools over loopback HTTP (`http.postJson` refuses any
  non-loopback plain http).
- `src/agent/run.zig`: the loop, approvals (one shared stdin reader), JSON-lines audit log.
- `src/agent/settings.zig`: per-model `[[agent]]` tables in config.toml; `sources_io` preserves them when
  sources change and vice versa.
- `src/agent_cmd.zig`: `aimgr agent <ollama> <model> --dir ...`, `show`, `set`, `settings`, `reset`.
- TUI: key `g` on Installed (asks for a directory unless one is stored), runs the same command on the real
  terminal and returns; the detail panel shows "Agent mode: available - default level ...".

## Behavior notes
- Tool support comes from `ollama show` (Capabilities: tools). Models without it, cloud models, a missing
  daemon, a missing directory and `/` as the directory are all refused with a message.
- `read_file`/`list_dir` return paths relative decisions on the *lexical* path first, then verify the real path
  after symlink resolution is still inside the allowed directories.
- The model only sees tools its level allows; a call to any other tool is denied by name as well.
- Approval prompts print the exact argv or a write preview (first 12 lines). A declined action is reported to the
  model as "DENIED: the user declined" and the audit log records it.
- Sandbox: `auto` uses bubblewrap when it works (probe runs `bwrap --ro-bind / / --unshare-all true`); commands then
  see /usr, /etc read-only, the allowed directories read-only (read-write only at level `ask`), a private /tmp,
  no network. Without it the policy layer is the only protection and the session banner says "sandbox: off".

## Verified (real runs, 2026-11-08)
gemma4:12b (11.9B, tools): list_dir inside /stuff/Books auto-approved; read of /etc/passwd denied by policy and
explained by the model; in a scratch dir at level `ask`: `grep -rn needle .` ran automatically inside bubblewrap,
file creation showed a preview and happened only after `y`, `rm b.txt` was asked and declined (file kept);
audit log lines recorded each. TUI `g` started a session and returned to the TUI. 60+ policy/parsing unit tests,
including `..`, sibling-directory prefixes, secret names, shell metacharacters, find/git/tail flags, sudo,
interpreters and wrappers.

## Known limits
- Ollama only; llama-server tool calling is not implemented.
- Small models call tools badly or miscount (a 12B model misreported a folder count after reading the listing
  correctly): the policy keeps that harmless, but answers still need checking.
- Without bubblewrap, an approved command runs with the user's full privileges.
- No streaming: the reply appears when complete. Context is `num_ctx = 8192` for the session.
- Prompt-injection resistance is structural (output cannot approve or change settings), not a promise that a model
  will never be misled into asking for something unwise; every non-read-only action still needs the user.
