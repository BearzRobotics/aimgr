//! Full-screen session interface (chat and agent), built on the vendored libvaxis, in the style of Claude Code:
//! a scrollable transcript on top, an input box pinned at the bottom (two rules, the line you type, a status line),
//! and approval questions as a menu you answer with arrows, number keys, y/n or the mouse.
//!
//! Threads: the main thread owns the terminal and draws; the conversation (model requests, tools) runs on a worker
//! thread. The worker writes to `writer()` (appended to the transcript; ANSI colour codes in it become styles)
//! and blocks in `nextLine` / `choose` until the user answers. `suspendTerm` / `resumeTerm` hand the real terminal
//! to a child process (`!command`) and take it back.
const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const activity = @import("activity.zig");

const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
};

const max_transcript = 2 * 1024 * 1024;

/// A tiny spin lock: the critical sections are short (append text, copy state).
const Lock = struct {
    v: std.atomic.Value(bool) = .init(false),
    fn lock(l: *Lock) void {
        while (l.v.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    fn unlock(l: *Lock) void {
        l.v.store(false, .release);
    }
};

pub const Ui = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    tty_buf: [4096]u8 = undefined,
    tty: vaxis.Tty = undefined,
    vx: vaxis.Vaxis = undefined,
    loop: vaxis.Loop(Event) = undefined,
    frame: std.heap.ArenaAllocator,

    lock: Lock = .{},
    // --- shared with the worker (under `lock`) ---
    transcript: std.ArrayList(u8) = .empty,
    status_left: std.ArrayList(u8) = .empty,
    /// Lines submitted by the user and not yet taken by the worker.
    queued: std.ArrayList([]u8) = .empty,
    /// The worker waits for a line (`nextLine`).
    want_line: bool = false,
    /// End of input (Ctrl-D / Ctrl-C on an empty box while the worker waits).
    eof: bool = false,
    /// Approval menu: question, options, selected row, answer (-1 = pending).
    menu_q: []const u8 = "",
    menu_opts: []const []const u8 = &.{},
    menu_on: bool = false,
    menu_sel: usize = 0,
    menu_answer: i32 = -1,
    // terminal hand-over for `!command`: 0 running, 1 suspend requested, 2 suspended, 3 resume requested
    hand: std.atomic.Value(u8) = .init(0),
    worker_done: std.atomic.Value(bool) = .init(false),

    // --- main thread only ---
    input: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    history: std.ArrayList([]u8) = .empty,
    hist_pos: usize = 0,
    scroll: usize = 0,
    /// Rows of the menu options as drawn last (for mouse clicks): first row and count.
    menu_row0: usize = 0,
    spinner: usize = 0,
    out_writer: OutWriter = undefined,

    pub fn init(self: *Ui, gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) !void {
        self.* = .{ .gpa = gpa, .io = io, .frame = .init(gpa) };
        self.tty = try vaxis.Tty.init(io, &self.tty_buf);
        errdefer self.tty.deinit();
        self.vx = try vaxis.init(io, gpa, @constCast(environ), .{});
        errdefer self.vx.deinit(gpa, self.tty.writer());
        self.loop = .init(io, &self.tty, &self.vx);
        try self.loop.start();
        try self.vx.enterAltScreen(self.tty.writer());
        try self.vx.queryTerminal(self.tty.writer(), .fromMilliseconds(300));
        self.vx.setMouseMode(self.tty.writer(), true) catch {};
        self.out_writer = .{ .ui = self, .interface = .{ .buffer = &self.out_writer.buf, .vtable = &.{ .drain = OutWriter.drain } } };
        if (vaxis.Tty.getWinsize(&self.tty)) |ws| self.vx.resize(gpa, self.tty.writer(), ws) catch {} else |_| {}
    }

    pub fn deinit(self: *Ui) void {
        self.vx.setMouseMode(self.tty.writer(), false) catch {};
        self.loop.stop();
        self.vx.exitAltScreen(self.tty.writer()) catch {};
        self.vx.deinit(self.gpa, self.tty.writer());
        self.tty.writer().flush() catch {};
        self.tty.deinit();
        for (self.queued.items) |l| self.gpa.free(l);
        for (self.history.items) |l| self.gpa.free(l);
        self.queued.deinit(self.gpa);
        self.history.deinit(self.gpa);
        self.transcript.deinit(self.gpa);
        self.status_left.deinit(self.gpa);
        self.input.deinit(self.gpa);
        self.frame.deinit();
    }

    pub fn writer(self: *Ui) *std.Io.Writer {
        return &self.out_writer.interface;
    }

    /// Columns available for text in the transcript.
    pub fn width(self: *Ui) usize {
        return @max(20, @as(usize, self.vx.screen.width));
    }

    fn append(self: *Ui, bytes: []const u8) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.transcript.appendSlice(self.gpa, bytes) catch {};
        if (self.transcript.items.len > max_transcript) {
            // Keep the newest part, cut at a line start.
            const cut = self.transcript.items.len - max_transcript / 2;
            const nl = std.mem.indexOfScalarPos(u8, self.transcript.items, cut, '\n') orelse cut;
            const rest = self.transcript.items[nl..];
            std.mem.copyForwards(u8, self.transcript.items[0..rest.len], rest);
            self.transcript.shrinkRetainingCapacity(rest.len);
        }
    }

    // ---- worker side -----------------------------------------------------------------------------

    pub fn setStatus(self: *Ui, text: []const u8) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.status_left.clearRetainingCapacity();
        self.status_left.appendSlice(self.gpa, text) catch {};
    }

    /// Block until the user submits a line (copied into `out`, at most out.len bytes); null at end of input.
    pub fn nextLine(self: *Ui, out: []u8) ?[]const u8 {
        self.out_writer.interface.flush() catch {};
        self.lock.lock();
        self.want_line = true;
        self.lock.unlock();
        while (true) {
            self.lock.lock();
            if (self.queued.items.len > 0) {
                const l = self.queued.orderedRemove(0);
                self.want_line = false;
                self.lock.unlock();
                defer self.gpa.free(l);
                const n = @min(l.len, out.len);
                @memcpy(out[0..n], l[0..n]);
                return out[0..n];
            }
            if (self.eof) {
                self.want_line = false;
                self.lock.unlock();
                return null;
            }
            self.lock.unlock();
            self.io.sleep(.fromMilliseconds(20), .awake) catch {};
        }
    }

    /// Ask a question as a menu; returns the chosen index, or null if the session is ending.
    pub fn choose(self: *Ui, question: []const u8, options: []const []const u8) ?usize {
        self.out_writer.interface.flush() catch {};
        self.lock.lock();
        self.menu_q = question;
        self.menu_opts = options;
        self.menu_sel = 0;
        self.menu_answer = -1;
        self.menu_on = true;
        self.lock.unlock();
        while (true) {
            self.lock.lock();
            if (self.menu_answer >= 0 or self.eof) {
                const a = self.menu_answer;
                self.menu_on = false;
                // The question and options belong to the caller and are gone once it returns.
                self.menu_q = "";
                self.menu_opts = &.{};
                self.lock.unlock();
                if (a < 0) return null;
                const i: usize = @intCast(a);
                var buf: [300]u8 = undefined;
                const line = std.fmt.bufPrint(&buf, "  \x1b[2m→ {s}\x1b[0m\n", .{options[i]}) catch "";
                self.append(line);
                return i;
            }
            self.lock.unlock();
            self.io.sleep(.fromMilliseconds(20), .awake) catch {};
        }
    }

    /// Give the real terminal to a child process (normal screen, line mode). Pair with resumeTerm.
    pub fn suspendTerm(self: *Ui) void {
        self.out_writer.interface.flush() catch {};
        self.hand.store(1, .release);
        while (self.hand.load(.acquire) != 2) self.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }

    pub fn resumeTerm(self: *Ui) void {
        self.hand.store(3, .release);
        while (self.hand.load(.acquire) != 0) self.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }

    // ---- main thread -------------------------------------------------------------------------------

    /// Run until the worker finishes. Returns false if the user forced an exit while the worker was busy.
    pub fn run(self: *Ui) bool {
        while (!self.worker_done.load(.acquire)) {
            switch (self.hand.load(.acquire)) {
                1 => {
                    self.doSuspend();
                    self.hand.store(2, .release);
                    continue;
                },
                2 => {
                    self.io.sleep(.fromMilliseconds(20), .awake) catch {};
                    continue;
                },
                3 => {
                    self.doResume();
                    self.hand.store(0, .release);
                },
                else => {},
            }
            while (self.loop.tryEvent() catch null) |ev| {
                if (!self.handle(ev)) return false;
            }
            self.draw();
            self.io.sleep(.fromMilliseconds(30), .awake) catch {};
        }
        return true;
    }

    fn doSuspend(self: *Ui) void {
        self.vx.setMouseMode(self.tty.writer(), false) catch {};
        self.loop.stop();
        self.vx.exitAltScreen(self.tty.writer()) catch {};
        self.tty.writer().flush() catch {};
        if (builtin.os.tag == .windows) {
            vaxis.Tty.setConsoleMode(self.tty.stdin, self.tty.initial_input_mode) catch {};
            vaxis.Tty.setConsoleMode(self.tty.stdout, self.tty.initial_output_mode) catch {};
        } else std.posix.tcsetattr(self.tty.fd.handle, .FLUSH, self.tty.termios) catch {};
    }

    fn doResume(self: *Ui) void {
        if (builtin.os.tag == .windows) {
            vaxis.Tty.setConsoleMode(self.tty.stdin, vaxis.Tty.input_raw_mode) catch {};
            vaxis.Tty.setConsoleMode(self.tty.stdout, vaxis.Tty.output_raw_mode) catch {};
        } else _ = vaxis.Tty.makeRaw(self.tty.fd.handle) catch {};
        self.loop.start() catch {};
        self.vx.enterAltScreen(self.tty.writer()) catch {};
        self.vx.setMouseMode(self.tty.writer(), true) catch {};
        self.vx.queueRefresh();
    }

    /// Returns false to quit immediately.
    fn handle(self: *Ui, ev: Event) bool {
        switch (ev) {
            .winsize => |ws| {
                self.vx.resize(self.gpa, self.tty.writer(), ws) catch {};
                self.vx.queueRefresh();
            },
            .mouse => |m| self.mouse(m),
            .key_press => |k| return self.key(k),
            else => {},
        }
        return true;
    }

    fn mouse(self: *Ui, m: vaxis.Mouse) void {
        switch (m.button) {
            .wheel_up => self.scroll += 3,
            .wheel_down => self.scroll -|= 3,
            .left => if (m.type == .press) {
                self.lock.lock();
                defer self.lock.unlock();
                if (!self.menu_on or m.row < 0) return;
                const r: usize = @intCast(m.row);
                if (r >= self.menu_row0 and r < self.menu_row0 + self.menu_opts.len) self.menu_answer = @intCast(r - self.menu_row0);
            },
            else => {},
        }
    }

    fn key(self: *Ui, k: vaxis.Key) bool {
        // Ctrl-C: clear the box; on an empty box end the session (immediately if the model is busy).
        if (k.matches('c', .{ .ctrl = true }) or k.matches('d', .{ .ctrl = true })) {
            if (self.input.items.len > 0 and k.matches('c', .{ .ctrl = true })) {
                self.input.clearRetainingCapacity();
                self.cursor = 0;
                return true;
            }
            self.lock.lock();
            const waiting = self.want_line or self.menu_on;
            self.eof = true;
            self.lock.unlock();
            return waiting; // a busy worker cannot be stopped politely: quit now
        }
        if (k.matches('l', .{ .ctrl = true })) {
            self.vx.queueRefresh();
            return true;
        }
        // Esc while the model or a tool works: interrupt that request (the session goes on).
        if (k.codepoint == vaxis.Key.escape) {
            self.lock.lock();
            const busy = !self.want_line and !self.menu_on;
            self.lock.unlock();
            if (busy) {
                activity.requestCancel();
                return true;
            }
        }
        // Scrolling the transcript.
        switch (k.codepoint) {
            vaxis.Key.page_up => {
                self.scroll += @max(1, self.paneRows() -| 2);
                return true;
            },
            vaxis.Key.page_down => {
                self.scroll -|= @max(1, self.paneRows() -| 2);
                return true;
            },
            else => {},
        }
        if (k.matches(vaxis.Key.home, .{ .ctrl = true })) {
            self.scroll = std.math.maxInt(u32);
            return true;
        }
        if (k.matches(vaxis.Key.end, .{ .ctrl = true })) {
            self.scroll = 0;
            return true;
        }

        self.lock.lock();
        const menu = self.menu_on;
        self.lock.unlock();
        if (menu) {
            self.menuKey(k);
            return true;
        }
        self.editKey(k);
        return true;
    }

    fn menuKey(self: *Ui, k: vaxis.Key) void {
        self.lock.lock();
        defer self.lock.unlock();
        const n = self.menu_opts.len;
        if (n == 0) return;
        switch (k.codepoint) {
            vaxis.Key.up => self.menu_sel = if (self.menu_sel == 0) n - 1 else self.menu_sel - 1,
            vaxis.Key.down, vaxis.Key.tab => self.menu_sel = (self.menu_sel + 1) % n,
            vaxis.Key.enter => self.menu_answer = @intCast(self.menu_sel),
            vaxis.Key.escape => self.menu_answer = @intCast(n - 1), // the last option is always "No"
            '1'...'9' => {
                const i = k.codepoint - '1';
                if (i < n) self.menu_answer = @intCast(i);
            },
            'y', 'Y' => self.menu_answer = 0,
            'n', 'N' => self.menu_answer = @intCast(n - 1),
            'a', 'A' => if (n == 3) {
                self.menu_answer = 1;
            },
            else => {},
        }
    }

    fn editKey(self: *Ui, k: vaxis.Key) void {
        switch (k.codepoint) {
            vaxis.Key.enter => {
                if (k.mods.shift or k.mods.alt) {
                    self.insert("\n");
                    return;
                }
                self.submit();
            },
            vaxis.Key.backspace => if (self.cursor > 0) {
                var start = self.cursor - 1;
                while (start > 0 and (self.input.items[start] & 0xC0) == 0x80) start -= 1;
                self.input.replaceRange(self.gpa, start, self.cursor - start, &.{}) catch {};
                self.cursor = start;
            },
            vaxis.Key.delete => if (self.cursor < self.input.items.len) {
                const len = std.unicode.utf8ByteSequenceLength(self.input.items[self.cursor]) catch 1;
                self.input.replaceRange(self.gpa, self.cursor, @min(len, self.input.items.len - self.cursor), &.{}) catch {};
            },
            vaxis.Key.left => if (self.cursor > 0) {
                self.cursor -= 1;
                while (self.cursor > 0 and (self.input.items[self.cursor] & 0xC0) == 0x80) self.cursor -= 1;
            },
            vaxis.Key.right => if (self.cursor < self.input.items.len) {
                self.cursor += std.unicode.utf8ByteSequenceLength(self.input.items[self.cursor]) catch 1;
                self.cursor = @min(self.cursor, self.input.items.len);
            },
            vaxis.Key.home => self.cursor = 0,
            vaxis.Key.end => self.cursor = self.input.items.len,
            vaxis.Key.up => self.historyMove(-1),
            vaxis.Key.down => self.historyMove(1),
            else => {
                if (k.matches('a', .{ .ctrl = true })) {
                    self.cursor = 0;
                } else if (k.matches('e', .{ .ctrl = true })) {
                    self.cursor = self.input.items.len;
                } else if (k.matches('u', .{ .ctrl = true })) {
                    self.input.replaceRange(self.gpa, 0, self.cursor, &.{}) catch {};
                    self.cursor = 0;
                } else if (k.text) |t| {
                    if (!k.mods.ctrl and !k.mods.alt) self.insert(t);
                } else if (!k.mods.ctrl and !k.mods.alt and k.codepoint >= 0x20 and k.codepoint < 0x110000 and k.codepoint != 0x7f) {
                    // Some terminals report only the code point.
                    var b: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(@intCast(k.codepoint), &b) catch return;
                    self.insert(b[0..n]);
                }
            },
        }
    }

    fn insert(self: *Ui, t: []const u8) void {
        for (t) |b| if (b < 0x20 and b != '\n') return; // no control bytes in the box
        self.input.insertSlice(self.gpa, self.cursor, t) catch return;
        self.cursor += t.len;
    }

    fn historyMove(self: *Ui, dir: i32) void {
        if (self.history.items.len == 0) return;
        if (dir < 0 and self.hist_pos > 0) self.hist_pos -= 1;
        if (dir > 0 and self.hist_pos < self.history.items.len) self.hist_pos += 1;
        self.input.clearRetainingCapacity();
        if (self.hist_pos < self.history.items.len) self.input.appendSlice(self.gpa, self.history.items[self.hist_pos]) catch {};
        self.cursor = self.input.items.len;
    }

    fn submit(self: *Ui) void {
        const text = self.input.items;
        const line = self.gpa.dupe(u8, text) catch return;
        if (text.len > 0) {
            if (self.gpa.dupe(u8, text)) |h| self.history.append(self.gpa, h) catch self.gpa.free(h) else |_| {}
        }
        self.hist_pos = self.history.items.len;
        self.input.clearRetainingCapacity();
        self.cursor = 0;
        self.scroll = 0;
        // Your message, shaded, in the transcript (commands too, so the history reads naturally).
        if (line.len > 0) {
            var it = std.mem.splitScalar(u8, line, '\n');
            var first = true;
            self.append("\n");
            while (it.next()) |l| {
                const msg = std.fmt.allocPrint(self.gpa, "\x1b[48;5;237m\x1b[97m {s} {s} \x1b[0m\n", .{ if (first) "❯" else " ", l }) catch continue;
                defer self.gpa.free(msg);
                self.append(msg);
                first = false;
            }
        }
        self.lock.lock();
        defer self.lock.unlock();
        self.queued.append(self.gpa, line) catch self.gpa.free(line);
    }

    // ---- drawing ---------------------------------------------------------------------------------

    fn paneRows(self: *Ui) usize {
        const h: usize = self.vx.screen.height;
        return h -| 6;
    }

    fn draw(self: *Ui) void {
        _ = self.frame.reset(.retain_capacity);
        const a = self.frame.allocator();
        const win = self.vx.window();
        win.fill(.{ .char = .{ .grapheme = " ", .width = 1 } });
        const W: usize = self.vx.screen.width;
        const H: usize = self.vx.screen.height;
        if (W < 10 or H < 6) return;

        // Snapshot shared state.
        self.lock.lock();
        const text = a.dupe(u8, self.transcript.items) catch "";
        const status = a.dupe(u8, self.status_left.items) catch "";
        const menu_on = self.menu_on;
        const menu_q = if (menu_on) a.dupe(u8, self.menu_q) catch "" else "";
        const empty: [][]const u8 = &.{};
        const opts_copy: [][]const u8 = if (menu_on) a.alloc([]const u8, self.menu_opts.len) catch empty else empty;
        for (opts_copy, 0..) |*o, i| o.* = a.dupe(u8, self.menu_opts[i]) catch "";
        const menu_opts: []const []const u8 = opts_copy;
        const menu_sel = self.menu_sel;
        const waiting = self.want_line;
        const queued = self.queued.items.len;
        self.lock.unlock();

        // Input rows (wrapped), at most 6.
        const in_w = W -| 3;
        const input_rows = layout(a, self.input.items, in_w, .{}) catch &.{};
        const n_in = @max(1, @min(input_rows.len, 6));

        // Menu rows: question (wrapped, at most 6) + options + a blank line.
        var menu_rows: []const Row = &.{};
        if (menu_on) menu_rows = layout(a, menu_q, W -| 2, .{ .bold = true }) catch &.{};
        const n_q = @min(menu_rows.len, 6);
        const menu_h: usize = if (menu_on) n_q + menu_opts.len + 2 else 0;

        const box_h = 3 + (if (menu_on) 0 else n_in); // rule, input, rule, status (input hidden while the menu has focus)
        const pane_h = H -| (box_h + menu_h);

        // Transcript.
        const rows = layout(a, text, W, .{}) catch &.{};
        const max_scroll = rows.len -| pane_h;
        if (self.scroll > max_scroll) self.scroll = max_scroll;
        const end = rows.len - self.scroll;
        const start = end -| pane_h;
        for (rows[start..end], 0..) |r, y| putRow(win, y, 0, r);
        if (self.scroll > 0) {
            const note = std.fmt.allocPrint(a, " ↑ {d} more lines · PgDn / wheel to return ", .{self.scroll}) catch "";
            putText(win, pane_h -| 1, W -| (note.len + 1), note, .{ .reverse = true });
        }

        var y = pane_h;
        if (menu_on) {
            const st: vaxis.Style = .{ .fg = .{ .index = 3 } };
            putText(win, y, 0, "╭ approval needed", st);
            y += 1;
            for (menu_rows[0..n_q]) |r| {
                putRow(win, y, 2, r);
                y += 1;
            }
            self.menu_row0 = y;
            for (menu_opts, 0..) |o, i| {
                const sel = i == menu_sel;
                const label = std.fmt.allocPrint(a, "{s} {d}. {s}", .{ if (sel) "❯" else " ", i + 1, o }) catch "";
                putText(win, y, 2, label, if (sel) .{ .fg = .{ .index = 6 }, .bold = true } else .{});
                y += 1;
            }
            putText(win, y, 2, "↑/↓ or 1-3 to choose, Enter to confirm, Esc = No (or click an option)", .{ .dim = true });
            y += 1;
        }

        // Box: rule, input, rule, status.
        const rule = a.alloc(u8, W * 3) catch return;
        for (0..W) |i| @memcpy(rule[i * 3 .. i * 3 + 3], "─");
        putText(win, y, 0, rule, .{ .dim = true });
        y += 1;
        if (!menu_on) {
            const first_in = input_rows.len -| n_in;
            for (0..n_in) |i| {
                putText(win, y + i, 0, if (i == 0) "❯" else " ", .{ .fg = .{ .index = 6 }, .bold = true });
                if (first_in + i < input_rows.len) putRow(win, y + i, 2, input_rows[first_in + i]);
            }
            // Cursor position: count characters before the cursor and wrap like layout() did.
            const before = std.unicode.utf8CountCodepoints(self.input.items[0..self.cursor]) catch self.cursor;
            const nl_before = std.mem.count(u8, self.input.items[0..self.cursor], "\n");
            var col: usize = before;
            var row_i: usize = 0;
            if (nl_before > 0) {
                const last_nl = std.mem.lastIndexOfScalar(u8, self.input.items[0..self.cursor], '\n').?;
                col = std.unicode.utf8CountCodepoints(self.input.items[last_nl + 1 .. self.cursor]) catch 0;
                row_i = nl_before;
            }
            row_i += col / @max(1, in_w);
            col = col % @max(1, in_w);
            if (row_i >= first_in and row_i - first_in < n_in) win.showCursor(@intCast(2 + col), @intCast(y + row_i - first_in)) else win.hideCursor();
            y += n_in;
        } else win.hideCursor();
        putText(win, y, 0, rule, .{ .dim = true });
        y += 1;

        // Status: what is going on right now, else model · level · mode and hints.
        var abuf: [200]u8 = undefined;
        if (activity.current(&abuf)) |act| {
            self.spinner +%= 1;
            const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
            putText(win, y, 2, frames[(self.spinner / 3) % frames.len], .{ .fg = .{ .index = 6 } });
            putText(win, y, 4, act, .{ .dim = true });
            const tail: []const u8 = if (activity.cancelled()) "  interrupting…" else "  · Esc interrupts";
            putText(win, y, 4 + (std.unicode.utf8CountCodepoints(act) catch act.len), tail, .{ .dim = true });
        } else {
            const hint: []const u8 = if (menu_on) "answer the question above" else if (waiting) "Enter send · Shift+Enter new line · PgUp/PgDn scroll · /help · Ctrl-C quit" else "working… Esc interrupts · Enter queues your message";
            const q = if (queued > 0 and !waiting) std.fmt.allocPrint(a, "{s}   {d} queued", .{ status, queued }) catch status else status;
            putText(win, y, 2, std.fmt.allocPrint(a, "{s}   {s}", .{ q, hint }) catch q, .{ .dim = true });
        }

        self.vx.render(self.tty.writer()) catch {};
        self.tty.writer().flush() catch {};
    }
};

/// The worker's output: appended to the transcript.
const OutWriter = struct {
    ui: *Ui,
    buf: [4096]u8 = undefined,
    interface: std.Io.Writer,

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *OutWriter = @alignCast(@fieldParentPtr("interface", w));
        self.ui.append(w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            self.ui.append(d);
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            self.ui.append(last);
            n += last.len;
        }
        return n;
    }
};

// ---- text layout: ANSI SGR colour codes -> styled segments, wrapped to a width ------------------------

pub const Seg = struct { text: []const u8, style: vaxis.Style };
pub const Row = []const Seg;

/// Split `text` into display rows of at most `w` characters. SGR escape sequences set the style; other escape
/// sequences and control bytes are dropped (the transcript holds untrusted model and command output).
pub fn layout(a: std.mem.Allocator, text: []const u8, w: usize, base: vaxis.Style) ![]Row {
    var rows: std.ArrayList(Row) = .empty;
    var segs: std.ArrayList(Seg) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var style = base;
    var col: usize = 0;
    const flushSeg = struct {
        fn f(al: std.mem.Allocator, sg: *std.ArrayList(Seg), c: *std.ArrayList(u8), st: vaxis.Style) !void {
            if (c.items.len == 0) return;
            try sg.append(al, .{ .text = try c.toOwnedSlice(al), .style = st });
        }
    }.f;
    var i: usize = 0;
    while (i < text.len) {
        const b = text[i];
        if (b == 0x1b) {
            if (i + 1 < text.len and text[i + 1] == '[') {
                var j = i + 2;
                while (j < text.len and (text[j] < 0x40 or text[j] > 0x7e)) j += 1;
                if (j < text.len and text[j] == 'm') {
                    try flushSeg(a, &segs, &cur, style);
                    style = applySgr(style, base, text[i + 2 .. j]);
                }
                i = @min(text.len, j + 1);
                continue;
            }
            i += 2;
            continue;
        }
        if (b == '\n') {
            try flushSeg(a, &segs, &cur, style);
            try rows.append(a, try segs.toOwnedSlice(a));
            col = 0;
            i += 1;
            continue;
        }
        if (b == '\r') {
            i += 1;
            continue;
        }
        if (b == '\t') {
            try cur.appendSlice(a, "    ");
            col += 4;
            i += 1;
            continue;
        }
        if (b < 0x20 or b == 0x7f) {
            i += 1;
            continue;
        }
        if (col >= w) {
            try flushSeg(a, &segs, &cur, style);
            try rows.append(a, try segs.toOwnedSlice(a));
            col = 0;
        }
        const len = @min(text.len - i, std.unicode.utf8ByteSequenceLength(b) catch 1);
        try cur.appendSlice(a, text[i .. i + len]);
        col += 1;
        i += len;
    }
    try flushSeg(a, &segs, &cur, style);
    if (segs.items.len > 0) try rows.append(a, try segs.toOwnedSlice(a));
    return rows.toOwnedSlice(a);
}

fn applySgr(st_in: vaxis.Style, base: vaxis.Style, params: []const u8) vaxis.Style {
    var st = st_in;
    var nums: [16]u16 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, params, ';');
    while (it.next()) |p| {
        if (n == nums.len) break;
        nums[n] = std.fmt.parseInt(u16, p, 10) catch 0;
        n += 1;
    }
    if (n == 0) return base;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const v = nums[k];
        switch (v) {
            0 => st = base,
            1 => st.bold = true,
            2 => st.dim = true,
            3 => st.italic = true,
            4 => st.ul_style = .single,
            7 => st.reverse = true,
            9 => st.strikethrough = true,
            22 => {
                st.bold = false;
                st.dim = false;
            },
            23 => st.italic = false,
            24 => st.ul_style = .off,
            27 => st.reverse = false,
            29 => st.strikethrough = false,
            30...37 => st.fg = .{ .index = @intCast(v - 30) },
            39 => st.fg = .default,
            40...47 => st.bg = .{ .index = @intCast(v - 40) },
            49 => st.bg = .default,
            90...97 => st.fg = .{ .index = @intCast(v - 90 + 8) },
            100...107 => st.bg = .{ .index = @intCast(v - 100 + 8) },
            38, 48 => {
                if (k + 2 < n and nums[k + 1] == 5) {
                    const c: vaxis.Color = .{ .index = @intCast(@min(nums[k + 2], 255)) };
                    if (v == 38) st.fg = c else st.bg = c;
                    k += 2;
                } else if (k + 4 < n and nums[k + 1] == 2) {
                    const c: vaxis.Color = .{ .rgb = .{ @intCast(@min(nums[k + 2], 255)), @intCast(@min(nums[k + 3], 255)), @intCast(@min(nums[k + 4], 255)) } };
                    if (v == 38) st.fg = c else st.bg = c;
                    k += 4;
                }
            },
            else => {},
        }
    }
    return st;
}

fn putRow(win: vaxis.Window, y: usize, x0: usize, r: Row) void {
    var x = x0;
    for (r) |s| {
        if (x >= win.width or y >= win.height) return;
        const child = win.child(.{ .x_off = @intCast(x), .y_off = @intCast(y), .width = @intCast(win.width - x), .height = 1 });
        const res = child.printSegment(.{ .text = s.text, .style = s.style }, .{ .wrap = .none });
        x += res.col;
    }
}

fn putText(win: vaxis.Window, y: usize, x: usize, text: []const u8, style: vaxis.Style) void {
    if (x >= win.width or y >= win.height) return;
    const child = win.child(.{ .x_off = @intCast(x), .y_off = @intCast(y), .width = @intCast(win.width - x), .height = 1 });
    _ = child.printSegment(.{ .text = text, .style = style }, .{ .wrap = .none });
}

test "layout: styles from SGR, wrapping, control bytes dropped" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const rows = try layout(a, "\x1b[1mbold\x1b[0m plain\nabcdefgh\x07ij\n", 5, .{});
    try std.testing.expectEqual(@as(usize, 5), rows.len); // "bold "+"plain" wraps at 5, "abcde" "fghij"
    try std.testing.expect(rows[0][0].style.bold);
    try std.testing.expectEqualStrings("bold", rows[0][0].text);
    try std.testing.expect(!rows[1][0].style.bold);
    try std.testing.expectEqualStrings("fghij", rows[4][0].text);
    const bg = try layout(a, "\x1b[48;5;237m\x1b[97m hi \x1b[0m", 80, .{});
    try std.testing.expectEqual(@as(u8, 237), bg[0][0].style.bg.index);
    try std.testing.expectEqual(@as(u8, 15), bg[0][0].style.fg.index);
}
