//! The interactive part of the Settings tab: the list of model sources (enable / disable /
//! refresh) and the per-model agent levels. Pure data; drawing is in draw.zig, keys in app.zig.
const std = @import("std");
const backend = @import("../backend.zig");
const sources = @import("../sources.zig");
const policy = @import("../agent/policy.zig");
const agent_settings = @import("../agent/settings.zig");
const modelinfo = @import("../modelinfo.zig");

pub const AgentItem = struct {
    id: []const u8,
    level: policy.Level,
    /// Level used when nothing is stored (from capability and size).
    default_level: policy.Level,
    params_b: ?f64,
    stored_dirs: ?[]const []const u8,
    custom: bool,
};

pub const Item = union(enum) {
    source: usize,
    agent: AgentItem,
};

pub fn nextLevel(l: policy.Level) policy.Level {
    return switch (l) {
        .off => .read_only,
        .read_only => .inspect,
        .inspect => .ask,
        .ask => .off,
    };
}

/// One entry per configured source, then one per installed, tool-capable Ollama model.
pub fn items(
    arena: std.mem.Allocator,
    srcs: []const sources.Source,
    report_models: []const backend.Model,
    infos: *const std.StringHashMapUnmanaged(modelinfo.Info),
    stored: []const agent_settings.Entry,
) ![]Item {
    var out: std.ArrayList(Item) = .empty;
    for (srcs, 0..) |_, i| try out.append(arena, .{ .source = i });
    for (report_models) |m| {
        if (m.backend != .ollama) continue;
        const info = infos.get(m.id) orelse continue;
        if (!info.hasCap("tools")) continue;
        const def = policy.defaultLevel(true, info.paramsB());
        const idx = agent_settings.find(stored, .ollama, m.id);
        const entry: ?agent_settings.Entry = if (idx) |k| stored[k] else null;
        const lvl = if (entry) |e| (e.level orelse def) else def;
        try out.append(arena, .{ .agent = .{
            .id = m.id,
            .level = lvl,
            .default_level = def,
            .params_b = info.paramsB(),
            .stored_dirs = if (entry) |e| e.dirs else null,
            .custom = if (entry) |e| e.level != null else false,
        } });
    }
    return out.toOwnedSlice(arena);
}

test "items: sources first, then tool-capable ollama models with their effective level" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const srcs = try sources.defaults(a.allocator());
    const models = [_]backend.Model{
        .{ .backend = .ollama, .id = "big:30b" },
        .{ .backend = .ollama, .id = "small:1b" },
        .{ .backend = .ollama, .id = "notools:7b" },
        .{ .backend = .llama, .id = "x/y:Q4" },
    };
    var infos: std.StringHashMapUnmanaged(modelinfo.Info) = .empty;
    try infos.put(a.allocator(), "big:30b", .{ .parameters = "30B", .caps = &.{ "completion", "tools" } });
    try infos.put(a.allocator(), "small:1b", .{ .parameters = "1B", .caps = &.{"tools"} });
    try infos.put(a.allocator(), "notools:7b", .{ .parameters = "7B", .caps = &.{"completion"} });
    const stored = [_]agent_settings.Entry{.{ .backend = .ollama, .id = "small:1b", .level = .ask }};
    const it = try items(a.allocator(), srcs, &models, &infos, &stored);
    try std.testing.expectEqual(@as(usize, 3 + 2), it.len);
    try std.testing.expect(it[0] == .source);
    try std.testing.expectEqualStrings("big:30b", it[3].agent.id);
    try std.testing.expectEqual(policy.Level.ask, it[3].agent.level); // default for 30B
    try std.testing.expect(!it[3].agent.custom);
    try std.testing.expectEqual(policy.Level.ask, it[4].agent.level); // stored override on a 1B model
    try std.testing.expectEqual(policy.Level.read_only, it[4].agent.default_level);
    try std.testing.expect(it[4].agent.custom);
}

test "level cycle visits every level" {
    var l = policy.Level.off;
    var seen: [4]bool = .{ false, false, false, false };
    for (0..4) |_| {
        seen[@backingInt(l)] = true;
        l = nextLevel(l);
    }
    try std.testing.expect(seen[0] and seen[1] and seen[2] and seen[3]);
    try std.testing.expectEqual(policy.Level.off, l);
}
