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
