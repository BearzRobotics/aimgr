# 0011: Extended agent tools (shell, planning, sub-agents, web, scheduling, ...)

Status: accepted 2026-11-08. Implemented in tranches; the table says what exists.

## Why
Agent mode started deliberately narrow (file tools + an allowlisted argv runner). Claude Code's own model is
"powerful tools, a permission prompt in front of the dangerous ones". The user asked for a real shell (including
their own `dksh`), and for the rest of the tool families, noting that offline-first does not mean "never
network/agents/scheduling", only "never without explicit user action".

## Principles (unchanged by the extension)
1. The approval prompt is the boundary. It shows the exact action; model text cannot answer it.
2. Anything that changes state, runs unreviewed code, or leaves the machine needs a fresh keypress each time.
3. Output coming back (files, commands, web pages, sub-agent reports, MCP results) is untrusted data.
4. Autonomy never increases implicitly: a sub-agent <= its parent; a scheduled run <= `inspect`; plan mode <= read.
5. Defaults are narrow; each capability is a per-model setting that the user turns on.

## Shell
`run_shell` at level `ask` only. Shells: bash, sh, dksh (`dksh -c <string>`; dksh is a C-like scripting shell, not
POSIX, so a model must be told which shell it is talking to: the tool description states it). Sandbox (bubblewrap):
read-only /usr and /etc, allowed directories read-write, private /tmp, no network, plus a read-only bind of the shell
binary's own directory when it lives outside /usr (dksh in ~/.local/bin). Warnings (not blocks) for rm -rf, dd, mkfs,
curl|sh, sudo; `sudo/su/doas/pkexec` refused unless allow_root. No allowlist, no auto-approval: unlike `run_command`
(argv, allowlisted read-only commands that may run unprompted), a shell string can mean anything.

## Tranches (status 2026-11-08)
| Tool family | Status |
|---|---|
| run_shell (bash/sh/dksh) | done; verified live with the real dksh in the sandbox (pipe and redirect worked, both approvals shown) |
| find_files, ask_user, update_todos, load_skill | done; ask_user and todos verified live, find_files verified live in plan mode |
| plan mode (`/plan`, `plan=true`, submit_plan) | done; verified live: read-only exploration, plan declined with feedback, revised, approved |
| spawn_agent | done; verified live (fresh context, read-only, nested output, report returned as untrusted data) |
| web_fetch, web_search (opt-in `web=true`, per-request approval) | web_fetch verified live (example.org); web_search unit-tested only (needs a configured endpoint) |
| notify (notify-send) | done; unit-tested, not exercised live (would pop a real notification) |
| edit_notebook_cell | done; verified live; generic edit/write refuse .ipynb after the model chose them in a first run and left stale outputs |
| allow/deny rules (`allow_rule=` / `deny_rule=`) | done; deny wins; allow only answers prompts, never overrides a refusal; a wildcard allow does not cover shell commands containing `; | & < > $ ( ) ` or newlines; verified live (rule-approved edit, prompted edit, denied read) |
| run_background / check_background / stop_background | done; approved per start, sandboxed, max 4, all stopped at session end (verified: no leftover process), bwrap --die-with-parent / setpriv --pdeathsig if aimgr is killed |
| enter_worktree / exit_worktree | done; verified live in a scratch repo (branch aimgr/<name> under <dir>/.aimgr-worktrees, work happens there, main checkout untouched) |
| scheduling: done (aimgr schedule, unattended, read-only/inspect) · MCP client | not built |

Fixes found by these runs: approval prompt printed `[y/N]` before the question; the sub-agent report string leaked
(allocated outside the arena that frees it).

Not planned: Artifact/Docs/Gmail/Calendar/Drive style integrations (Anthropic-hosted services, not general tools).

## Notes on the shell
- The shell string is passed as ONE argv element to `<shell> -c`, never interpolated by aimgr. bash gets
  `--noprofile --norc`. dksh is invoked as `dksh -c <string>`; it is found on PATH or in `~/.local/bin`, and its
  directory is bind-mounted read-only into the sandbox when it lives outside /usr.
- Without bubblewrap the prompt says NOT SANDBOXED in capitals and the question names it.
- Lexical checks (sudo words, rm -rf, curl|sh, mkfs, dd) only add a WARNING line or refuse root escalation; they
  are bypassable by a determined model, which is why every use needs a keypress and the sandbox exists.
