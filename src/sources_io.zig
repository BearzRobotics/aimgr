//! Reading/writing the source list (config.toml), the download cache for
//! catalog-url sources, and the explicit `refresh` network step.
const std = @import("std");
const catalog = @import("catalog.zig");
const config = @import("config.zig");
const http = @import("http.zig");
const sources = @import("sources.zig");
const agent_settings = @import("agent/settings.zig");
const schedule = @import("schedule.zig");
const toml = @import("toml");

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

/// The non-source tables already in the file, so rewriting one kind never drops another.
const Extras = struct {
    agents: []agent_settings.Entry = &.{},
    schedules: []schedule.Entry = &.{},
    /// The file's current text, for its comments.
    old: ?[]const u8 = null,
};

fn readExtras(arena: std.mem.Allocator, io: std.Io, path: []const u8) Extras {
    const old = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch return .{};
    return .{
        .agents = agent_settings.parse(arena, arena, old) catch &.{},
        .schedules = schedule.parse(arena, arena, old) catch &.{},
        .old = old,
    };
}

fn compose(arena: std.mem.Allocator, list: []const sources.Source, agents: []const agent_settings.Entry, schedules: []const schedule.Entry, old_text: ?[]const u8) ![]const u8 {
    const fresh = try std.mem.concat(arena, u8, &.{
        try sources.serialize(arena, list),
        try agent_settings.serialize(arena, agents),
        try schedule.serialize(arena, schedules),
    });
    return if (old_text) |o| carryComments(arena, o, fresh) else fresh;
}

/// The comments of the file being replaced, put back on the text just generated: each `[[source]]`,
/// `[[agent]]` and `[[schedule]]` table keeps the comments above it and on its keys (matched by `id`),
/// and the comments at the end of the file stay. A file that cannot be parsed is replaced as it is.
pub fn carryComments(arena: std.mem.Allocator, old_text: []const u8, fresh: []const u8) []const u8 {
    var old = toml.Document.parse(arena, old_text, .{}, null) catch return fresh;
    defer old.deinit();
    var new = toml.Document.parse(arena, fresh, .{}, null) catch return fresh;
    defer new.deinit();
    for (new.root.entries.keys(), new.root.entries.values()) |name, nv| {
        const na = switch (nv) {
            .array => |a| a,
            else => continue,
        };
        const ov = old.root.get(name) orelse continue;
        const oa = switch (ov) {
            .array => |a| a,
            else => continue,
        };
        for (na.items.items) |ni| {
            if (ni != .table) continue;
            const nt = ni.table;
            const id = nt.getString("id") orelse continue;
            for (oa.items.items) |oi| {
                if (oi != .table) continue;
                const ot = oi.table;
                const oid = ot.getString("id") orelse continue;
                if (!std.mem.eql(u8, oid, id)) continue;
                nt.header = ot.header;
                for (nt.entries.keys()) |k| {
                    if (ot.commentsOf(k)) |c| nt.setComments(new.allocator(), k, c) catch return fresh;
                }
                break;
            }
        }
    }
    new.root.footer = old.root.footer;
    return new.toOwnedString(arena) catch fresh;
}

test "comments in the old file stay on the tables they were written on" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const old =
        \\# my notes
        \\
        \\# the local one
        \\[[source]]
        \\id = "mine"
        \\kind = "catalog-file"
        \\enabled = true # temporarily on
        \\location = "/tmp/m.toml"
        \\
        \\# last words
        \\
    ;
    const list = [_]sources.Source{.{ .id = "mine", .kind = .catalog_file, .enabled = false, .location = "/tmp/m.toml" }};
    const out = try compose(a.allocator(), &list, &.{}, &.{}, old);
    try std.testing.expect(std.mem.indexOf(u8, out, "# the local one\n[[source]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "enabled = false # temporarily on") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "# last words\n"));
    // A file that is not valid TOML is simply replaced.
    const plain = try compose(a.allocator(), &list, &.{}, &.{}, "[[[");
    try std.testing.expect(std.mem.indexOf(u8, plain, "enabled = false") != null);
}

/// Atomic replace (temp file + rename). Creates the config directory if needed. Existing [[agent]] and
/// [[schedule]] tables in the file are preserved.
pub fn save(arena: std.mem.Allocator, io: std.Io, path: []const u8, list: []const sources.Source) !void {
    const ex = readExtras(arena, io, path);
    try writeAtomic(arena, io, path, try compose(arena, list, ex.agents, ex.schedules, ex.old));
}

/// Replace the [[agent]] tables, keeping sources and schedules as they are.
pub fn saveAgents(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, entries: []const agent_settings.Entry) !void {
    const loaded = try load(arena, gpa, io, env);
    const path = loaded.path orelse return error.NoConfigDir;
    const ex = readExtras(arena, io, path);
    try writeAtomic(arena, io, path, try compose(arena, loaded.list, entries, ex.schedules, ex.old));
}

/// Replace the [[schedule]] tables, keeping sources and agent settings as they are.
pub fn saveSchedules(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, entries: []const schedule.Entry) !void {
    const loaded = try load(arena, gpa, io, env);
    const path = loaded.path orelse return error.NoConfigDir;
    const ex = readExtras(arena, io, path);
    try writeAtomic(arena, io, path, try compose(arena, loaded.list, ex.agents, entries, ex.old));
}

pub fn loadSchedules(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ![]schedule.Entry {
    const path = (try configFile(arena, env)) orelse return &.{};
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return &.{};
    defer gpa.free(text);
    return schedule.parse(arena, gpa, text);
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
