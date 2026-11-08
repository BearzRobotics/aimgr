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
//!   shell = "bash"                 # none | bash | sh | dksh | powershell | pwsh | cmd (only used at level ask)
//!   web = false                    # web_fetch / web_search tools (each request asks)
//!   subagents = true
//!   plan = false                   # start sessions in plan mode
//!   search_url = "https://search.example/?q={q}&format=json"
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
    shell: ?policy.Shell = null,
    web: ?bool = null,
    subagents: ?bool = null,
    plan: ?bool = null,
    search_url: ?[]const u8 = null,
    allow_rules: ?[]const []const u8 = null,
    deny_rules: ?[]const []const u8 = null,
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
    if (ent.shell) |v| s.shell = v;
    if (ent.web) |v| s.web = v;
    if (ent.subagents) |v| s.subagents = v;
    if (ent.plan) |v| s.plan = v;
    if (ent.search_url) |v| s.search_url = v;
    if (ent.allow_rules) |v| s.allow_rules = v;
    if (ent.deny_rules) |v| s.deny_rules = v;
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
        if (t.getString("shell")) |sh| e.shell = policy.Shell.parse(sh) orelse return error.InvalidEntry;
        e.allow_rules = try strList(arena, t, "allow_rules");
        e.deny_rules = try strList(arena, t, "deny_rules");
        inline for (.{ e.allow_rules, e.deny_rules }) |maybe| if (maybe) |rs| for (rs) |r| if (policy.parseRule(r) == null) return error.InvalidEntry;
        e.web = t.getBool("web");
        e.subagents = t.getBool("subagents");
        e.plan = t.getBool("plan");
        if (t.getString("search_url")) |su| {
            if (!validSearchUrl(su)) return error.InvalidEntry;
            e.search_url = try arena.dupe(u8, su);
        }
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
        if (e.allow_rules) |v| try writeList(w, "allow_rules", v);
        if (e.deny_rules) |v| try writeList(w, "deny_rules", v);
        if (e.shell) |v| try w.print("shell = \"{s}\"\n", .{v.text()});
        if (e.web) |v| try w.print("web = {s}\n", .{if (v) "true" else "false"});
        if (e.subagents) |v| try w.print("subagents = {s}\n", .{if (v) "true" else "false"});
        if (e.plan) |v| try w.print("plan = {s}\n", .{if (v) "true" else "false"});
        if (e.search_url) |v| {
            try w.writeAll("search_url = ");
            try quote(w, v);
            try w.writeByte('\n');
        }
    }
    return aw.toOwnedSlice();
}

/// https only, must contain the {q} placeholder, no whitespace or control characters.
pub fn validSearchUrl(u: []const u8) bool {
    if (!std.mem.startsWith(u8, u, "https://") or u.len > 500) return false;
    if (std.mem.indexOf(u8, u, "{q}") == null) return false;
    for (u) |c| if (c <= 0x20 or c == 0x7f) return false;
    return true;
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
    } else if (std.mem.eql(u8, key, "shell")) {
        e.shell = policy.Shell.parse(val) orelse return error.BadValue;
    } else if (std.mem.eql(u8, key, "web") or std.mem.eql(u8, key, "subagents") or std.mem.eql(u8, key, "plan")) {
        const b = if (std.mem.eql(u8, val, "true")) true else if (std.mem.eql(u8, val, "false")) false else return error.BadValue;
        if (std.mem.eql(u8, key, "web")) e.web = b else if (std.mem.eql(u8, key, "subagents")) e.subagents = b else e.plan = b;
    } else if (std.mem.eql(u8, key, "search_url")) {
        if (!validSearchUrl(val)) return error.BadValue;
        e.search_url = try arena.dupe(u8, val);
    } else if (std.mem.eql(u8, key, "allow_rule") or std.mem.eql(u8, key, "deny_rule")) {
        if (policy.parseRule(val) == null) return error.BadValue;
        const slot = if (std.mem.eql(u8, key, "allow_rule")) &e.allow_rules else &e.deny_rules;
        var list: std.ArrayList([]const u8) = .empty;
        if (slot.*) |old| try list.appendSlice(arena, old);
        try list.append(arena, try arena.dupe(u8, val));
        slot.* = try list.toOwnedSlice(arena);
    } else if (std.mem.eql(u8, key, "rules") and std.mem.eql(u8, val, "clear")) {
        e.allow_rules = null;
        e.deny_rules = null;
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

test "new settings: shell, web, subagents, plan, search_url" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    var e: Entry = .{ .backend = .llama, .id = "o/m:Q4" };
    try setKey(a.allocator(), &e, "shell=dksh");
    try setKey(a.allocator(), &e, "web=true");
    try setKey(a.allocator(), &e, "subagents=false");
    try setKey(a.allocator(), &e, "plan=true");
    try setKey(a.allocator(), &e, "search_url=https://s.example/search?q={q}&format=json");
    const text = try serialize(a.allocator(), &.{e});
    const back = try parse(a.allocator(), std.testing.allocator, text);
    const s = apply(.{ .level = .ask }, back[0]);
    try std.testing.expectEqual(policy.Shell.dksh, s.shell.?);
    try std.testing.expect(s.web and !s.subagents and s.plan);
    try std.testing.expect(std.mem.indexOf(u8, s.search_url.?, "{q}") != null);
    try std.testing.expectError(error.BadValue, setKey(a.allocator(), &e, "shell=zsh"));
    try std.testing.expectError(error.BadValue, setKey(a.allocator(), &e, "web=maybe"));
    try std.testing.expectError(error.BadValue, setKey(a.allocator(), &e, "search_url=http://insecure/?q={q}"));
    try std.testing.expectError(error.BadValue, setKey(a.allocator(), &e, "search_url=https://no-placeholder.example/"));
}

test "rules in settings: add, validate, round trip, clear" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    var e: Entry = .{ .backend = .ollama, .id = "m" };
    try setKey(a.allocator(), &e, "allow_rule=run_command(git status*)");
    try setKey(a.allocator(), &e, "allow_rule=edit_file(/w/*)");
    try setKey(a.allocator(), &e, "deny_rule=*(*.pem)");
    try std.testing.expectError(error.BadValue, setKey(a.allocator(), &e, "allow_rule=nonsense"));
    const text = try serialize(a.allocator(), &.{e});
    const back = try parse(a.allocator(), std.testing.allocator, text);
    const s = apply(.{ .level = .ask }, back[0]);
    try std.testing.expectEqual(@as(usize, 2), s.allow_rules.len);
    try std.testing.expectEqual(@as(usize, 1), s.deny_rules.len);
    try std.testing.expectError(error.InvalidEntry, parse(a.allocator(), std.testing.allocator, "[[agent]]\nbackend=\"ollama\"\nid=\"m\"\nallow_rules=[\"bad rule\"]\n"));
    try setKey(a.allocator(), &e, "rules=clear");
    try std.testing.expect(e.allow_rules == null and e.deny_rules == null);
}
