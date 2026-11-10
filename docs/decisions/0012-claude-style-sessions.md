# 0012: Claude Code style sessions, chat in the same interface, Windows agent

Date: 2026-11-08. Status: accepted.

## Context
The user wants agent sessions (and chat) to feel like Claude Code: clear separation of their text from the
model's, project notes, "don't ask again" answers, modes, running their own commands, and the ability to work
outside the trusted folder by saying so. aimgr also had to work for non-technical users on Windows.

## Decisions
- **One interface for chat and agent.** `aimgr chat` now runs the agent session at level `off` (no tools at all,
  different system prompt); `aimgr chat --raw` (or `--ctx` / `--gpu-layers`) keeps the backend's own CLI. The TUI's
  `c` and `g` both run aimgr itself in the terminal.
- **Full-screen session (supersedes the line-oriented box below).** On a terminal, sessions run in a libvaxis
  full-screen interface: transcript pane with its own scrollback (PgUp/PgDn, wheel), input box with line editing
  and history pinned at the bottom, live status (spinner, activity, seconds, files searched), approvals as a menu
  (arrows, numbers, y/a/n, Esc, mouse). The conversation runs on a worker thread that writes to the transcript (ANSI
  colours from the Markdown renderer become styles) and blocks on the UI for lines and menu answers; `!command`
  hands the real terminal over and back. The line-oriented session stays for pipes and NO_COLOR. Reason: a
  line-based screen cannot keep the box, scrollback and the user's keystrokes in order (typed text echoed into the
  output while the model worked).
- **Input between two rules.** On a colour terminal the prompt is a line between two full-width rules with a status
  line (model, level, mode) under them; after Enter the message is redrawn as a shaded `❯` block; replies start with
  `●`, are Markdown rendered with md-zig (vendored, BearzRobotics/md-zig v0.4.0) and indented under the bullet.
  The box is pinned to the bottom four rows with a terminal scroll region (DECSTBM): output scrolls above it and
  the box never disappears, also while the model works. Still line-oriented (no full-screen redraw), so the
  terminal's scrollback, copy and paste keep working; the region is reset on exit and on Ctrl-C. Plain `you>` for
  pipes, NO_COLOR and consoles without ANSI.
- **Approvals.** `[y/N/a]`: `a` = this exact action for the rest of the session; on a file edit it turns on edits
  mode. Session only: persistence stays explicit (rules). Deletes, plan approval and worktree switches never get `a`.
- **Modes.** `/mode` cycles default -> edits -> plan (Claude Code's shift-tab; a line editor cannot see shift-tab).
- **Folder trust.** First use of a folder asks once; stored in the user's config (`trusted-dirs`), never in the
  project, so a cloned repository cannot mark itself trusted.
- **Outside the folders.** Reads are asked (every level) instead of refused; the model is told not to refuse in
  advance. `/add-dir` widens the session. Writes stay inside the folders.
- **Project notes.** AIMGR.md, else AGENTS.md, else CLAUDE.md in the first folder, added to the instructions.
- **`!command`.** The user's own command, in their shell, on the terminal (so sudo/installers can prompt); no
  approval and no sandbox because the user typed it; the model learns only the command and exit code.
- **Package managers, git, gh.** Query forms run without asking (apt, apt-cache, dpkg, apk, rpm, dnf/yum, pacman,
  zypper, winget list) with the package databases bound read-only into the sandbox; installs never run
  automatically, the model suggests the command (per-distro install hints for missing tools). gh read-only views
  and winget search/show ask because they use the network, and run outside the network-less sandbox once approved.
  git write forms that looked like listings (branch NAME, tag NAME, remote add) are no longer automatic.
- **PDFs.** read_file extracts text with pdftotext; scanned PDFs are OCRed with tesseract (first 8 pages).
- **Windows agent.** PowerShell 5.1 default (pwsh, cmd optional); paths canonicalised to `C:/...`,
  case-insensitive containment; device names, UNC paths, alternate data streams and trailing dots/spaces refused.
  No sandbox exists, so every shell command is shown as NOT SANDBOXED and asked.

## Verification
Live sessions on Linux (gemma4:12b, gpt-oss-20b) and in a Windows 11 VM (qwen3:1.7b); rendering checked by
replaying the terminal log through a small VT renderer; unit tests for policy, package rules, Windows paths.
