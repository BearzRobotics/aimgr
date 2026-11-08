//! Remembers what aimgr has verified about a model's tool support, so the Settings tab can show it
//! without starting a server. File: $XDG_STATE_HOME/aimgr/agent-capabilities.json, e.g.
//!   {"llama:ggml-org/gpt-oss-20b-GGUF:MXFP4": true, "llama:some/model:Q4_K_M": false}
//! Only written after a real check (llama /props); a missing entry means "not verified".
const std = @import("std");
const backend = @import("../backend.zig");
const config = @import("../config.zig");

pub const Map = std.StringHashMapUnmanaged(bool);

fn keyFor(arena: std.mem.Allocator, kind: backend.Kind, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}:{s}", .{ kind.name(), id });
}

pub fn parse(arena: std.mem.Allocator, text: []const u8) Map {
    var map: Map = .empty;
    const parsed = std.json.parseFromSlice(std.json.Value, arena, text, .{}) catch return map;
    if (parsed.value != .object) return map;
    var it = parsed.value.object.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* != .bool) continue;
        const key = arena.dupe(u8, kv.key_ptr.*) catch continue;
        map.put(arena, key, kv.value_ptr.bool) catch continue;
    }
    return map;
}

pub fn serialize(arena: std.mem.Allocator, map: *const Map) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    // stable order for readable diffs
    var keys: std.ArrayList([]const u8) = .empty;
    var it = map.iterator();
    while (it.next()) |kv| try keys.append(arena, kv.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    for (keys.items) |k| {
        try s.objectField(k);
        try s.write(map.get(k).?);
    }
    try s.endObject();
    return aw.toOwnedSlice();
}

pub fn load(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) Map {
    const path = (config.statePath(arena, env, "agent-capabilities.json") catch return .empty) orelse return .empty;
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return .empty;
    defer gpa.free(text);
    return parse(arena, text);
}

pub fn get(map: *const Map, arena: std.mem.Allocator, kind: backend.Kind, id: []const u8) ?bool {
    const key = keyFor(arena, kind, id) catch return null;
    return map.get(key);
}

pub fn record(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, kind: backend.Kind, id: []const u8, supports: bool) void {
    const path = (config.statePath(arena, env, "agent-capabilities.json") catch return) orelse return;
    var map = load(arena, gpa, io, env);
    map.put(arena, keyFor(arena, kind, id) catch return, supports) catch return;
    const text = serialize(arena, &map) catch return;
    if (std.fs.path.dirname(path)) |d| std.Io.Dir.cwd().createDirPath(io, d) catch return;
    const tmp = std.fmt.allocPrint(arena, "{s}.tmp", .{path}) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = text }) catch return;
    std.Io.Dir.rename(std.Io.Dir.cwd(), tmp, std.Io.Dir.cwd(), path, io) catch {};
}

test "round trip and lookups" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    var m: Map = .empty;
    try m.put(a.allocator(), "llama:a/b:Q4", true);
    try m.put(a.allocator(), "llama:c/d:Q8", false);
    const text = try serialize(a.allocator(), &m);
    const back = parse(a.allocator(), text);
    try std.testing.expectEqual(@as(?bool, true), get(&back, a.allocator(), .llama, "a/b:Q4"));
    try std.testing.expectEqual(@as(?bool, false), get(&back, a.allocator(), .llama, "c/d:Q8"));
    try std.testing.expectEqual(@as(?bool, null), get(&back, a.allocator(), .llama, "never:seen"));
    try std.testing.expectEqual(@as(usize, 0), parse(a.allocator(), "not json").count());
    try std.testing.expectEqual(@as(usize, 0), parse(a.allocator(), "{\"x\": 3}").count()); // non-bool values ignored
}
