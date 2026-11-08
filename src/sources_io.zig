//! Reading/writing the source list (config.toml), the download cache for
//! catalog-url sources, and the explicit `refresh` network step.
const std = @import("std");
const catalog = @import("catalog.zig");
const config = @import("config.zig");
const http = @import("http.zig");
const sources = @import("sources.zig");
const agent_settings = @import("agent/settings.zig");

pub const Loaded = struct {
    list: []sources.Source,
    path: ?[]const u8,
    /// Set when config.toml could not be used (defaults are used instead; the file is left untouched).
    warning: ?[]const u8 = null,
};

pub fn configFile(arena: std.mem.Allocator, env: *const std.process.Environ.Map) !?[]const u8 {
    return config.configPath(arena, env, "config.toml");
}

pub fn load(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !Loaded {
    const path = (try configFile(arena, env)) orelse return .{ .list = try sources.defaults(arena), .path = null };
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |e| {
        if (e == error.FileNotFound) return .{ .list = try sources.defaults(arena), .path = path };
        return .{ .list = try sources.defaults(arena), .path = path, .warning = try std.fmt.allocPrint(arena, "cannot read {s}: {s} (using default sources)", .{ path, @errorName(e) }) };
    };
    defer gpa.free(text);
    const list = sources.parse(arena, gpa, text) catch |e| {
        return .{ .list = try sources.defaults(arena), .path = path, .warning = try std.fmt.allocPrint(arena, "{s}: {s} (using default sources; the file was not modified)", .{ path, sources.errorText(e) }) };
    };
    return .{ .list = list, .path = path };
}

/// Atomic replace (temp file + rename). Creates the config directory if needed. Existing
/// [[agent]] tables in the file are preserved.
pub fn save(arena: std.mem.Allocator, io: std.Io, path: []const u8, list: []const sources.Source) !void {
    var text = try sources.serialize(arena, list);
    if (std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20))) |old| {
        if (agent_settings.parse(arena, arena, old)) |agents| {
            if (agents.len > 0) text = try std.mem.concat(arena, u8, &.{ text, try agent_settings.serialize(arena, agents) });
        } else |_| {}
    } else |_| {}
    try writeAtomic(arena, io, path, text);
}

/// Replace the [[agent]] tables, keeping the [[source]] tables as they are.
pub fn saveAgents(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, entries: []const agent_settings.Entry) !void {
    const loaded = try load(arena, gpa, io, env);
    const path = loaded.path orelse return error.NoConfigDir;
    const text = try std.mem.concat(arena, u8, &.{ try sources.serialize(arena, loaded.list), try agent_settings.serialize(arena, entries) });
    try writeAtomic(arena, io, path, text);
}

pub fn loadAgents(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ![]agent_settings.Entry {
    const path = (try configFile(arena, env)) orelse return &.{};
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return &.{};
    defer gpa.free(text);
    return agent_settings.parse(arena, gpa, text);
}

fn writeAtomic(arena: std.mem.Allocator, io: std.Io, path: []const u8, text: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
    const tmp = try std.fmt.allocPrint(arena, "{s}.tmp", .{path});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = text });
    try std.Io.Dir.rename(std.Io.Dir.cwd(), tmp, std.Io.Dir.cwd(), path, io);
}

pub fn cacheFile(arena: std.mem.Allocator, env: *const std.process.Environ.Map, id: []const u8) !?[]const u8 {
    const sub = try std.fmt.allocPrint(arena, "sources/{s}", .{try sources.cacheFileName(arena, id)});
    return config.cachePath(arena, env, sub);
}

pub const RefreshError = error{ NotACatalogUrl, NoCacheDir, NetworkFailed, BadStatus, TooLarge, InvalidCatalog, EmptyCatalog, WriteFailed, OutOfMemory };

pub fn refreshErrorText(e: RefreshError) []const u8 {
    return switch (e) {
        error.NotACatalogUrl => "only catalog-url sources can be refreshed",
        error.NoCacheDir => "cannot determine a cache directory (HOME / XDG_CACHE_HOME not set)",
        error.NetworkFailed => "network request failed",
        error.BadStatus => "the server did not return 200 OK",
        error.TooLarge => "catalog is larger than 2 MiB",
        error.InvalidCatalog => "the downloaded file is not a valid catalog (nothing was saved)",
        error.EmptyCatalog => "the downloaded catalog has no [[model]] entries (nothing was saved)",
        error.WriteFailed => "could not write the cache file",
        error.OutOfMemory => "out of memory",
    };
}

/// Download a catalog-url source, validate it as a catalog, and only then replace the cached copy.
/// Returns the number of entries.
pub fn refresh(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, src: sources.Source) RefreshError!usize {
    if (src.kind != .catalog_url) return error.NotACatalogUrl;
    const url = src.location orelse return error.NotACatalogUrl;
    const dest = (cacheFile(arena, env, src.id) catch return error.OutOfMemory) orelse return error.NoCacheDir;
    const body = http.get(gpa, io, url, 2 << 20) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.NetworkFailed => error.NetworkFailed,
        error.BadStatus => error.BadStatus,
        error.TooLarge => error.TooLarge,
    };
    defer gpa.free(body);

    var scratch: catalog.Catalog = .{};
    var prob: catalog.Problem = .{};
    scratch.loadWith(arena, gpa, body, .user, src.id, false, &prob) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidCatalog => error.InvalidCatalog,
    };
    if (scratch.entries.items.len == 0) return error.EmptyCatalog;

    if (std.fs.path.dirname(dest)) |d| std.Io.Dir.cwd().createDirPath(io, d) catch return error.WriteFailed;
    const tmp = std.fmt.allocPrint(arena, "{s}.tmp", .{dest}) catch return error.OutOfMemory;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = body }) catch return error.WriteFailed;
    std.Io.Dir.rename(std.Io.Dir.cwd(), tmp, std.Io.Dir.cwd(), dest, io) catch return error.WriteFailed;
    return scratch.entries.items.len;
}
