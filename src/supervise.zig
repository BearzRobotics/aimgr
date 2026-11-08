//! Running launch plans: foreground chat and supervised servers.
//! Global state: one atomic flag set from the signal handler (documented
//! exception to the no-global-state rule; signal handlers cannot take context).
const std = @import("std");
const launcher = @import("launcher.zig");
const netstat = @import("netstat.zig");
const dlwatch = @import("dlwatch.zig");

var stop_requested = std.atomic.Value(u8).init(0);

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    _ = stop_requested.fetchAdd(1, .monotonic);
}

/// Handler (not SIG_IGN) so the disposition resets to default across exec in children.
fn installHandlers() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
}

fn resetHandlers() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
}

pub const Env = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    /// Where server logs go (null: discard, with a warning).
    log_dir: ?[]const u8,
};

fn mergedEnv(e: Env, plan: launcher.Plan) !std.process.Environ.Map {
    var m = try e.environ.clone(e.gpa);
    errdefer m.deinit();
    for (plan.env) |kv| try m.put(kv[0], kv[1]);
    return m;
}

/// Foreground interactive chat. The child owns the terminal; aimgr waits and
/// returns the child's exit code. The terminal is not modified by aimgr here,
/// so there is nothing to restore (the TUI milestone must restore on its side).
pub fn runChat(e: Env, plan: launcher.Plan) !u8 {
    var env = try mergedEnv(e, plan);
    defer env.deinit();
    installHandlers(); // aimgr survives Ctrl-C; the child (same process group) receives it too
    defer resetHandlers();
    var child = std.process.spawn(e.io, .{
        .argv = plan.argv,
        .environ_map = &env,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        try e.err.print("aimgr: cannot start {s}: {s}\n", .{ plan.argv[0], @errorName(err) });
        return 1;
    };
    const term = try child.wait(e.io);
    return switch (term) {
        .exited => |c| c,
        else => 1,
    };
}

fn pidAlive(gpa: std.mem.Allocator, io: std.Io, pid: i32) bool {
    var buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "/proc/{d}/stat", .{pid}) catch return false;
    const text = netstat.readProc(gpa, io, path, 4096) catch return false;
    defer gpa.free(text);
    const rp = std.mem.lastIndexOfScalar(u8, text, ')') orelse return false;
    if (rp + 2 >= text.len) return false;
    return text[rp + 2] != 'Z';
}

/// Ask a yes/no question on stdin. Anything but "y"/"yes" (or unreadable stdin) is no.
pub fn confirm(e: Env, question: []const u8) bool {
    e.out.print("{s} [y/N] ", .{question}) catch return false;
    e.out.flush() catch return false;
    var buf: [64]u8 = undefined;
    var r = std.Io.File.stdin().reader(e.io, &buf);
    const line = r.interface.takeDelimiter('\n') catch return false;
    const l = std.mem.trim(u8, line orelse return false, " \r\t");
    return std.ascii.eqlIgnoreCase(l, "y") or std.ascii.eqlIgnoreCase(l, "yes");
}

const StopState = struct { term_sent_at: ?u32 = null };

/// Graceful stop on first signal (SIGTERM); escalate to SIGKILL only with user
/// approval (second signal, or ~10 s after SIGTERM at 250 ms ticks).
fn pollStop(e: Env, pid: i32, tick: u32, st: *StopState, label: []const u8) !void {
    const stops = stop_requested.load(.monotonic);
    if (stops > 0 and st.term_sent_at == null) {
        try e.out.print("{s}: stopping (SIGTERM)...\n", .{label});
        try e.out.flush();
        std.posix.kill(pid, .TERM) catch {};
        st.term_sent_at = tick;
    } else if (st.term_sent_at) |t0| {
        if (stops > 1 or tick - t0 > 40) {
            if (confirm(e, "process has not exited; send SIGKILL?")) {
                std.posix.kill(pid, .KILL) catch {};
            } else {
                st.term_sent_at = tick;
                stop_requested.store(1, .monotonic);
            }
        }
    }
}

/// Run a transfer (pull/remove) in the foreground. The child's own progress
/// output goes straight to the terminal. Ctrl-C cancels gracefully.
/// Returns the child's exit code, or 130 when cancelled.
pub fn runTransfer(e: Env, argv: []const []const u8, label: []const u8) !u8 {
    return runTransferEnv(e, argv, null, label);
}

/// Like runTransfer with an explicit child environment (null = inherit aimgr's).
pub fn runTransferEnv(e: Env, argv: []const []const u8, env: ?*const std.process.Environ.Map, label: []const u8) !u8 {
    return runTransferWatch(e, argv, env, label, null);
}

/// Watch a growing download: aimgr prints "aimgr-progress: done=N total=M" lines (about once a
/// second, only when the value changed) because llama itself prints nothing when not on a terminal.
pub const Watch = struct {
    /// <hub cache>/models--owner--repo/blobs
    dir: []const u8,
    /// Expected bytes; 0 = unknown.
    total: u64,
};

/// Like runTransferEnv, additionally reporting download progress for `watch`.
pub fn runTransferWatch(e: Env, argv: []const []const u8, env: ?*const std.process.Environ.Map, label: []const u8, watch: ?Watch) !u8 {
    installHandlers();
    defer resetHandlers();
    stop_requested.store(0, .monotonic);
    var child = std.process.spawn(e.io, .{
        .argv = argv,
        .environ_map = env orelse e.environ,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        try e.err.print("aimgr: cannot start {s}: {s}\n", .{ argv[0], @errorName(err) });
        return 1;
    };
    const pid: i32 = @intCast(child.id.?);
    var stop: StopState = .{};
    var tick: u32 = 0;
    var best: u64 = 0;
    var printed: u64 = std.math.maxInt(u64);
    while (pidAlive(e.gpa, e.io, pid)) : (tick += 1) {
        try pollStop(e, pid, tick, &stop, label);
        if (watch) |w| if (tick % 4 == 0) {
            best = @max(best, dlwatch.bytesInProgress(e.io, w.dir)); // monotonic: blobs are renamed when complete
            if (w.total > 0) best = @min(best, w.total);
            if (best != printed) {
                try e.out.print("aimgr-progress: done={d} total={d}\n", .{ best, w.total });
                try e.out.flush();
                printed = best;
            }
        };
        e.io.sleep(.fromMilliseconds(250), .awake) catch {};
    }
    const term = child.wait(e.io) catch return 1;
    if (watch) |w| if (w.total > 0 and term == .exited and term.exited == 0) {
        try e.out.print("aimgr-progress: done={d} total={d}\n", .{ w.total, w.total });
        try e.out.flush();
    };
    const cancelled = stop.term_sent_at != null or stop_requested.load(.monotonic) > 0;
    switch (term) {
        .exited => |c| {
            if (cancelled) {
                try e.err.print("aimgr: {s} cancelled\n", .{label});
                return 130;
            }
            return c;
        },
        else => {
            if (cancelled) {
                try e.err.print("aimgr: {s} cancelled\n", .{label});
                return 130;
            }
            try e.err.print("aimgr: {s} terminated abnormally\n", .{label});
            return 1;
        },
    }
}

/// Run a server plan until it exits or the user stops it. Reports "listening"
/// only after the port is observed in LISTEN state.
pub fn runServer(e: Env, plan: launcher.Plan, label: []const u8) !u8 {
    const port = plan.listen_port.?;
    if (netstat.isListening(e.gpa, e.io, port)) {
        try e.err.print("aimgr: port {d} is already in use; not starting {s}\n", .{ port, label });
        return 1;
    }
    var env = try mergedEnv(e, plan);
    defer env.deinit();

    var log_file: ?std.Io.File = null;
    var log_path: []const u8 = "(discarded)";
    var log_owned: ?[]u8 = null;
    defer if (log_owned) |p| e.gpa.free(p);
    if (e.log_dir) |dir| {
        std.Io.Dir.cwd().createDirPath(e.io, dir) catch |err| try e.err.print("aimgr: cannot create log dir {s}: {s}\n", .{ dir, @errorName(err) });
        const p = try std.fmt.allocPrint(e.gpa, "{s}/{s}-{d}.log", .{ dir, label, port });
        log_path = p;
        log_owned = p;
        log_file = std.Io.Dir.cwd().createFile(e.io, p, .{ .truncate = true }) catch |err| blk: {
            try e.err.print("aimgr: cannot open log {s}: {s} (output discarded)\n", .{ p, @errorName(err) });
            break :blk null;
        };
    }
    defer if (log_file) |f| f.close(e.io);
    const sink: std.process.SpawnOptions.StdIo = if (log_file) |f| .{ .file = f } else .ignore;

    installHandlers();
    defer resetHandlers();
    stop_requested.store(0, .monotonic);

    var child = std.process.spawn(e.io, .{
        .argv = plan.argv,
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = sink,
        .stderr = sink,
    }) catch |err| {
        try e.err.print("aimgr: cannot start {s}: {s}\n", .{ plan.argv[0], @errorName(err) });
        return 1;
    };
    const pid: i32 = @intCast(child.id.?);
    try e.out.print("{s}: started pid {d}; waiting for port {d}...\n  log: {s}\n", .{ label, pid, port, log_path });
    try e.out.flush();

    var announced = false;
    var stop: StopState = .{};
    var tick: u32 = 0;
    while (pidAlive(e.gpa, e.io, pid)) : (tick += 1) {
        if (!announced and tick % 4 == 0 and netstat.isListening(e.gpa, e.io, port)) {
            announced = true;
            try e.out.print("{s}: listening on {s}:{d} (Ctrl-C to stop)\n", .{ label, plan.listen_host.?, port });
            try e.out.flush();
        }
        try pollStop(e, pid, tick, &stop, label);
        e.io.sleep(.fromMilliseconds(250), .awake) catch {};
    }
    const term = child.wait(e.io) catch return 1;
    switch (term) {
        .exited => |c| {
            if (!announced and stop.term_sent_at == null) {
                try e.err.print("aimgr: {s} exited with code {d} before listening; see {s}\n", .{ label, c, log_path });
                return if (c == 0) 1 else c;
            }
            try e.out.print("{s}: exited with code {d}\n", .{ label, c });
            return c;
        },
        .signal => |s| {
            try e.out.print("{s}: terminated by signal {d}\n", .{ label, @backingInt(s) });
            return if (stop.term_sent_at != null) 0 else 1;
        },
        else => return 1,
    }
}
