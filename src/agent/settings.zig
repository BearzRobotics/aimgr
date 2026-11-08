//! Per-model agent settings, stored as [[agent]] tables in config.toml:
//!
//!   [[agent]]
//!   backend = "ollama"
//!   id = "qwen3.8:27b"
//!   level = "ask"                  # off | read-only | inspect | ask
//!   dirs = ["/stuff/Books"]
//!   max_steps = 20
//!   timeout_s = 20
//!   max_output_kb = 64
//!   allow_commands = ["md5sum"]    # extra read-only commands (names only)
//!   sandbox = "auto"               # auto | bwrap | none
//!   allow_root = false
//!
//! Every field is optional; a missing field falls back to the default derived from what the model can do.
const std = @import("std");
const toml = @import("toml");
const backend = @import("../backend.zig");
const policy = @import("policy.zig");

pub const Entry = struct {
    backend: backend.Kind,
    id: []const u8,
    level: ?policy.Level = null,
    dirs: ?[]const []const u8 = null,
    max_steps: ?u32 = null,
    timeout_s: ?u32 = null,
    max_output_kb: ?u32 = null,
    allow_commands: ?[]const []const u8 = null,
    sandbox: ?policy.Sandbox = null,
    allow_root: ?bool = null,
};

pub const Error = error{ InvalidEntry, OutOfMemory };

/// Settings = defaults, then the stored entry on top.
pub fn apply(base: policy.Settings, e: ?Entry) policy.Settings {
    var s = base;
    const ent = e orelse return s;
    if (ent.level) |v| s.level = v;
    if (ent.dirs) |v| s.dirs = v;
    if (ent.max_steps) |v| s.max_steps = v;
    if (ent.timeout_s) |v| s.timeout_s = v;
    if (ent.max_output_kb) |v| s.max_output_kb = v;
    if (ent.allow_commands) |v| s.allow_commands = v;
    if (ent.sandbox) |v| s.sandbox = v;
    if (ent.allow_root) |v| s.allow_root = v;
    return s;
}

pub fn find(entries: []const Entry, kind: backend.Kind, id: []const u8) ?usize {
    for (entries, 0..) |e, i| if (e.backend == kind and std.mem.eql(u8, e.id, id)) return i;
    return null;
}

fn strList(arena: std.mem.Allocator, t: *const toml.Table, key: []const u8) Error!?[]const []const u8 {
    const v = t.get(key) orelse return null;
    if (v != .array) return error.InvalidEntry;
    var out: std.ArrayList([]const u8) = .empty;
    for (v.array.items.items) |item| {
        if (item != .string) return error.InvalidEntry;
        try out.append(arena, try arena.dupe(u8, item.string));
    }
    return try out.toOwnedSlice(arena);
}

fn intOpt(t: *const toml.Table, key: []const u8, lo: i64, hi: i64) Error!?u32 {
    const v = t.getInt(key) orelse {
        if (t.get(key) != null) return error.InvalidEntry;
        return null;
    };
    if (v < lo or v > hi) return error.InvalidEntry;
    return @intCast(v);
}

/// Parse the [[agent]] tables of config.toml text. Absent tables => empty list.
pub fn parse(arena: std.mem.Allocator, gpa: std.mem.Allocator, text: []const u8) Error![]Entry {
    var doc = toml.Document.parse(gpa, text, .{}, null) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidEntry,
    };
    defer doc.deinit();
    const v = doc.root.get("agent") orelse return &.{};
    if (v != .array) return error.InvalidEntry;
    var out: std.ArrayList(Entry) = .empty;
    for (v.array.items.items) |item| {
        if (item != .table) return error.InvalidEntry;
        const t = item.table;
        const be = std.meta.stringToEnum(backend.Kind, t.getString("backend") orelse return error.InvalidEntry) orelse return error.InvalidEntry;
        const id = t.getString("id") orelse return error.InvalidEntry;
        if (id.len == 0 or id[0] == '-') return error.InvalidEntry;
        var e: Entry = .{ .backend = be, .id = try arena.dupe(u8, id) };
        if (t.getString("level")) |l| e.level = policy.Level.parse(l) orelse return error.InvalidEntry;
        if (t.getString("sandbox")) |l| e.sandbox = policy.Sandbox.parse(l) orelse return error.InvalidEntry;
        e.dirs = try strList(arena, t, "dirs");
        if (e.dirs) |ds| for (ds) |d| if (d.len == 0 or d[0] != '/') return error.InvalidEntry;
        e.allow_commands = try strList(arena, t, "allow_commands");
        if (e.allow_commands) |cs| for (cs) |c| if (c.len == 0 or std.mem.indexOfScalar(u8, c, '/') != null or c[0] == '-') return error.InvalidEntry;
        e.max_steps = try intOpt(t, "max_steps", 1, 200);
        e.timeout_s = try intOpt(t, "timeout_s", 1, 600);
        e.max_output_kb = try intOpt(t, "max_output_kb", 1, 4096);
        e.allow_root = t.getBool("allow_root");
        try out.append(arena, e);
    }
    return try out.toOwnedSlice(arena);
}

fn quote(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        0...31, 127 => try w.print("\\u{X:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn writeList(w: *std.Io.Writer, key: []const u8, items: []const []const u8) std.Io.Writer.Error!void {
    try w.print("{s} = [", .{key});
    for (items, 0..) |it, i| {
        if (i > 0) try w.writeAll(", ");
        try quote(w, it);
    }
    try w.writeAll("]\n");
}

pub fn serialize(arena: std.mem.Allocator, entries: []const Entry) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    for (entries) |e| {
        try w.print("\n[[agent]]\nbackend = \"{s}\"\nid = ", .{e.backend.name()});
        try quote(w, e.id);
        try w.writeByte('\n');
        if (e.level) |v| try w.print("level = \"{s}\"\n", .{v.text()});
        if (e.dirs) |v| try writeList(w, "dirs", v);
        if (e.max_steps) |v| try w.print("max_steps = {d}\n", .{v});
        if (e.timeout_s) |v| try w.print("timeout_s = {d}\n", .{v});
        if (e.max_output_kb) |v| try w.print("max_output_kb = {d}\n", .{v});
        if (e.allow_commands) |v| try writeList(w, "allow_commands", v);
        if (e.sandbox) |v| try w.print("sandbox = \"{s}\"\n", .{@tagName(v)});
        if (e.allow_root) |v| try w.print("allow_root = {s}\n", .{if (v) "true" else "false"});
    }
    return aw.toOwnedSlice();
}

pub const SetError = error{ UnknownKey, BadValue, OutOfMemory };

/// Apply one `key=value` (as typed on the command line) to an entry.
pub fn setKey(arena: std.mem.Allocator, e: *Entry, kv: []const u8) SetError!void {
    const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return error.BadValue;
    const key = kv[0..eq];
    const val = kv[eq + 1 ..];
    if (std.mem.eql(u8, key, "level")) {
        e.level = policy.Level.parse(val) orelse return error.BadValue;
    } else if (std.mem.eql(u8, key, "dirs")) {
        var out: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, val, ',');
        while (it.next()) |d| {
            if (d[0] != '/') return error.BadValue;
            try out.append(arena, try arena.dupe(u8, d));
        }
        e.dirs = try out.toOwnedSlice(arena);
    } else if (std.mem.eql(u8, key, "steps")) {
        const n = std.fmt.parseInt(u32, val, 10) catch return error.BadValue;
        if (n < 1 or n > 200) return error.BadValue;
        e.max_steps = n;
    } else if (std.mem.eql(u8, key, "timeout")) {
        const n = std.fmt.parseInt(u32, val, 10) catch return error.BadValue;
        if (n < 1 or n > 600) return error.BadValue;
        e.timeout_s = n;
    } else if (std.mem.eql(u8, key, "output_kb")) {
        const n = std.fmt.parseInt(u32, val, 10) catch return error.BadValue;
        if (n < 1 or n > 4096) return error.BadValue;
        e.max_output_kb = n;
    } else if (std.mem.eql(u8, key, "allow")) {
        var out: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, val, ',');
        while (it.next()) |c| {
            if (std.mem.indexOfScalar(u8, c, '/') != null or c[0] == '-') return error.BadValue;
            try out.append(arena, try arena.dupe(u8, c));
        }
        e.allow_commands = try out.toOwnedSlice(arena);
    } else if (std.mem.eql(u8, key, "sandbox")) {
        e.sandbox = policy.Sandbox.parse(val) orelse return error.BadValue;
    } else if (std.mem.eql(u8, key, "root")) {
        if (std.mem.eql(u8, val, "true")) e.allow_root = true else if (std.mem.eql(u8, val, "false")) e.allow_root = false else return error.BadValue;
    } else return error.UnknownKey;
}

test "round trip and defaults layering" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    var e: Entry = .{ .backend = .ollama, .id = "qwen3.8:27b" };
    try setKey(a.allocator(), &e, "level=ask");
    try setKey(a.allocator(), &e, "dirs=/stuff/Books,/tmp/x");
    try setKey(a.allocator(), &e, "steps=12");
    try setKey(a.allocator(), &e, "allow=md5sum,wc");
    try setKey(a.allocator(), &e, "sandbox=none");
    try setKey(a.allocator(), &e, "root=false");
    const text = try serialize(a.allocator(), &.{e});
    const back = try parse(a.allocator(), std.testing.allocator, text);
    try std.testing.expectEqual(@as(usize, 1), back.len);
    try std.testing.expectEqual(policy.Level.ask, back[0].level.?);
    try std.testing.expectEqual(@as(usize, 2), back[0].dirs.?.len);
    try std.testing.expectEqual(@as(?u32, 12), back[0].max_steps);
    try std.testing.expectEqual(policy.Sandbox.none, back[0].sandbox.?);
    try std.testing.expectEqual(@as(?bool, false), back[0].allow_root);
    const s = apply(.{ .level = .read_only, .max_steps = 20, .timeout_s = 30 }, back[0]);
    try std.testing.expectEqual(policy.Level.ask, s.level); // stored value wins
    try std.testing.expectEqual(@as(u32, 30), s.timeout_s); // untouched default stays
    try std.testing.expectEqual(@as(u32, 12), s.max_steps);
}

test "invalid entries are rejected" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const g = std.testing.allocator;
    try std.testing.expectError(error.InvalidEntry, parse(a.allocator(), g, "[[agent]]\nbackend=\"ollama\"\nid=\"m\"\nlevel=\"yolo\"\n"));
    try std.testing.expectError(error.InvalidEntry, parse(a.allocator(), g, "[[agent]]\nbackend=\"ollama\"\nid=\"m\"\ndirs=[\"relative\"]\n"));
    try std.testing.expectError(error.InvalidEntry, parse(a.allocator(), g, "[[agent]]\nbackend=\"ollama\"\nid=\"m\"\nmax_steps=0\n"));
    try std.testing.expectError(error.InvalidEntry, parse(a.allocator(), g, "[[agent]]\nbackend=\"ollama\"\nid=\"m\"\nallow_commands=[\"/bin/sh\"]\n"));
    try std.testing.expectError(error.InvalidEntry, parse(a.allocator(), g, "[[agent]]\nid=\"m\"\n"));
    try std.testing.expectEqual(@as(usize, 0), (try parse(a.allocator(), g, "# nothing\n")).len);
    var e: Entry = .{ .backend = .ollama, .id = "m" };
    try std.testing.expectError(error.BadValue, setKey(a.allocator(), &e, "level=root"));
    try std.testing.expectError(error.BadValue, setKey(a.allocator(), &e, "dirs=relative/path"));
    try std.testing.expectError(error.UnknownKey, setKey(a.allocator(), &e, "sudo=yes"));
    try std.testing.expectError(error.BadValue, setKey(a.allocator(), &e, "allow=/bin/rm"));
}
