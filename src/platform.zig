//! The few OS-specific operations aimgr needs, in one place: process ids, stopping processes,
//! interrupt handlers. Everything else is portable std. Linux behaviour is unchanged; Windows uses
//! process handles (std.process.Child.Id is a HANDLE there).
const std = @import("std");
const builtin = @import("builtin");
const netstat = @import("netstat.zig");

pub const is_windows = builtin.os.tag == .windows;

/// A running child: pid on POSIX, process HANDLE on Windows.
pub const Pid = std.process.Child.Id;

const win = if (is_windows) struct {
    const HANDLE = std.os.windows.HANDLE;
    extern "kernel32" fn TerminateProcess(h: HANDLE, code: c_uint) callconv(.winapi) c_int;
    extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: c_uint) callconv(.winapi) c_uint;
    extern "kernel32" fn OpenProcess(access: c_uint, inherit: c_int, pid: c_uint) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) c_int;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) c_uint;
    extern "kernel32" fn GetProcessId(h: HANDLE) callconv(.winapi) c_uint;
    const COORD = extern struct { x: i16, y: i16 };
    const SMALL_RECT = extern struct { left: i16, top: i16, right: i16, bottom: i16 };
    const CSBI = extern struct { size: COORD, cursor: COORD, attributes: u16, window: SMALL_RECT, max_size: COORD };
    extern "kernel32" fn GetStdHandle(n: u32) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn GetConsoleScreenBufferInfo(h: HANDLE, info: *CSBI) callconv(.winapi) c_int;
    extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, len: u32, written: *u32, overlapped: ?*anyopaque) callconv(.winapi) c_int;
    extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: [*:0]const u16) callconv(.winapi) c_int;
    extern "kernel32" fn SetConsoleCtrlHandler(cb: ?*const fn (c_uint) callconv(.winapi) c_int, add: c_int) callconv(.winapi) c_int;
} else struct {};

/// The id of a spawned child as a plain number (for messages).
pub fn pidNumber(pid: Pid) u32 {
    if (is_windows) return win.GetProcessId(pid);
    return @intCast(pid);
}

pub fn selfPid() u32 {
    if (is_windows) return win.GetCurrentProcessId();
    return @intCast(std.os.linux.getpid());
}

/// Is the child still running (a zombie counts as gone)?
pub fn alive(gpa: std.mem.Allocator, io: std.Io, pid: Pid) bool {
    if (is_windows) return win.WaitForSingleObject(pid, 0) == 0x102; // WAIT_TIMEOUT
    return aliveNumber(gpa, io, @intCast(pid));
}

/// Is a process with this number alive? (used for lock files)
pub fn aliveNumber(gpa: std.mem.Allocator, io: std.Io, n: u32) bool {
    if (is_windows) {
        const h = win.OpenProcess(0x00100000, 0, n) orelse return false; // SYNCHRONIZE
        defer _ = win.CloseHandle(h);
        return win.WaitForSingleObject(h, 0) == 0x102;
    }
    var buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "/proc/{d}/stat", .{n}) catch return false;
    const text = netstat.readProc(gpa, io, path, 4096) catch return false;
    defer gpa.free(text);
    const rp = std.mem.lastIndexOfScalar(u8, text, ')') orelse return false;
    if (rp + 2 >= text.len) return false;
    return text[rp + 2] != 'Z';
}

/// Ask nicely (SIGTERM). Windows has no equivalent for GUI-less children: it ends the process.
pub fn terminate(pid: Pid) void {
    if (is_windows) {
        _ = win.TerminateProcess(pid, 1);
        return;
    }
    std.posix.kill(pid, .TERM) catch {};
}

pub fn killHard(pid: Pid) void {
    if (is_windows) {
        _ = win.TerminateProcess(pid, 1);
        return;
    }
    std.posix.kill(pid, .KILL) catch {};
}

var interrupt_cb: ?*const fn () void = null;

fn posixHandler(_: std.posix.SIG) callconv(.c) void {
    if (interrupt_cb) |cb| cb();
}

fn winHandler(_: c_uint) callconv(.winapi) c_int {
    if (interrupt_cb) |cb| cb();
    return 1;
}

/// Call `cb` (async-signal-safe: set an atomic flag) on Ctrl-C / termination (and hangup on POSIX).
pub fn onInterrupt(cb: *const fn () void, hangup: bool) void {
    interrupt_cb = cb;
    if (is_windows) {
        _ = win.SetConsoleCtrlHandler(winHandler, 1);
        return;
    }
    const act: std.posix.Sigaction = .{ .handler = .{ .handler = posixHandler }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
    if (hangup) std.posix.sigaction(.HUP, &act, null);
}

/// Back to default handling (before exec of children on POSIX).
pub fn resetInterrupt() void {
    if (is_windows) {
        _ = win.SetConsoleCtrlHandler(null, 0);
        return;
    }
    const act: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
}

/// Windows: put `dir` first on this process's PATH (and in `env`, which spawned children inherit), so tools
/// installed by `aimgr setup-backends` are found by name. No-op elsewhere.
pub fn prependPath(arena: std.mem.Allocator, env: *std.process.Environ.Map, dir: []const u8) void {
    if (!is_windows) return;
    const old = env.get("PATH") orelse env.get("Path") orelse "";
    const joined = std.fmt.allocPrint(arena, "{s};{s}", .{ dir, old }) catch return;
    env.put("PATH", joined) catch {};
    const k = std.unicode.utf8ToUtf16LeAllocZ(arena, "PATH") catch return;
    const v = std.unicode.utf8ToUtf16LeAllocZ(arena, joined) catch return;
    _ = win.SetEnvironmentVariableW(k, v);
}

/// Columns of the terminal on stdout, or null when stdout is not a terminal.
pub fn termWidth() ?u16 {
    const sz = termSize() orelse return null;
    return sz.cols;
}

pub const Size = struct { rows: u16, cols: u16 };

/// Rows and columns of the terminal on stdout, or null when stdout is not a terminal.
pub fn termSize() ?Size {
    if (is_windows) {
        const h = win.GetStdHandle(@bitCast(@as(i32, -11))) orelse return null; // STD_OUTPUT_HANDLE
        var info: win.CSBI = undefined;
        if (win.GetConsoleScreenBufferInfo(h, &info) == 0) return null;
        const w = info.window.right - info.window.left + 1;
        const ht = info.window.bottom - info.window.top + 1;
        if (w <= 0 or ht <= 0) return null;
        return .{ .rows = @intCast(ht), .cols = @intCast(w) };
    }
    var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const rc = std.posix.system.ioctl(1, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (std.posix.errno(rc) != .SUCCESS or ws.col == 0 or ws.row == 0) return null;
    return .{ .rows = ws.row, .cols = ws.col };
}

/// Write bytes straight to stdout without buffering (safe to call from an interrupt handler).
pub fn writeStdoutRaw(bytes: []const u8) void {
    if (is_windows) {
        const h = win.GetStdHandle(@bitCast(@as(i32, -11))) orelse return;
        var n: u32 = 0;
        _ = win.WriteFile(h, bytes.ptr, @intCast(bytes.len), &n, null);
        return;
    }
    _ = std.posix.system.write(1, bytes.ptr, bytes.len);
}
