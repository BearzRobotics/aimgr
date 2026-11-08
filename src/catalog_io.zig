//! Loads the bundled catalog plus the user overlay from disk, collecting
//! visible warnings instead of failing (unknown models stay usable).
const std = @import("std");
const catalog = @import("catalog.zig");
const config = @import("config.zig");

pub const Loaded = struct {
    cat: catalog.Catalog = .{},
    /// Human-readable problems, allocated from `arena`.
    warnings: []const []const u8 = &.{},
    overlay_path: ?[]const u8 = null,
};

pub fn loadAll(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !Loaded {
    var out: Loaded = .{};
    var warns: std.ArrayList([]const u8) = .empty;
    var prob: catalog.Problem = .{};
    catalog.loadBundled(arena, gpa, &out.cat, &prob) catch |e| {
        try warns.append(arena, try std.fmt.allocPrint(arena, "bundled catalog invalid: {s} ({s})", .{ @errorName(e), prob.message }));
        out.warnings = try warns.toOwnedSlice(arena);
        return out;
    };
    const path = (try config.configPath(arena, env, "models.toml")) orelse {
        out.warnings = try warns.toOwnedSlice(arena);
        return out;
    };
    out.overlay_path = path;
    if (std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20))) |text| {
        defer gpa.free(text);
        out.cat.load(arena, gpa, text, .user, &prob) catch |e| {
            try warns.append(arena, try std.fmt.allocPrint(arena, "{s}:{d}:{d}: invalid catalog: {s} {s} (user overlay ignored)", .{ path, prob.line, prob.column, @errorName(e), prob.message }));
        };
    } else |e| {
        if (e != error.FileNotFound) try warns.append(arena, try std.fmt.allocPrint(arena, "cannot read {s}: {s} (using bundled catalog only)", .{ path, @errorName(e) }));
    }
    out.warnings = try warns.toOwnedSlice(arena);
    return out;
}
