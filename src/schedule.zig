//! Scheduled agent tasks. A schedule is a saved request ("every 6h, summarize what changed in these
//! folders") that `aimgr schedule run-due` executes UNATTENDED, normally driven by a systemd user timer or cron
//! that the user installs. Unattended means no one can approve anything, so a scheduled run is capped at
//! level `read-only` or `inspect`, has no shell, web, notifications or user questions, and anything that
//! would have asked is denied and recorded. Output goes to $XDG_STATE_HOME/aimgr/schedule/<id>/<time>.md.
const std = @import("std");
const toml = @import("toml");
const backend = @import("backend.zig");
const policy = @import("agent/policy.zig");

pub const Entry = struct {
    id: []const u8,
    backend: backend.Kind,
    model: []const u8,
    every_s: u32,
    task: []const u8,
    dirs: []const []const u8,
    level: policy.Level = .read_only,
    steps: u32 = 10,
    enabled: bool = true,
};

pub const Error = error{ InvalidId, InvalidInterval, InvalidTask, InvalidDirs, InvalidLevel, InvalidEntry, DuplicateId, OutOfMemory };

pub fn errorText(e: Error) []const u8 {
    return switch (e) {
        error.InvalidId => "schedule id must be 1-40 chars of a-z 0-9 - _ and start with a letter or digit",
        error.InvalidInterval => "interval must look like 30m, 6h, 1d (at least 5m, at most 30d) or hourly / daily / weekly",
        error.InvalidTask => "task must be 1-4000 characters",
        error.InvalidDirs => "give at least one absolute directory",
        error.InvalidLevel => "unattended runs can only use level read-only or inspect",
        error.InvalidEntry => "a [[schedule]] entry in config.toml is invalid",
        error.DuplicateId => "a schedule with that id already exists",
        error.OutOfMemory => "out of memory",
    };
}

pub const min_interval_s: u32 = 5 * 60;
pub const max_interval_s: u32 = 30 * 24 * 3600;

pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 40) return false;
    if (!(std.ascii.isLower(id[0]) or std.ascii.isDigit(id[0]))) return false;
    for (id) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-' or c == '_')) return false;
    return true;
}

/// "30m", "6h", "2d", "hourly", "daily", "weekly" -> seconds.
pub fn parseInterval(text: []const u8) ?u32 {
    const named = [_]struct { []const u8, u32 }{ .{ "hourly", 3600 }, .{ "daily", 86400 }, .{ "weekly", 7 * 86400 } };
    for (named) |n| if (std.mem.eql(u8, text, n[0])) return n[1];
    if (text.len < 2) return null;
    const unit = text[text.len - 1];
    const n = std.fmt.parseInt(u32, text[0 .. text.len - 1], 10) catch return null;
    const mult: u64 = switch (unit) {
        'm' => 60,
        'h' => 3600,
        'd' => 86400,
        else => return null,
    };
    const total = @as(u64, n) * mult;
    if (total < min_interval_s or total > max_interval_s) return null;
    return @intCast(total);
}

pub fn formatInterval(buf: []u8, secs: u32) []const u8 {
    if (secs % 86400 == 0) return std.fmt.bufPrint(buf, "{d}d", .{secs / 86400}) catch "?";
    if (secs % 3600 == 0) return std.fmt.bufPrint(buf, "{d}h", .{secs / 3600}) catch "?";
    return std.fmt.bufPrint(buf, "{d}m", .{secs / 60}) catch "?";
}

pub fn validate(e: Entry) Error!void {
    if (!validId(e.id)) return error.InvalidId;
    if (e.every_s < min_interval_s or e.every_s > max_interval_s) return error.InvalidInterval;
    if (e.task.len == 0 or e.task.len > 4000) return error.InvalidTask;
    for (e.task) |c| if (c == 0) return error.InvalidTask;
    if (e.dirs.len == 0) return error.InvalidDirs;
    for (e.dirs) |d| if (d.len == 0 or d[0] != '/' or std.mem.eql(u8, d, "/")) return error.InvalidDirs;
    if (e.level != .read_only and e.level != .inspect) return error.InvalidLevel;
    if (e.steps < 1 or e.steps > 50) return error.InvalidEntry;
    if (e.model.len == 0 or e.model[0] == '-') return error.InvalidEntry;
}

/// Due when it never ran, or the interval has elapsed (a clock that went backwards counts as due too).
pub fn isDue(e: Entry, last_run: ?i64, now: i64) bool {
    if (!e.enabled) return false;
    const last = last_run orelse return true;
    if (now < last) return true;
    return now - last >= @as(i64, e.every_s);
}

pub fn nextDue(e: Entry, last_run: ?i64) ?i64 {
    const last = last_run orelse return null;
    return last + @as(i64, e.every_s);
}

/// "20261108-143005" (UTC) for file names.
pub fn formatStamp(buf: []u8, epoch: i64) []const u8 {
    const c = civil(epoch);
    return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{ c.year, c.month, c.day, c.hour, c.minute, c.second }) catch "?";
}

pub fn formatIso(buf: []u8, epoch: i64) []const u8 {
    const c = civil(epoch);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{ c.year, c.month, c.day, c.hour, c.minute, c.second }) catch "?";
}

const Civil = struct { year: u32, month: u8, day: u8, hour: u8, minute: u8, second: u8 };

fn civil(epoch: i64) Civil {
    const days = @divFloor(epoch, 86400);
    const rem: i64 = @mod(epoch, 86400);
    // Howard Hinnant's days-from-civil inverse
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y = yoe + era * 400 + (if (m <= 2) @as(i64, 1) else 0);
    return .{ .year = @intCast(@max(y, 0)), .month = @intCast(m), .day = @intCast(d), .hour = @intCast(@divFloor(rem, 3600)), .minute = @intCast(@divFloor(@mod(rem, 3600), 60)), .second = @intCast(@mod(rem, 60)) };
}

// ---- config.toml: [[schedule]] tables ---------------------------------------------------------

fn quote(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        0...8, 11...31, 127 => try w.print("\\u{X:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

pub fn serialize(arena: std.mem.Allocator, entries: []const Entry) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    for (entries) |e| {
        var ib: [16]u8 = undefined;
        try w.writeAll("\n[[schedule]]\nid = ");
        try quote(w, e.id);
        try w.print("\nbackend = \"{s}\"\nmodel = ", .{e.backend.name()});
        try quote(w, e.model);
        try w.print("\nevery = \"{s}\"\nlevel = \"{s}\"\nsteps = {d}\nenabled = {s}\ntask = ", .{ formatInterval(&ib, e.every_s), e.level.text(), e.steps, if (e.enabled) "true" else "false" });
        try quote(w, e.task);
        try w.writeAll("\ndirs = [");
        for (e.dirs, 0..) |d, i| {
            if (i > 0) try w.writeAll(", ");
            try quote(w, d);
        }
        try w.writeAll("]\n");
    }
    return aw.toOwnedSlice();
}

pub fn parse(arena: std.mem.Allocator, gpa: std.mem.Allocator, text: []const u8) Error![]Entry {
    var doc = toml.Document.parse(gpa, text, .{}, null) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidEntry,
    };
    defer doc.deinit();
    const root = doc.root.get("schedule") orelse return &.{};
    if (root != .array) return error.InvalidEntry;
    var out: std.ArrayList(Entry) = .empty;
    for (root.array.items.items) |item| {
        if (item != .table) return error.InvalidEntry;
        const t = item.table;
        const dirs_v = t.get("dirs") orelse return error.InvalidDirs;
        if (dirs_v != .array) return error.InvalidDirs;
        var dirs: std.ArrayList([]const u8) = .empty;
        for (dirs_v.array.items.items) |d| {
            if (d != .string) return error.InvalidDirs;
            try dirs.append(arena, try arena.dupe(u8, d.string));
        }
        const e: Entry = .{
            .id = try arena.dupe(u8, t.getString("id") orelse return error.InvalidId),
            .backend = std.meta.stringToEnum(backend.Kind, t.getString("backend") orelse return error.InvalidEntry) orelse return error.InvalidEntry,
            .model = try arena.dupe(u8, t.getString("model") orelse return error.InvalidEntry),
            .every_s = parseInterval(t.getString("every") orelse return error.InvalidInterval) orelse return error.InvalidInterval,
            .task = try arena.dupe(u8, t.getString("task") orelse return error.InvalidTask),
            .dirs = try dirs.toOwnedSlice(arena),
            .level = policy.Level.parse(t.getString("level") orelse "read-only") orelse return error.InvalidLevel,
            .steps = if (t.getInt("steps")) |n| (if (n >= 1 and n <= 50) @intCast(n) else return error.InvalidEntry) else 10,
            .enabled = t.getBool("enabled") orelse true,
        };
        try validate(e);
        for (out.items) |o| if (std.mem.eql(u8, o.id, e.id)) return error.DuplicateId;
        try out.append(arena, e);
    }
    return out.toOwnedSlice(arena);
}

pub fn find(entries: []const Entry, id: []const u8) ?usize {
    for (entries, 0..) |e, i| if (std.mem.eql(u8, e.id, id)) return i;
    return null;
}

// ---- systemd user units (written only with the user's confirmation) ----------------------------

pub fn serviceUnit(arena: std.mem.Allocator, exe: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena,
        \\[Unit]
        \\Description=Run due aimgr scheduled tasks (unattended, read-only/inspect only)
        \\
        \\[Service]
        \\Type=oneshot
        \\ExecStart={s} schedule run-due
        \\Nice=10
        \\NoNewPrivileges=true
        \\
    , .{exe});
}

pub const timer_unit =
    \\[Unit]
    \\Description=Check aimgr scheduled tasks every 15 minutes
    \\
    \\[Timer]
    \\OnBootSec=5min
    \\OnUnitActiveSec=15min
    \\Persistent=true
    \\
    \\[Install]
    \\WantedBy=timers.target
    \\
;

test "intervals" {
    try std.testing.expectEqual(@as(?u32, 1800), parseInterval("30m"));
    try std.testing.expectEqual(@as(?u32, 6 * 3600), parseInterval("6h"));
    try std.testing.expectEqual(@as(?u32, 86400), parseInterval("1d"));
    try std.testing.expectEqual(@as(?u32, 3600), parseInterval("hourly"));
    try std.testing.expectEqual(@as(?u32, 7 * 86400), parseInterval("weekly"));
    for ([_][]const u8{ "", "m", "4m", "31d", "0h", "1x", "-5m", "1.5h", "30 m", "hourlyx" }) |bad| try std.testing.expectEqual(@as(?u32, null), parseInterval(bad));
    var b: [16]u8 = undefined;
    try std.testing.expectEqualStrings("6h", formatInterval(&b, 6 * 3600));
    try std.testing.expectEqualStrings("2d", formatInterval(&b, 2 * 86400));
    try std.testing.expectEqualStrings("45m", formatInterval(&b, 45 * 60));
}

test "due logic" {
    var e: Entry = .{ .id = "x", .backend = .ollama, .model = "m", .every_s = 3600, .task = "t", .dirs = &.{"/d"} };
    try std.testing.expect(isDue(e, null, 1000)); // never ran
    try std.testing.expect(!isDue(e, 1000, 1000 + 3599));
    try std.testing.expect(isDue(e, 1000, 1000 + 3600));
    try std.testing.expect(isDue(e, 5000, 100)); // clock went backwards: run rather than wait forever
    e.enabled = false;
    try std.testing.expect(!isDue(e, null, 1000));
    try std.testing.expectEqual(@as(?i64, 4600), nextDue(e, 1000));
    try std.testing.expectEqual(@as(?i64, null), nextDue(e, null));
}

test "UTC stamps" {
    var b: [40]u8 = undefined;
    try std.testing.expectEqualStrings("19700101-000000", formatStamp(&b, 0));
    try std.testing.expectEqualStrings("20240229-235959", formatStamp(&b, 1709251199)); // leap day
    try std.testing.expectEqualStrings("20000101-000000", formatStamp(&b, 946684800));
    try std.testing.expectEqualStrings("2026-11-08 12:00:00 UTC", formatIso(&b, 1794139200));
}

test "validation" {
    const base: Entry = .{ .id = "daily-notes", .backend = .llama, .model = "o/m:Q4", .every_s = 86400, .task = "summarize", .dirs = &.{"/stuff/Books"} };
    try validate(base);
    var e = base;
    e.id = "Bad Id";
    try std.testing.expectError(error.InvalidId, validate(e));
    e = base;
    e.level = .ask;
    try std.testing.expectError(error.InvalidLevel, validate(e)); // unattended runs can never be 'ask'
    e = base;
    e.level = .off;
    try std.testing.expectError(error.InvalidLevel, validate(e));
    e = base;
    e.dirs = &.{"/"};
    try std.testing.expectError(error.InvalidDirs, validate(e));
    e.dirs = &.{"relative"};
    try std.testing.expectError(error.InvalidDirs, validate(e));
    e = base;
    e.every_s = 60;
    try std.testing.expectError(error.InvalidInterval, validate(e));
    e = base;
    e.task = "";
    try std.testing.expectError(error.InvalidTask, validate(e));
}

test "round trip including awkward task text" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const entries = [_]Entry{
        .{ .id = "one", .backend = .ollama, .model = "gemma4:12b", .every_s = 6 * 3600, .task = "Summarize \"changes\"\nline two\tand a backslash \\", .dirs = &.{ "/a", "/b c" }, .level = .inspect, .steps = 7 },
        .{ .id = "two", .backend = .llama, .model = "o/m:Q4_K_M", .every_s = 2 * 86400, .task = "x", .dirs = &.{"/d"}, .enabled = false },
    };
    const text = try serialize(a.allocator(), &entries);
    const back = try parse(a.allocator(), std.testing.allocator, text);
    try std.testing.expectEqual(@as(usize, 2), back.len);
    try std.testing.expectEqualStrings(entries[0].task, back[0].task);
    try std.testing.expectEqual(@as(usize, 2), back[0].dirs.len);
    try std.testing.expectEqual(policy.Level.inspect, back[0].level);
    try std.testing.expectEqual(@as(u32, 7), back[0].steps);
    try std.testing.expect(!back[1].enabled);
    try std.testing.expectEqual(@as(u32, 2 * 86400), back[1].every_s);
    try std.testing.expectError(error.InvalidLevel, parse(a.allocator(), std.testing.allocator, "[[schedule]]\nid=\"x\"\nbackend=\"ollama\"\nmodel=\"m\"\nevery=\"1h\"\ntask=\"t\"\ndirs=[\"/d\"]\nlevel=\"ask\"\n"));
    try std.testing.expectEqual(@as(usize, 0), (try parse(a.allocator(), std.testing.allocator, "# nothing\n")).len);
}

test "systemd units mention the unattended limits and run-due" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const svc = try serviceUnit(a.allocator(), "/home/u/.local/bin/aimgr");
    try std.testing.expect(std.mem.indexOf(u8, svc, "ExecStart=/home/u/.local/bin/aimgr schedule run-due") != null);
    try std.testing.expect(std.mem.indexOf(u8, timer_unit, "OnUnitActiveSec=15min") != null);
}
