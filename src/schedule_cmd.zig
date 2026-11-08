//! `aimgr schedule ...`: saved agent requests that run unattended. See schedule.zig for the safety model:
//! level read-only/inspect only, no shell / web / notifications / questions, anything needing approval is denied.
const std = @import("std");
const backend = @import("backend.zig");
const config = @import("config.zig");
const inventory = @import("inventory.zig");
const modelinfo = @import("modelinfo.zig");
const schedule = @import("schedule.zig");
const sources_io = @import("sources_io.zig");
const platform = @import("platform.zig");
const supervise = @import("supervise.zig");
const agent_cmd = @import("agent_cmd.zig");
const policy = @import("agent/policy.zig");
const settings = @import("agent/settings.zig");

const usage =
    \\usage:
    \\  aimgr schedule add <id> <ollama|llama> <model> --every 6h --dir DIR [--dir DIR]...
    \\                     [--level read-only|inspect] [--steps N] (--task "text" | --task-file FILE)
    \\  aimgr schedule list
    \\  aimgr schedule enable|disable|remove <id>
    \\  aimgr schedule run <id>        run one now (unattended), regardless of when it is due
    \\  aimgr schedule run-due         run every enabled task that is due (this is what a timer calls)
    \\  aimgr schedule results <id>    list saved results
    \\  aimgr schedule install [--yes] | uninstall [--yes]     systemd user timer that calls run-due every 15 minutes
    \\
    \\Unattended runs cannot ask you anything: they use level read-only or inspect, have no shell, web,
    \\notifications or questions, and anything that would need your approval is denied (and shown in the result).
    \\Results: $XDG_STATE_HOME/aimgr/schedule/<id>/<UTC time>.md
    \\
;

fn fail(err: *std.Io.Writer, msg: []const u8) !u8 {
    try err.print("aimgr: {s}\n", .{msg});
    return 2;
}

fn now(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}

fn schedDir(arena: std.mem.Allocator, env: *const std.process.Environ.Map, id: ?[]const u8) !?[]const u8 {
    const sub = if (id) |i| try std.fmt.allocPrint(arena, "schedule/{s}", .{i}) else "schedule";
    return config.statePath(arena, env, sub);
}

fn readLastRun(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, id: []const u8) ?i64 {
    const dir = (schedDir(arena, env, id) catch return null) orelse return null;
    const path = std.fmt.allocPrint(arena, "{s}/last-run", .{dir}) catch return null;
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64)) catch return null;
    return std.fmt.parseInt(i64, std.mem.trim(u8, text, " \n"), 10) catch null;
}

fn writeLastRun(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, id: []const u8, t: i64) void {
    const dir = (schedDir(arena, env, id) catch return) orelse return;
    std.Io.Dir.cwd().createDirPath(io, dir) catch return;
    const path = std.fmt.allocPrint(arena, "{s}/last-run", .{dir}) catch return;
    const text = std.fmt.allocPrint(arena, "{d}\n", .{t}) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch {};
}

pub fn main(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, out: *std.Io.Writer, err: *std.Io.Writer, report: inventory.Inventory, args: []const [:0]const u8) !u8 {
    if (args.len == 0) {
        try err.writeAll(usage);
        return 2;
    }
    const sub = args[0];
    var entries: std.ArrayList(schedule.Entry) = .empty;
    try entries.appendSlice(arena, sources_io.loadSchedules(arena, gpa, io, env) catch |e| {
        try err.print("aimgr: {s}\n", .{schedule.errorText(if (@TypeOf(e) == schedule.Error) e else error.InvalidEntry)});
        return 1;
    });

    if (std.mem.eql(u8, sub, "list")) {
        if (entries.items.len == 0) try out.writeAll("no schedules (see 'aimgr schedule' for how to add one)\n");
        for (entries.items) |e| {
            var ib: [16]u8 = undefined;
            var tb: [40]u8 = undefined;
            const last = readLastRun(arena, io, env, e.id);
            try out.print("{s}  [{s}]  {s} {s}  every {s}  level {s}\n    dirs: ", .{ e.id, if (e.enabled) "enabled" else "disabled", e.backend.name(), e.model, schedule.formatInterval(&ib, e.every_s), e.level.text() });
            for (e.dirs, 0..) |d, i| try out.print("{s}{s}", .{ if (i > 0) ", " else "", d });
            try out.print("\n    last run: {s}   next: {s}\n    task: {s}\n", .{
                if (last) |l| schedule.formatIso(&tb, l) else "never",
                if (!e.enabled) "(disabled)" else if (schedule.nextDue(e, last)) |n| (if (n <= now(io)) "due now" else schedule.formatIso(&tb, n)) else "due now",
                e.task[0..@min(e.task.len, 100)],
            });
        }
        return 0;
    }

    if (std.mem.eql(u8, sub, "add")) return add(arena, gpa, io, env, out, err, report, &entries, args[1..]);

    if (std.mem.eql(u8, sub, "enable") or std.mem.eql(u8, sub, "disable") or std.mem.eql(u8, sub, "remove")) {
        if (args.len != 2) return fail(err, usage);
        const i = schedule.find(entries.items, args[1]) orelse return fail(err, "no such schedule");
        if (std.mem.eql(u8, sub, "remove")) {
            _ = entries.orderedRemove(i);
        } else entries.items[i].enabled = std.mem.eql(u8, sub, "enable");
        try sources_io.saveSchedules(arena, gpa, io, env, entries.items);
        try out.print("{s}: {s}\n", .{ args[1], sub });
        return 0;
    }

    if (std.mem.eql(u8, sub, "results")) {
        if (args.len != 2) return fail(err, usage);
        const dir = (try schedDir(arena, env, args[1])) orelse return fail(err, "no state directory");
        var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch {
            try out.writeAll("no results yet\n");
            return 0;
        };
        defer d.close(io);
        var names: std.ArrayList([]const u8) = .empty;
        var it = d.iterate();
        while (it.next(io) catch null) |en| if (std.mem.endsWith(u8, en.name, ".md")) try names.append(arena, try arena.dupe(u8, en.name));
        std.mem.sort([]const u8, names.items, {}, struct {
            fn gt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, b, a);
            }
        }.gt);
        for (names.items[0..@min(names.items.len, 10)]) |n| try out.print("{s}/{s}\n", .{ dir, n });
        if (names.items.len == 0) try out.writeAll("no results yet\n");
        return 0;
    }

    if (std.mem.eql(u8, sub, "install") or std.mem.eql(u8, sub, "uninstall")) return installUnits(arena, io, env, out, err, std.mem.eql(u8, sub, "install"), args[1..]);

    if (std.mem.eql(u8, sub, "run") or std.mem.eql(u8, sub, "run-due")) {
        const lock = try acquireLock(arena, gpa, io, env, out);
        if (!lock) return 0;
        defer releaseLock(arena, io, env);
        var ran: usize = 0;
        var code: u8 = 0;
        if (std.mem.eql(u8, sub, "run")) {
            if (args.len != 2) return fail(err, usage);
            const i = schedule.find(entries.items, args[1]) orelse return fail(err, "no such schedule");
            code = try runOne(arena, gpa, io, env, out, err, report, entries.items[i]);
            ran = 1;
        } else for (entries.items) |e| {
            if (!schedule.isDue(e, readLastRun(arena, io, env, e.id), now(io))) continue;
            const c = try runOne(arena, gpa, io, env, out, err, report, e);
            if (c != 0) code = 1;
            ran += 1;
        }
        try out.print("schedule: {d} task(s) run\n", .{ran});
        return code;
    }
    return fail(err, usage);
}

fn add(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, out: *std.Io.Writer, err: *std.Io.Writer, report: inventory.Inventory, entries: *std.ArrayList(schedule.Entry), args: []const [:0]const u8) !u8 {
    if (args.len < 3) return fail(err, usage);
    const kind = std.meta.stringToEnum(backend.Kind, args[1]) orelse return fail(err, "backend must be ollama or llama");
    var e: schedule.Entry = .{ .id = args[0], .backend = kind, .model = args[2], .every_s = 0, .task = "", .dirs = &.{} };
    var dirs: std.ArrayList([]const u8) = .empty;
    var i: usize = 3;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return fail(err, usage);
        const k = args[i];
        const v = args[i + 1];
        if (std.mem.eql(u8, k, "--every")) {
            e.every_s = schedule.parseInterval(v) orelse return fail(err, schedule.errorText(error.InvalidInterval));
        } else if (std.mem.eql(u8, k, "--dir")) {
            const real = std.Io.Dir.cwd().realPathFileAlloc(io, v, arena) catch return fail(err, "directory not found");
            try dirs.append(arena, try arena.dupe(u8, real));
        } else if (std.mem.eql(u8, k, "--level")) {
            e.level = policy.Level.parse(v) orelse return fail(err, schedule.errorText(error.InvalidLevel));
        } else if (std.mem.eql(u8, k, "--steps")) {
            e.steps = std.fmt.parseInt(u32, v, 10) catch return fail(err, "--steps needs a number");
        } else if (std.mem.eql(u8, k, "--task")) {
            e.task = v;
        } else if (std.mem.eql(u8, k, "--task-file")) {
            e.task = std.Io.Dir.cwd().readFileAlloc(io, v, arena, .limited(4000)) catch return fail(err, "cannot read the task file (missing or larger than 4000 bytes)");
        } else return fail(err, usage);
    }
    e.dirs = dirs.items;
    schedule.validate(e) catch |er| return fail(err, schedule.errorText(er));
    if (schedule.find(entries.items, e.id) != null) return fail(err, schedule.errorText(error.DuplicateId));
    for (report.reports) |r| if (r.kind == kind) {
        var found = false;
        for (r.models orelse &.{}) |m| if (std.mem.eql(u8, m.id, e.model)) {
            found = true;
        };
        if (!found) return fail(err, "that model is not installed in the backend (exact id required; see 'aimgr list')");
    };
    try entries.append(arena, e);
    try sources_io.saveSchedules(arena, gpa, io, env, entries.items);
    var ib: [16]u8 = undefined;
    try out.print("added schedule '{s}': every {s} at level {s} on {s} {s}\nIt runs unattended: it cannot ask you anything, has no shell/web/notifications, and anything needing approval is denied.\nNothing runs until something calls 'aimgr schedule run-due' (try 'aimgr schedule run {s}' now, or 'aimgr schedule install' for a systemd user timer).\n", .{ e.id, schedule.formatInterval(&ib, e.every_s), e.level.text(), kind.name(), e.model, e.id });
    return 0;
}

// ---- running ---------------------------------------------------------------------------------

fn lockPath(arena: std.mem.Allocator, env: *const std.process.Environ.Map) ?[]const u8 {
    const dir = (schedDir(arena, env, null) catch return null) orelse return null;
    return std.fmt.allocPrint(arena, "{s}/run.lock", .{dir}) catch null;
}

/// One run-due at a time. A lock left by a dead process is taken over.
fn acquireLock(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, out: *std.Io.Writer) !bool {
    const path = lockPath(arena, env) orelse return true;
    if (std.fs.path.dirname(path)) |d| std.Io.Dir.cwd().createDirPath(io, d) catch {};
    var tries: u8 = 0;
    while (tries < 2) : (tries += 1) {
        if (std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true })) |f| {
            defer f.close(io);
            const pid = std.fmt.allocPrint(arena, "{d}\n", .{platform.selfPid()}) catch "0\n";
            f.writeStreamingAll(io, pid) catch {};
            return true;
        } else |_| {}
        const txt = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(32)) catch "";
        const pid = std.fmt.parseInt(u32, std.mem.trim(u8, txt, " \n"), 10) catch 0;
        if (pid > 0 and platform.aliveNumber(gpa, io, pid)) {
            try out.print("schedule: another run is active (pid {d}); skipping\n", .{pid});
            return false;
        }
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }
    return true;
}

fn releaseLock(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) void {
    const path = lockPath(arena, env) orelse return;
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

fn runOne(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, out: *std.Io.Writer, err: *std.Io.Writer, report: inventory.Inventory, e: schedule.Entry) !u8 {
    const t0 = now(io);
    var sb: [24]u8 = undefined;
    const dir = (try schedDir(arena, env, e.id)) orelse {
        try err.writeAll("aimgr: no state directory\n");
        return 1;
    };
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const path = try std.fmt.allocPrint(arena, "{s}/{s}.md", .{ dir, schedule.formatStamp(&sb, t0) });
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw: std.Io.File.Writer = .initStreaming(file, io, &buf);
    const w = &fw.interface;
    var ib: [40]u8 = undefined;
    try w.print("# Scheduled task: {s}\n\n- model: {s} {s}\n- started: {s}\n- level: {s} (unattended: nothing can be approved; no shell, web or notifications)\n- directories: ", .{ e.id, e.backend.name(), e.model, schedule.formatIso(&ib, t0), e.level.text() });
    for (e.dirs, 0..) |d, i| try w.print("{s}{s}", .{ if (i > 0) ", " else "", d });
    try w.print("\n\n## Task\n\n{s}\n\n## Transcript\n\n", .{e.task});

    const skip = struct {
        fn f(wr: *std.Io.Writer, o: *std.Io.Writer, p: []const u8, why: []const u8) !u8 {
            try wr.print("SKIPPED: {s}\n", .{why});
            try wr.flush();
            try o.print("schedule: skipped (not recorded as run): {s} -> {s}\n", .{ why, p });
            return 1;
        }
    }.f;

    // Preconditions (the same ones the interactive command enforces).
    for (report.reports) |r| if (r.kind == e.backend and r.probe != .available) return skip(w, out, path, "backend unavailable");
    var installed = false;
    for (report.reports) |r| if (r.kind == e.backend) for (r.models orelse &.{}) |m| if (std.mem.eql(u8, m.id, e.model)) {
        installed = true;
    };
    if (!installed) return skip(w, out, path, "model not installed");
    if (e.backend == .ollama) {
        const info = modelinfo.fetchOllama(arena, gpa, io, e.model) orelse return skip(w, out, path, "ollama could not describe the model");
        if (!info.hasCap("tools")) return skip(w, out, path, "the model does not support tools");
    }

    // Settings: the schedule's own limits, plus the safe knobs from the model's stored agent settings.
    var s: policy.Settings = .{ .level = e.level, .dirs = e.dirs, .max_steps = e.steps, .shell = .none, .web = false, .subagents = true, .plan = false, .search_url = null };
    const stored = try sources_io.loadAgents(arena, gpa, io, env);
    if (settings.find(stored, e.backend, e.model)) |i| {
        const st = stored[i];
        if (st.allow_commands) |v| s.allow_commands = v;
        if (st.deny_rules) |v| s.deny_rules = v;
        if (st.sandbox) |v| s.sandbox = v;
        if (st.max_output_kb) |v| s.max_output_kb = v;
        if (st.timeout_s) |v| s.timeout_s = v;
    }

    const code = agent_cmd.launch(arena, gpa, io, env, out, err, e.backend, e.model, s, .{ .once = .{ .task = e.task, .transcript = w } }) catch |er| blk: {
        try w.print("\nERROR: {s}\n", .{@errorName(er)});
        break :blk @as(u8, 1);
    };
    const t1 = now(io);
    try w.print("\n---\nfinished: {s} ({d} s), exit {d}\n", .{ schedule.formatIso(&ib, t1), t1 - t0, code });
    try w.flush();
    if (code == 0) writeLastRun(arena, io, env, e.id, t0);
    try out.print("schedule: {s} -> {s} (exit {d})\n", .{ e.id, path, code });
    return code;
}

// ---- systemd user units ----------------------------------------------------------------------

fn installUnits(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, out: *std.Io.Writer, err: *std.Io.Writer, install: bool, args: []const [:0]const u8) !u8 {
    var yes = false;
    for (args) |a| if (std.mem.eql(u8, a, "--yes")) {
        yes = true;
    } else return fail(err, usage);
    const home = env.get("HOME") orelse return fail(err, "HOME is not set");
    const dir = try std.fmt.allocPrint(arena, "{s}/.config/systemd/user", .{home});
    const svc = try std.fmt.allocPrint(arena, "{s}/aimgr-schedule.service", .{dir});
    const tim = try std.fmt.allocPrint(arena, "{s}/aimgr-schedule.timer", .{dir});
    if (!install) {
        try out.print("this removes:\n  {s}\n  {s}\nstop it first with: systemctl --user disable --now aimgr-schedule.timer\n", .{ svc, tim });
        if (!yes and !supervise.confirm(.{ .gpa = std.heap.page_allocator, .io = io, .environ = env, .out = out, .err = err, .log_dir = null }, "Remove these unit files?")) return 1;
        std.Io.Dir.cwd().deleteFile(io, svc) catch {};
        std.Io.Dir.cwd().deleteFile(io, tim) catch {};
        try out.writeAll("removed. Run: systemctl --user daemon-reload\n");
        return 0;
    }
    const exe = try std.process.executablePathAlloc(io, arena);
    try out.print("this writes two systemd USER units (no root, nothing is enabled by writing them):\n  {s}\n  {s}\n\n--- aimgr-schedule.service\n{s}\n--- aimgr-schedule.timer\n{s}\n", .{ svc, tim, try schedule.serviceUnit(arena, exe), schedule.timer_unit });
    try out.flush();
    if (!yes and !supervise.confirm(.{ .gpa = std.heap.page_allocator, .io = io, .environ = env, .out = out, .err = err, .log_dir = null }, "Write these unit files?")) return 1;
    try std.Io.Dir.cwd().createDirPath(io, dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = svc, .data = try schedule.serviceUnit(arena, exe) });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tim, .data = schedule.timer_unit });
    try out.writeAll("written. To start it (your decision):\n  systemctl --user daemon-reload\n  systemctl --user enable --now aimgr-schedule.timer\nTo stop it:\n  systemctl --user disable --now aimgr-schedule.timer\nIf you want it to run while you are logged out: loginctl enable-linger $USER\n");
    return 0;
}
