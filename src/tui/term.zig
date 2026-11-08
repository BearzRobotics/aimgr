//! Terminal backend on top of vendored libvaxis (pure Zig, no libncurses).
//! The rest of the TUI only uses this small interface, so the backend can be
//! swapped without touching drawing code.
//!
//! Module-level state is intentional: there is exactly one controlling
//! terminal, and the Loop/Vaxis structs hold pointers to each other.
const std = @import("std");
const vaxis = @import("vaxis");

pub const A_BOLD: c_int = 1;
pub const A_REVERSE: c_int = 2;

pub const Key = union(enum) {
    none,
    resize,
    up,
    down,
    left,
    right,
    page_up,
    page_down,
    home,
    end,
    enter,
    esc,
    backspace,
    tab,
    /// Ctrl-C: raw mode turns it into a key rather than SIGINT.
    ctrl_c,
    char: u21,
};

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
};

var tty_buf: [4096]u8 = undefined;
var tty: vaxis.Tty = undefined;
var vx: vaxis.Vaxis = undefined;
var loop: vaxis.Loop(Event) = undefined;
var gpa_: std.mem.Allocator = undefined;
var io_: std.Io = undefined;
var active = false;
var style: vaxis.Style = .{};

pub fn init(gpa: std.mem.Allocator, io: std.Io, environ: *std.process.Environ.Map) !void {
    gpa_ = gpa;
    io_ = io;
    frame_arena = std.heap.ArenaAllocator.init(gpa);
    errdefer frame_arena.deinit();
    tty = try vaxis.Tty.init(io, &tty_buf);
    errdefer tty.deinit();
    vx = try vaxis.init(io, gpa, environ, .{});
    errdefer vx.deinit(gpa, tty.writer());
    loop = .init(io, &tty, &vx);
    try loop.start();
    errdefer loop.stop();
    try vx.enterAltScreen(tty.writer());
    // Capability detection; bounded wait so unresponsive terminals still work.
    try vx.queryTerminal(tty.writer(), .fromMilliseconds(300));
    active = true;
}

/// Idempotent; safe from defer, signal paths and the panic handler.
pub fn deinit() void {
    if (!active) return;
    active = false;
    loop.stop();
    vx.exitAltScreen(tty.writer()) catch {};
    vx.deinit(gpa_, tty.writer());
    tty.writer().flush() catch {};
    tty.deinit();
    frame_arena.deinit();
}

/// Leave the TUI so a child can own the terminal (chat). libvaxis put /dev/tty in
/// raw mode (no output post-processing, no echo, no line editing) and only undoes
/// that in Tty.deinit, so the saved original settings are restored here; otherwise
/// the child runs in a raw terminal and its output "staircases".
pub fn suspendTerm() void {
    if (!active) return;
    loop.stop();
    vx.exitAltScreen(tty.writer()) catch {};
    tty.writer().flush() catch {};
    std.posix.tcsetattr(tty.fd.handle, .FLUSH, tty.termios) catch {};
}

pub fn resumeTerm() void {
    if (!active) return;
    _ = vaxis.Tty.makeRaw(tty.fd.handle) catch {};
    loop.start() catch {};
    vx.enterAltScreen(tty.writer()) catch {};
    vx.queueRefresh();
}

pub fn size() struct { rows: usize, cols: usize } {
    return .{ .rows = @max(vx.screen.height, 1), .cols = @max(vx.screen.width, 1) };
}

pub fn erase() void {
    _ = frame_arena.reset(.retain_capacity);
    vx.window().clear();
}

pub fn flush() void {
    vx.render(tty.writer()) catch {};
    tty.writer().flush() catch {};
}

pub fn setAttr(attr: c_int) void {
    style = .{ .bold = attr & A_BOLD != 0, .reverse = attr & A_REVERSE != 0 };
}

// libvaxis cells keep slices of the text they were given until the next
// render, so text must outlive put(): it is copied into a per-frame arena that
// is reset in erase() (after the previous frame was rendered). Control bytes in
// untrusted text (model names, subprocess output) are replaced during the copy.
var frame_arena: std.heap.ArenaAllocator = undefined;

fn sanitized(t: []const u8) []const u8 {
    const buf = frame_arena.allocator().alloc(u8, t.len) catch return "";
    for (t, 0..) |b, i| buf[i] = if (b < 0x20 or b == 0x7f) '?' else b;
    return buf;
}

/// Draw `text` at row/col, clipped to `max_cols` columns and the screen.
pub fn put(row: usize, col: usize, max_cols: usize, text: []const u8) void {
    const sz = size();
    if (row >= sz.rows or col >= sz.cols or max_cols == 0) return;
    const w: u16 = @intCast(@min(max_cols, sz.cols - col));
    const win = vx.window().child(.{
        .x_off = @intCast(col),
        .y_off = @intCast(row),
        .width = w,
        .height = 1,
    });
    _ = win.printSegment(.{ .text = sanitized(text), .style = style }, .{ .wrap = .none });
}

/// Poll for input for up to ~100 ms (so the caller can service jobs and signals).
pub fn getKey() Key {
    var waited: usize = 0;
    while (waited < 4) : (waited += 1) {
        while (loop.tryEvent() catch null) |ev| switch (ev) {
            .winsize => |ws| {
                vx.resize(gpa_, tty.writer(), ws) catch {};
                return .resize;
            },
            .key_press => |k| {
                const mapped = mapKey(k);
                if (mapped != .none) return mapped;
            },
            else => {},
        };
        io_.sleep(.fromMilliseconds(25), .awake) catch {};
    }
    return .none;
}

fn mapKey(k: vaxis.Key) Key {
    if (k.matches('c', .{ .ctrl = true })) return .ctrl_c;
    return switch (k.codepoint) {
        vaxis.Key.up => .up,
        vaxis.Key.down => .down,
        vaxis.Key.left => .left,
        vaxis.Key.right => .right,
        vaxis.Key.page_up => .page_up,
        vaxis.Key.page_down => .page_down,
        vaxis.Key.home => .home,
        vaxis.Key.end => .end,
        vaxis.Key.enter => .enter,
        vaxis.Key.escape => .esc,
        vaxis.Key.backspace => .backspace,
        vaxis.Key.tab => .tab,
        else => blk: {
            // Prefer the generated text (handles Shift, e.g. '?').
            if (k.text) |t| {
                if (t.len > 0) {
                    const len = std.unicode.utf8ByteSequenceLength(t[0]) catch break :blk .none;
                    if (len <= t.len) {
                        const cp = std.unicode.utf8Decode(t[0..len]) catch break :blk .none;
                        if (cp >= 32) break :blk .{ .char = cp };
                    }
                }
            }
            if (k.mods.ctrl or k.mods.alt or k.mods.super) break :blk .none;
            break :blk if (k.codepoint >= 32 and k.codepoint < 0x110000) .{ .char = k.codepoint } else .none;
        },
    };
}
