# 0006: Replace ncursesw with vendored libvaxis

Status: accepted. Date: 2026-11-08. Supersedes the backend part of 0005.

## Context
The first TUI used ncursesw (allowed by SPEC section 7 as a v1 exception). On this
system `libncursesw.so` is a text linker script that Zig 0.17.1 cannot parse
("UnexpectedEndOfFile"), forcing a static link of the distro `.a` and a
`libncursesw-dev` build dependency. The spec's own rule is "vendor and pin".

## Decision
- Vendor libvaxis at commit `74b7d916c8879e5379f428ea8c4d43d1a1bb061b` (main,
  "build: update to zig 0.17.1"; its `build.zig.zon` says version 0.6.0, minimum
  Zig 0.17.0; no release tag exists for 0.6.0, the newest tag v0.5.1 predates
  Zig 0.17) in `vendor/libvaxis`, MIT.
- Vendor its only dependency uucode at `1fb73433bba5d93366c57f23ff2e9d7939746500`
  (0.2.0) in `vendor/uucode`.
- **Local patch:** `vendor/libvaxis/build.zig.zon` points `uucode` at
  `../uucode` instead of a git URL, so builds never touch the network.
  (See VENDORED.txt in each directory.)
- `src/tui/term.zig` keeps the small interface used by the drawing code
  (`put`, `erase`, `flush`, `getKey`, `size`, `setAttr`, suspend/resume), so
  `draw.zig` was untouched except for one Settings line.

## Consequences
- The binary is fully static with no libncurses/tinfo; `src/c.h`, translate-c and
  the static-link workaround were removed.
- libvaxis stores slices of drawn text until render, so `term.put` copies text
  into a per-frame arena (reset in `erase`). The first attempt reused one scratch
  buffer and corrupted the screen.
- Raw mode turns Ctrl-C into a key (mapped to the quit flow); SIGTERM/SIGHUP are
  still handled by signal handlers. libvaxis' input thread uses `io.concurrent`.
- Chat still leaves the TUI via `loop.stop()` + `exitAltScreen`, then restores.

## Verified (GNU screen pty)
Rendering, tabs, detail, help, search, modal cancel, llama delete refusal, real
server start/stop from the TUI, quit-with-job modal, Ctrl-C quit with tty modes
restored, no leftover processes. Not verified: terminal resize, chat inside the TUI.
