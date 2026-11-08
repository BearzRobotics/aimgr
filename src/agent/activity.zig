//! What the session is doing right now, shown live in the status line of the pinned input box: a spinner, a
//! label ("thinking", "running search_files"), elapsed seconds and, for walks, the number of files seen.
//! A ticker thread redraws only the status row, once a second, and only while an activity is set. The main
//! thread clears the activity before it prints anything; `clear` waits for a tick that is in progress, so the
//! ticker never writes in the middle of the session's own output.
//! Global state (documented exception, like the signal flag): one session per process.
const std = @import("std");
const platform = @import("../platform.zig");

var lock = std.atomic.Value(bool).init(false);
var label_buf: [160]u8 = undefined;
var label_len: usize = 0;
var started_ms: i64 = 0;
var files = std.atomic.Value(usize).init(0);
var row: u16 = 0;
var cols: u16 = 80;
var running = std.atomic.Value(bool).init(false);
var thread: ?std.Thread = null;
var io_global: std.Io = undefined;

fn acquire() void {
    while (lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn release() void {
    lock.store(false, .release);
}

fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.awake.now(io).toMilliseconds();
}

/// Start the ticker for a pinned box whose status line is terminal row `status_row`.
pub fn start(io: std.Io, status_row: u16, width: u16, prefix: []const u8) void {
    io_global = io;
    row = status_row;
    cols = width;
    _ = prefix;
    running.store(true, .release);
    thread = std.Thread.spawn(.{}, tick, .{}) catch null;
}

pub fn stop() void {
    running.store(false, .release);
    if (thread) |t| t.join();
    thread = null;
    clear();
}

/// The session is about to block on `what` (it has flushed its output). No-op without a ticker.
pub fn set(what: []const u8) void {
    acquire();
    defer release();
    label_len = @min(what.len, label_buf.len);
    @memcpy(label_buf[0..label_len], what[0..label_len]);
    started_ms = nowMs(io_global);
    files.store(0, .monotonic);
}

/// The current activity as "label 12s · 340 files", formatted into `buf`; null when idle.
pub fn current(buf: []u8) ?[]const u8 {
    acquire();
    defer release();
    if (label_len == 0) return null;
    const secs = @divTrunc(nowMs(io_global) - started_ms, 1000);
    var w: std.Io.Writer = .fixed(buf);
    w.print("{s} {d}s", .{ label_buf[0..label_len], secs }) catch {};
    const n = files.load(.monotonic);
    if (n > 0) w.print(" · {d} files", .{n}) catch {};
    return w.buffered();
}

/// Needed before `set` when no ticker is started (the full-screen UI reads `current` itself).
pub fn useIo(io: std.Io) void {
    io_global = io;
}

/// The session will print again: stop drawing (waits for a tick in progress).
pub fn clear() void {
    acquire();
    defer release();
    label_len = 0;
}

/// Progress of a walk (files seen so far).
pub fn count(n: usize) void {
    files.store(n, .monotonic);
}

fn tick() void {
    const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    var i: usize = 0;
    while (running.load(.acquire)) {
        io_global.sleep(.fromMilliseconds(250), .awake) catch {};
        i += 1;
        acquire();
        if (label_len > 0) {
            // The text part first (cut to the terminal width, by characters), then wrapped in escapes.
            var tb: [400]u8 = undefined;
            var t: std.Io.Writer = .fixed(&tb);
            const secs = @divTrunc(nowMs(io_global) - started_ms, 1000);
            const n = files.load(.monotonic);
            t.print("{s} {d}s", .{ label_buf[0..label_len], secs }) catch {};
            if (n > 0) t.print(" · {d} files", .{n}) catch {};
            t.writeAll(" · Ctrl-C ends the session") catch {};
            const text = fitCols(t.buffered(), cols -| 5);
            var buf: [600]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            w.print("\x1b7\x1b[{d};1H\x1b[2K  \x1b[36m{s}\x1b[0m \x1b[2m{s}\x1b[0m\x1b8", .{ row, frames[i % frames.len], text }) catch {};
            platform.writeStdoutRaw(w.buffered());
        }
        release();
    }
}

/// The longest prefix of `s` that is at most `n` characters (UTF-8 code points) wide.
pub fn fitCols(s: []const u8, n: usize) []const u8 {
    var chars: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (chars == n) return s[0..i];
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i = @min(s.len, i + len);
        chars += 1;
    }
    return s;
}

test "fitCols counts characters, not bytes" {
    try std.testing.expectEqualStrings("a·b", fitCols("a·b·c", 3));
    try std.testing.expectEqualStrings("abc", fitCols("abc", 10));
    try std.testing.expectEqualStrings("", fitCols("abc", 0));
}
