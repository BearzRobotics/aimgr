//! Long-running and repository tools: run_background / check_background / stop_background and
//! enter_worktree / exit_worktree. Every start or removal is approved by the user; everything a session
//! starts is stopped when the session ends (and, via the kernel, if aimgr itself is killed).
const std = @import("std");
const policy = @import("policy.zig");
const tools = @import("tools.zig");
const envm = @import("env.zig");
const calls = @import("calls.zig");
const process = @import("../process.zig");
const supervise = @import("../supervise.zig");

const Env = envm.Env;
const State = envm.State;
const Outcome = calls.Outcome;

pub const max_background = 4;

pub fn handle(e: Env, st: *State, arena: std.mem.Allocator, s: policy.Settings, sandbox_on: bool, tool: tools.Tool, args: std.json.ObjectMap) !Outcome {
    return switch (tool) {
        .run_background => runBackground(e, st, arena, s, sandbox_on, args),
        .check_background => checkBackground(e, st, arena, args),
        .stop_background => stopBackground(e, st, arena, args),
        .enter_worktree => enterWorktree(e, st, arena, s, args),
        .exit_worktree => exitWorktree(e, st, arena, args),
        else => calls.denied(arena, "not a workflow tool"),
    };
}

fn declined(reason: []const u8) Outcome {
    return .{ .text = "DENIED: the user declined", .decision = "declined", .reason = reason };
}

// ---- background tasks ------------------------------------------------------------------------

fn runBackground(e: Env, st: *State, arena: std.mem.Allocator, s: policy.Settings, sandbox_on: bool, args: std.json.ObjectMap) !Outcome {
    const sh = policy.effectiveShell(s);
    if (sh == .none) return calls.denied(arena, "background tasks need a shell (level 'ask' and shell other than 'none')");
    const command = calls.getStr(args, "command") orelse return calls.denied(arena, "missing 'command'");
    if (command.len == 0 or command.len > 4000 or std.mem.indexOfScalar(u8, command, 0) != null) return calls.denied(arena, "command must be 1-4000 characters without NUL");
    if (tools.mentionsRootEscalation(command) and !s.allow_root) return calls.denied(arena, "privilege escalation (sudo/su/doas) is disabled for this model");
    var running: usize = 0;
    for (st.bg.items) |*b| if (taskRunning(e, b)) {
        running += 1;
    };
    if (running >= max_background) return calls.denied(arena, "at most 4 background tasks at once: stop one first");
    const log_dir = e.state_dir orelse return calls.denied(arena, "no state directory for background logs");
    const shell_path = tools.findExecutable(arena, e.io, sh.text(), e.path_env, e.home) orelse
        return calls.denied(arena, try std.fmt.allocPrint(arena, "the shell '{s}' was not found", .{sh.text()}));

    const warn = tools.shellWarnings(command);
    try e.out.print("\n  --- BACKGROUND TASK ({s}, {s})\n", .{ sh.text(), if (sandbox_on) "sandboxed: no network, writes only inside the allowed directories" else "NOT SANDBOXED: runs with your full privileges" });
    var lines = std.mem.splitScalar(u8, command, '\n');
    while (lines.next()) |l| try e.out.print("    $ {s}\n", .{l});
    if (warn.len > 0) try e.out.print("    WARNING: {s}\n", .{warn});
    if (!calls.ask(e, st, try std.fmt.allocPrint(arena, "START this in the background{s}? (it keeps running until you stop it or the session ends)", .{if (sandbox_on) "" else " WITHOUT a sandbox"}))) return declined("background");

    std.Io.Dir.cwd().createDirPath(e.io, log_dir) catch {};
    const id = st.next_bg;
    const log_path = try e.gpa.dupe(u8, try std.fmt.allocPrint(arena, "{s}/task-{d}-{d}.log", .{ log_dir, std.Io.Clock.real.now(e.io).toSeconds(), id }));
    errdefer e.gpa.free(log_path);
    var log_file = std.Io.Dir.cwd().createFile(e.io, log_path, .{ .truncate = true }) catch return calls.denied(arena, "cannot create the log file");
    defer log_file.close(e.io);

    const base = try tools.shellArgv(arena, sh, shell_path, command);
    var argv: std.ArrayList([]const u8) = .empty;
    if (sandbox_on) {
        var extra: std.ArrayList([]const u8) = .empty;
        const under_sys = std.mem.startsWith(u8, shell_path, "/usr/") or std.mem.startsWith(u8, shell_path, "/bin/");
        if (!under_sys) if (std.fs.path.dirname(shell_path)) |d| try extra.append(arena, d);
        try argv.appendSlice(arena, try tools.bwrapArgvWith(arena, s, extra.items, base)); // bwrap --die-with-parent
    } else {
        if (std.Io.Dir.cwd().access(e.io, "/usr/bin/setpriv", .{})) |_| {
            try argv.appendSlice(arena, &.{ "/usr/bin/setpriv", "--pdeathsig", "TERM", "--" });
        } else |_| {}
        try argv.appendSlice(arena, base);
    }
    const child = std.process.spawn(e.io, .{
        .argv = argv.items,
        .cwd = if (sandbox_on or s.dirs.len == 0) .inherit else .{ .path = s.dirs[0] },
        .stdin = .ignore,
        .stdout = .{ .file = log_file },
        .stderr = .{ .file = log_file },
    }) catch return calls.denied(arena, "could not start the task");
    try st.bg.append(e.gpa, .{
        .id = id,
        .pid = @intCast(child.id.?),
        .log_path = log_path,
        .command = try e.gpa.dupe(u8, command[0..@min(command.len, 200)]),
        .child = child,
    });
    st.next_bg += 1;
    try e.out.print("  [run_background] started #{d}\n", .{id});
    return .{ .text = try std.fmt.allocPrint(arena, "started background task #{d}. Use check_background({d}) to see its output, stop_background({d}) to stop it.", .{ id, id, id }), .decision = "approved", .reason = "background" };
}

fn taskRunning(e: Env, b: *envm.Bg) bool {
    if (b.reaped) return false;
    if (supervise.pidAlive(e.gpa, e.io, b.pid)) return true;
    reap(e, b);
    return false;
}

fn reap(e: Env, b: *envm.Bg) void {
    if (b.reaped) return;
    b.reaped = true;
    if (b.child.wait(e.io)) |term| switch (term) {
        .exited => |c| b.exit_code = c,
        else => {},
    } else |_| {}
}

fn findTask(st: *State, id: u64) ?*envm.Bg {
    for (st.bg.items) |*b| if (b.id == id) return b;
    return null;
}

fn tailOf(e: Env, arena: std.mem.Allocator, path: []const u8, max: u64) ![]const u8 {
    var f = std.Io.Dir.cwd().openFile(e.io, path, .{}) catch return "";
    defer f.close(e.io);
    const len = f.length(e.io) catch return "";
    const start = if (len > max) len - max else 0;
    const buf = try arena.alloc(u8, @intCast(@min(len, max)));
    const n = f.readPositionalAll(e.io, buf, start) catch return "";
    return buf[0..n];
}

fn checkBackground(e: Env, st: *State, arena: std.mem.Allocator, args: std.json.ObjectMap) !Outcome {
    const id = calls.getInt(args, "id") orelse return calls.denied(arena, "missing 'id'");
    const b = findTask(st, id) orelse return calls.denied(arena, "no such background task in this session");
    const running = taskRunning(e, b);
    const tail = try tailOf(e, arena, b.log_path, 8192);
    const status: []const u8 = if (running) "running" else if (b.exit_code) |c| try std.fmt.allocPrint(arena, "exited with code {d}", .{c}) else "ended abnormally";
    try e.out.print("  [check_background] #{d}: {s}\n", .{ id, status });
    return .{ .text = try std.fmt.allocPrint(arena, "[task #{d}: {s}] (command: {s})\n[end of its output so far]\n{s}", .{ id, status, b.command, tail }), .decision = "auto", .reason = "" };
}

fn killTask(e: Env, b: *envm.Bg) void {
    if (b.reaped) return;
    if (supervise.pidAlive(e.gpa, e.io, b.pid)) {
        std.posix.kill(b.pid, .TERM) catch {};
        var waited: u32 = 0;
        while (supervise.pidAlive(e.gpa, e.io, b.pid) and waited < 12) : (waited += 1) e.io.sleep(.fromMilliseconds(250), .awake) catch {};
        if (supervise.pidAlive(e.gpa, e.io, b.pid)) std.posix.kill(b.pid, .KILL) catch {};
    }
    reap(e, b);
}

fn stopBackground(e: Env, st: *State, arena: std.mem.Allocator, args: std.json.ObjectMap) !Outcome {
    const id = calls.getInt(args, "id") orelse return calls.denied(arena, "missing 'id'");
    const b = findTask(st, id) orelse return calls.denied(arena, "no such background task in this session");
    killTask(e, b);
    try e.out.print("  [stop_background] #{d} stopped\n", .{id});
    return .{ .text = try std.fmt.allocPrint(arena, "background task #{d} stopped", .{id}), .decision = "auto", .reason = "" };
}

/// Called when a session ends: stop everything it started and free the records.
pub fn cleanup(e: Env, st: *State) void {
    for (st.bg.items) |*b| {
        killTask(e, b);
        e.gpa.free(b.log_path);
        e.gpa.free(b.command);
    }
    st.bg.deinit(e.gpa);
    if (st.worktree) |w| {
        e.gpa.free(w.path);
        e.gpa.free(w.branch);
        e.gpa.free(w.toplevel);
    }
}

// ---- git worktrees ---------------------------------------------------------------------------

pub fn validWorktreeName(n: []const u8) bool {
    if (n.len == 0 or n.len > 40 or n[0] == '-' or n[0] == '.') return false;
    for (n) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-' or c == '_' or c == '.')) return false;
    return true;
}

fn git(e: Env, arena: std.mem.Allocator, argv_tail: []const []const u8) !process.Result {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, "git");
    try argv.appendSlice(arena, argv_tail);
    return process.run(e.gpa, e.io, argv.items, 30);
}

fn enterWorktree(e: Env, st: *State, arena: std.mem.Allocator, s: policy.Settings, args: std.json.ObjectMap) !Outcome {
    if (st.worktree != null) return calls.denied(arena, "already in a worktree: call exit_worktree first");
    const name = calls.getStr(args, "name") orelse return calls.denied(arena, "missing 'name'");
    if (!validWorktreeName(name)) return calls.denied(arena, "the name must be 1-40 characters: lowercase letters, digits, - _ .");
    if (s.dirs.len == 0) return calls.denied(arena, "no working directory");
    const here = s.dirs[0];
    const top_r = try git(e, arena, &.{ "-C", here, "rev-parse", "--show-toplevel" });
    defer top_r.deinit(e.gpa);
    if (!top_r.ok()) return calls.denied(arena, "the working directory is not inside a git repository");
    const toplevel = std.mem.trim(u8, top_r.stdout, " \n\r");
    const wt_path = try std.fmt.allocPrint(arena, "{s}/.aimgr-worktrees/{s}", .{ std.mem.trimEnd(u8, here, "/"), name });
    const branch = try std.fmt.allocPrint(arena, "aimgr/{s}", .{name});
    if (tools.pathExists(e.io, wt_path)) return calls.denied(arena, "that worktree path already exists");
    try e.out.print("\n  --- GIT WORKTREE\n    $ git -C {s} worktree add -b {s} {s}\n", .{ toplevel, branch, wt_path });
    if (!calls.ask(e, st, "CREATE this worktree and switch to it?")) return declined("worktree");
    const r = try git(e, arena, &.{ "-C", toplevel, "worktree", "add", "-b", branch, wt_path });
    defer r.deinit(e.gpa);
    if (!r.ok()) return calls.denied(arena, try std.fmt.allocPrint(arena, "git said: {s}", .{std.mem.trim(u8, r.stderr, " \n")}));
    st.worktree = .{ .path = try e.gpa.dupe(u8, wt_path), .branch = try e.gpa.dupe(u8, branch), .toplevel = try e.gpa.dupe(u8, toplevel) };
    return .{ .text = try std.fmt.allocPrint(arena, "worktree created on branch {s}. Relative paths now resolve in {s}; the original directory stays readable.", .{ branch, wt_path }), .decision = "approved", .reason = "worktree" };
}

fn exitWorktree(e: Env, st: *State, arena: std.mem.Allocator, args: std.json.ObjectMap) !Outcome {
    const w = st.worktree orelse return calls.denied(arena, "not in a worktree");
    const action = calls.getStr(args, "action") orelse return calls.denied(arena, "missing 'action' (keep or remove)");
    if (std.mem.eql(u8, action, "remove")) {
        try e.out.print("\n  --- REMOVE WORKTREE\n    $ git -C {s} worktree remove --force {s}   (the branch {s} is kept)\n", .{ w.toplevel, w.path, w.branch });
        if (!calls.ask(e, st, "DELETE this worktree directory (uncommitted work in it is lost)?")) return declined("worktree");
        const r = try git(e, arena, &.{ "-C", w.toplevel, "worktree", "remove", "--force", w.path });
        defer r.deinit(e.gpa);
        if (!r.ok()) return calls.denied(arena, try std.fmt.allocPrint(arena, "git said: {s}", .{std.mem.trim(u8, r.stderr, " \n")}));
    } else if (!std.mem.eql(u8, action, "keep")) return calls.denied(arena, "action must be 'keep' or 'remove'");
    const msg = try std.fmt.allocPrint(arena, "left the worktree ({s}); branch {s} {s}", .{ w.path, w.branch, if (std.mem.eql(u8, action, "keep")) "and its files are kept for you to review or merge" else "is kept" });
    e.gpa.free(w.path);
    e.gpa.free(w.branch);
    e.gpa.free(w.toplevel);
    st.worktree = null;
    return .{ .text = msg, .decision = if (std.mem.eql(u8, action, "keep")) "auto" else "approved", .reason = "worktree" };
}

/// Settings as the tools should see them: inside a worktree it is the first (working) directory.
pub fn view(arena: std.mem.Allocator, s: policy.Settings, st: *const State) !policy.Settings {
    const w = st.worktree orelse return s;
    var out = s;
    var dirs: std.ArrayList([]const u8) = .empty;
    try dirs.append(arena, w.path);
    try dirs.appendSlice(arena, s.dirs);
    out.dirs = try dirs.toOwnedSlice(arena);
    return out;
}

test "worktree names" {
    try std.testing.expect(validWorktreeName("try-new_idea.2"));
    for ([_][]const u8{ "", "-x", ".hidden", "Up", "a b", "a/b", "../x" }) |bad| try std.testing.expect(!validWorktreeName(bad));
}

test "view puts the worktree first and keeps the originals" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    var st: State = .{};
    const base: policy.Settings = .{ .level = .ask, .dirs = &.{"/repo"} };
    const same = try view(a.allocator(), base, &st);
    try std.testing.expectEqual(@as(usize, 1), same.dirs.len);
    st.worktree = .{ .path = "/repo/.aimgr-worktrees/x", .branch = "aimgr/x", .toplevel = "/repo" };
    const v = try view(a.allocator(), base, &st);
    try std.testing.expectEqualStrings("/repo/.aimgr-worktrees/x", v.dirs[0]);
    try std.testing.expectEqualStrings("/repo", v.dirs[1]);
    st.worktree = null; // do not free the string literals in cleanup
}
