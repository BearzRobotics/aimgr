//! Loads the catalogs of all ENABLED catalog sources (see sources.zig), in source
//! order (earlier sources win for the same backend+id), collecting visible warnings
//! instead of failing: unknown models stay usable.
const std = @import("std");
const catalog = @import("catalog.zig");
const config = @import("config.zig");
const sources = @import("sources.zig");
const sources_io = @import("sources_io.zig");

pub const Loaded = struct {
    cat: catalog.Catalog = .{},
    /// Human-readable problems, allocated from `arena`.
    warnings: []const []const u8 = &.{},
    /// Path of the user overlay file, if an overlay source exists.
    overlay_path: ?[]const u8 = null,
    /// All configured sources (enabled or not), for display.
    sources: []const sources.Source = &.{},
};

pub fn loadAll(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !Loaded {
    var out: Loaded = .{};
    var warns: std.ArrayList([]const u8) = .empty;
    const sl = try sources_io.load(arena, gpa, io, env);
    out.sources = sl.list;
    if (sl.warning) |w| try warns.append(arena, w);

    for (sl.list) |src| {
        if (!src.enabled or !src.kind.isCatalog()) continue;
        var prob: catalog.Problem = .{};
        switch (src.kind) {
            .bundled => {
                out.cat.loadWith(arena, gpa, catalog.bundled_text, .bundled, src.id, false, &prob) catch |e| {
                    try warns.append(arena, try std.fmt.allocPrint(arena, "source '{s}': bundled catalog invalid: {s} ({s})", .{ src.id, @errorName(e), prob.message }));
                };
            },
            .overlay => {
                const path = src.location orelse ((try config.configPath(arena, env, "models.toml")) orelse continue);
                out.overlay_path = path;
                try loadFile(arena, gpa, io, &out.cat, src, path, &warns, true);
            },
            .catalog_file => try loadFile(arena, gpa, io, &out.cat, src, src.location.?, &warns, false),
            .catalog_url => {
                const path = (try sources_io.cacheFile(arena, env, src.id)) orelse continue;
                try loadFile(arena, gpa, io, &out.cat, src, path, &warns, false);
            },
            .huggingface => unreachable,
        }
    }
    out.warnings = try warns.toOwnedSlice(arena);
    return out;
}

fn loadFile(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, cat: *catalog.Catalog, src: sources.Source, path: []const u8, warns: *std.ArrayList([]const u8), missing_ok: bool) !void {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |e| {
        if (e == error.FileNotFound) {
            if (missing_ok) return;
            const hint = if (src.kind == .catalog_url) try std.fmt.allocPrint(arena, " (not downloaded yet: run 'aimgr sources refresh {s}')", .{src.id}) else "";
            try warns.append(arena, try std.fmt.allocPrint(arena, "source '{s}': {s} not found{s}", .{ src.id, path, hint }));
            return;
        }
        try warns.append(arena, try std.fmt.allocPrint(arena, "source '{s}': cannot read {s}: {s}", .{ src.id, path, @errorName(e) }));
        return;
    };
    defer gpa.free(text);
    var prob: catalog.Problem = .{};
    cat.loadWith(arena, gpa, text, .user, src.id, false, &prob) catch |e| {
        try warns.append(arena, try std.fmt.allocPrint(arena, "source '{s}': {s}:{d}:{d}: invalid catalog: {s} {s} (source ignored)", .{ src.id, path, prob.line, prob.column, @errorName(e), prob.message }));
    };
}
