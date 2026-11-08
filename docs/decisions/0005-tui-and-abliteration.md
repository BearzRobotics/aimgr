# 0005: ncursesw TUI and abliteration tagging

Status: accepted. Date: 2026-11-07.

## TUI
- **Binding:** SUPERSEDED by 0006: the first implementation used ncursesw via
  translate-c; it now uses vendored libvaxis. Everything below that mentions
  curses/linking is historical.
- **Linking:** `libncursesw.so` on this system is a text linker script
  (`INPUT(libncursesw.so.6 -ltinfo)`) that Zig 0.17.1 fails to parse
  ("UnexpectedEndOfFile"), so `build.zig` links `libncursesw.a` statically
  (`preferred_link_mode = .static`). Terminfo is still read at runtime. If your
  distro's script parses, switch to dynamic. Requires `libncursesw-dev`.
- **Responsiveness:** no threads. `getch` times out every 100 ms; each tick polls
  jobs (`/proc/<pid>/stat`, log tail, LISTEN state). Transfers and servers are
  child processes with output going to `job-N-<kind>.log` in the state dir; the
  UI shows the sanitized last line (ANSI and `\r` progress handled).
- **Isolation:** jobs run in their own process group so terminal Ctrl-C reaches
  aimgr only. aimgr handles SIGINT/SIGTERM/SIGHUP by asking jobs to stop
  (SIGTERM, ~5 s) and then exiting; leftover pids are printed. SIGKILL is only
  sent after a confirmation modal.
- **Terminal safety:** `term.deinit()` is idempotent and runs from `defer`, the
  signal path and a custom panic handler. Chat suspends curses (`endwin`),
  runs the child on the real terminal and resumes.
- **Text safety:** control bytes in model names / subprocess output are replaced
  before reaching curses; UTF-8 is clipped by codepoint.
- **Accessibility:** selection is `> ` plus reverse video; states are words
  (RUNNING, FAILED, ...); color accents are enabled unless `NO_COLOR` is set and
  are never the only signal. Errors stay in the status line until replaced or Esc.
- **Safety rules kept:** every pull/update/remove goes through a modal naming
  backend and exact id; TUI servers bind 127.0.0.1 only (non-loopback needs the CLI
  confirmation); llama delete is disabled with the reason shown.

## Abliteration
"Abliterated" models have had their refusal direction removed by weight editing.
aimgr does not perform abliteration; it only helps you recognize such models.
- A catalog `tags = ["abliterated"]` entry is authoritative.
- Otherwise a name heuristic (`abliterat` in the id or catalog name) applies. It
  can be wrong in both directions and is documented as unverified.
- Surfaces: `[abliterated]` marker in `list` and the TUI, `list --abliterated`,
  TUI key `a`, free-text filters match the tag, and the detail panel shows a
  factual note. No capability is blocked or changed for these models.

## Verification
Driven in a real pty via GNU screen: tab switching, search, sort/filter, detail
(both layouts), delete modal (cancelled), start/stop of a real llama server,
quit-with-jobs modal, SIGTERM restore of tty modes, non-tty refusal. Not
exercised: resize events, color rendering, interactive chat inside the TUI,
transfer jobs (no pull/remove was run), SIGKILL escalation modal.
