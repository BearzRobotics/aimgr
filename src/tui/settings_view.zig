//! The interactive part of the Settings tab: the list of model sources (enable / disable /
//! refresh) and the per-model agent levels. Pure data; drawing is in draw.zig, keys in app.zig.
const std = @import("std");
const backend = @import("../backend.zig");
const sources = @import("../sources.zig");
const policy = @import("../agent/policy.zig");
const agent_settings = @import("../agent/settings.zig");
const modelinfo = @import("../modelinfo.zig");
const catalog = @import("../catalog.zig");
const capcache = @import("../agent/capcache.zig");
const hardware = @import("../hardware.zig");

/// How we know (or do not know) that a model can call tools.
pub const ToolsKnowledge = enum { reported, verified_yes, verified_no, catalog_hint, unknown };

pub const AgentItem = struct {
    backend: backend.Kind,
    tools: ToolsKnowledge,
    id: []const u8,
    level: policy.Level,
    /// Level used when nothing is stored (from capability and size).
    default_level: policy.Level,
    params_b: ?f64,
    stored_dirs: ?[]const []const u8,
    custom: bool,
    /// Stored values (null = default) of the other per-model knobs shown and changed in the TUI.
    sandbox: ?policy.Sandbox = null,
    shell: ?policy.Shell = null,
    web: ?bool = null,
};

pub fn nextSandbox(v: ?policy.Sandbox) policy.Sandbox {
    return switch (v orelse .auto) {
        .auto => .bwrap,
        .bwrap => .none,
        .none => .auto,
    };
}

/// Shells offered on this OS, in cycle order (none = no run_shell tool).
pub fn nextShell(v: ?policy.Shell) policy.Shell {
    const order: []const policy.Shell = if (policy.is_windows) &.{ .powershell, .pwsh, .cmd, .none } else &.{ .bash, .sh, .dksh, .none };
    const cur = v orelse order[0];
    for (order, 0..) |o, i| if (o == cur) return order[(i + 1) % order.len];
    return order[0];
}

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

/// One entry per configured source, then one per installed model that can use (or might be able to use)
/// tools: Ollama models whose `ollama show` lists tools, and llama models (whose capability is verified
/// by starting their server: cached result, else the catalog hint, else unknown).
pub fn items(
    arena: std.mem.Allocator,
    srcs: []const sources.Source,
    report_models: []const backend.Model,
    infos: *const std.StringHashMapUnmanaged(modelinfo.Info),
    stored: []const agent_settings.Entry,
    cat: *const catalog.Catalog,
    caps: *const capcache.Map,
) ![]Item {
    var out: std.ArrayList(Item) = .empty;
    for (srcs, 0..) |_, i| try out.append(arena, .{ .source = i });
    for (report_models) |m| {
        var tools: ToolsKnowledge = undefined;
        var params: ?f64 = null;
        switch (m.backend) {
            .ollama => {
                const info = infos.get(m.id) orelse continue;
                if (!info.hasCap("tools")) continue;
                tools = .reported;
                params = info.paramsB();
            },
            .llama => {
                const ent = cat.find(.llama, m.id);
                params = (if (ent) |e| e.params_b else null) orelse hardware.parseParamsB(m.id);
                if (capcache.get(caps, arena, .llama, m.id)) |v| {
                    tools = if (v) .verified_yes else .verified_no;
                } else if (ent != null and hasUse(ent.?, "tools")) {
                    tools = .catalog_hint;
                } else tools = .unknown;
            },
        }
        const def = policy.defaultLevel(tools != .verified_no, params);
        const idx = agent_settings.find(stored, m.backend, m.id);
        const entry: ?agent_settings.Entry = if (idx) |k| stored[k] else null;
        const lvl = if (entry) |e| (e.level orelse def) else def;
        try out.append(arena, .{ .agent = .{
            .backend = m.backend,
            .tools = tools,
            .id = m.id,
            .level = lvl,
            .default_level = def,
            .params_b = params,
            .stored_dirs = if (entry) |e| e.dirs else null,
            .custom = if (entry) |e| e.level != null else false,
            .sandbox = if (entry) |e| e.sandbox else null,
            .shell = if (entry) |e| e.shell else null,
            .web = if (entry) |e| e.web else null,
        } });
    }
    return out.toOwnedSlice(arena);
}

fn hasUse(e: *const catalog.Entry, u: []const u8) bool {
    for (e.use_cases) |x| if (std.ascii.eqlIgnoreCase(x, u)) return true;
    return false;
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
    var cat: catalog.Catalog = .{};
    var caps: capcache.Map = .empty;
    const it = try items(a.allocator(), srcs, &models, &infos, &stored, &cat, &caps);
    try std.testing.expectEqual(@as(usize, 3 + 2 + 1), it.len); // + the llama model (capability unknown)
    try std.testing.expect(it[0] == .source);
    try std.testing.expectEqualStrings("big:30b", it[3].agent.id);
    try std.testing.expectEqual(policy.Level.ask, it[3].agent.level); // default for 30B
    try std.testing.expect(!it[3].agent.custom);
    try std.testing.expectEqual(policy.Level.ask, it[4].agent.level); // stored override on a 1B model
    try std.testing.expectEqual(policy.Level.read_only, it[4].agent.default_level);
    try std.testing.expect(it[4].agent.custom);
    try std.testing.expectEqual(backend.Kind.llama, it[5].agent.backend);
    try std.testing.expectEqual(ToolsKnowledge.unknown, it[5].agent.tools);
}

test "llama capability comes from the cache first, then the catalog hint" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const srcs = try sources.defaults(a.allocator());
    const models = [_]backend.Model{
        .{ .backend = .llama, .id = "o/yes-20b:Q4" },
        .{ .backend = .llama, .id = "o/no-7b:Q4" },
        .{ .backend = .llama, .id = "o/hint-3b:Q4" },
        .{ .backend = .llama, .id = "o/nothing-3b:Q4" },
    };
    var infos: std.StringHashMapUnmanaged(modelinfo.Info) = .empty;
    var cat: catalog.Catalog = .{};
    var p: catalog.Problem = .{};
    try cat.load(a.allocator(), std.testing.allocator, "[[model]]\nbackend=\"llama\"\nid=\"o/hint-3b:Q4\"\nuse_cases=[\"tools\"]\n", .user, &p);
    var caps: capcache.Map = .empty;
    try caps.put(a.allocator(), "llama:o/yes-20b:Q4", true);
    try caps.put(a.allocator(), "llama:o/no-7b:Q4", false);
    const it = try items(a.allocator(), srcs, &models, &infos, &.{}, &cat, &caps);
    const base = srcs.len;
    try std.testing.expectEqual(ToolsKnowledge.verified_yes, it[base].agent.tools);
    try std.testing.expectEqual(policy.Level.inspect, it[base].agent.default_level); // 20B
    try std.testing.expectEqual(ToolsKnowledge.verified_no, it[base + 1].agent.tools);
    try std.testing.expectEqual(policy.Level.off, it[base + 1].agent.default_level); // no tools -> off
    try std.testing.expectEqual(ToolsKnowledge.catalog_hint, it[base + 2].agent.tools);
    try std.testing.expectEqual(ToolsKnowledge.unknown, it[base + 3].agent.tools);
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
