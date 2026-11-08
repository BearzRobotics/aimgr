//! A private llama-server for one agent session: started on a free loopback port, probed for tool
//! support, and always stopped when the session ends. Bound to 127.0.0.1 only; never public.
const std = @import("std");
const http = @import("../http.zig");
const netstat = @import("../netstat.zig");
const supervise = @import("../supervise.zig");
const launcher = @import("../launcher.zig");

pub const Server = struct {
    child: std.process.Child,
    pid: i32,
    port: u16,
    log_path: []const u8,

    /// SIGTERM, then wait. llama exits promptly; a hung server is killed after ~15 s (it is aimgr's own helper process).
    pub fn stop(self: *Server, gpa: std.mem.Allocator, io: std.Io) void {
        std.posix.kill(self.pid, .TERM) catch {};
        var waited: u32 = 0;
        while (supervise.pidAlive(gpa, io, self.pid) and waited < 60) : (waited += 1) {
            io.sleep(.fromMilliseconds(250), .awake) catch {};
        }
        if (supervise.pidAlive(gpa, io, self.pid)) std.posix.kill(self.pid, .KILL) catch {};
        _ = self.child.wait(io) catch {};
    }
};

pub const StartError = error{ NoFreePort, SpawnFailed, ExitedEarly, Timeout, OutOfMemory };

pub fn startErrorText(e: StartError) []const u8 {
    return switch (e) {
        error.NoFreePort => "no free port in 19900-19999",
        error.SpawnFailed => "could not start llama",
        error.ExitedEarly => "llama exited before it was ready",
        error.Timeout => "llama did not become ready in time",
        error.OutOfMemory => "out of memory",
    };
}

pub fn freePort(gpa: std.mem.Allocator, io: std.Io) ?u16 {
    var p: u16 = 19900;
    while (p < 20000) : (p += 1) if (!netstat.isListening(gpa, io, p)) return p;
    return null;
}

/// Start `llama serve --offline -hf <id> --jinja ...` on 127.0.0.1:<port>, logging to `log_dir`.
pub fn start(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, id: []const u8, ctx: u32, log_dir: ?[]const u8, out: *std.Io.Writer, wait_s: u32) StartError!Server {
    const port = freePort(gpa, io) orelse return error.NoFreePort;
    const pl = launcher.plan(arena, .llama, .server, id, .{ .port = port, .ctx = ctx }) catch return error.SpawnFailed;
    var argv: std.ArrayList([]const u8) = .empty;
    // Tie the server's life to ours at the kernel level (PR_SET_PDEATHSIG): if aimgr is killed, even with
    // SIGKILL, the server receives SIGTERM instead of lingering as an orphan.
    const have_setpriv = if (std.Io.Dir.cwd().access(io, "/usr/bin/setpriv", .{})) |_| true else |_| false;
    if (have_setpriv) {
        argv.appendSlice(arena, &.{ "/usr/bin/setpriv", "--pdeathsig", "TERM", "--" }) catch return error.OutOfMemory;
    } else out.writeAll("warning: setpriv not found; if aimgr is killed abruptly the llama server may keep running (stop it manually)\n") catch {};
    argv.appendSlice(arena, pl.argv) catch return error.OutOfMemory;
    argv.append(arena, "--jinja") catch return error.OutOfMemory; // chat-template tool calling

    var log_path: []const u8 = "(none)";
    var sink: std.process.SpawnOptions.StdIo = .ignore;
    var log_file: ?std.Io.File = null;
    if (log_dir) |d| {
        std.Io.Dir.cwd().createDirPath(io, d) catch {};
        log_path = std.fmt.allocPrint(arena, "{s}/agent-llama-{d}.log", .{ d, port }) catch return error.OutOfMemory;
        log_file = std.Io.Dir.cwd().createFile(io, log_path, .{ .truncate = true }) catch null;
        if (log_file) |f| sink = .{ .file = f };
    }
    defer if (log_file) |f| f.close(io);

    out.print("starting llama for {s} on 127.0.0.1:{d} (loading the model can take a while; log: {s})\n", .{ id, port, log_path }) catch {};
    out.flush() catch {};
    const child = std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = env,
        .stdin = .ignore,
        .stdout = sink,
        .stderr = sink,
    }) catch return error.SpawnFailed;
    const pid: i32 = @intCast(child.id.?);
    var srv: Server = .{ .child = child, .pid = pid, .port = port, .log_path = log_path };

    const url = std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/health", .{port}) catch return error.OutOfMemory;
    var ticks: u32 = 0;
    const max_ticks = wait_s * 2;
    while (ticks < max_ticks) : (ticks += 1) {
        if (!supervise.pidAlive(gpa, io, pid)) {
            _ = srv.child.wait(io) catch {};
            return error.ExitedEarly;
        }
        if (http.getLocal(gpa, io, url, 4096)) |body| {
            defer gpa.free(body);
            if (std.mem.indexOf(u8, body, "\"ok\"") != null) return srv;
        } else |_| {}
        io.sleep(.fromMilliseconds(500), .awake) catch {};
    }
    srv.stop(gpa, io);
    return error.Timeout;
}

/// `chat_template_caps.supports_tools` from GET /props. Null when it cannot be read.
pub fn supportsTools(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, port: u16) ?bool {
    const url = std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/props", .{port}) catch return null;
    const body = http.getLocal(gpa, io, url, 4 << 20) catch return null;
    defer gpa.free(body);
    return parseSupportsTools(arena, body);
}

pub fn parseSupportsTools(arena: std.mem.Allocator, body: []const u8) ?bool {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch return null;
    if (parsed.value != .object) return null;
    const caps = parsed.value.object.get("chat_template_caps") orelse return null;
    if (caps != .object) return null;
    const v = caps.object.get("supports_tools") orelse return null;
    return if (v == .bool) v.bool else null;
}

test "props: supports_tools" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectEqual(@as(?bool, true), parseSupportsTools(a.allocator(), "{\"chat_template_caps\":{\"supports_tools\":true,\"supports_system_role\":true},\"model_path\":\"/x\"}"));
    try std.testing.expectEqual(@as(?bool, false), parseSupportsTools(a.allocator(), "{\"chat_template_caps\":{\"supports_tools\":false}}"));
    try std.testing.expectEqual(@as(?bool, null), parseSupportsTools(a.allocator(), "{\"model_path\":\"/x\"}"));
    try std.testing.expectEqual(@as(?bool, null), parseSupportsTools(a.allocator(), "garbage"));
}
