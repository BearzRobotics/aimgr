//! `aimgr sources ...`: list, add, enable, disable, remove, refresh.
//! Changing the list only edits config.toml; `refresh` is the one network step
//! (downloads a catalog-url source into the cache after validating it).
const std = @import("std");
const catalog_io = @import("catalog_io.zig");
const sources = @import("sources.zig");
const sources_io = @import("sources_io.zig");

const usage =
    \\usage:
    \\  aimgr sources [list]
    \\  aimgr sources add <kind> <id> [<location>] [--disabled]
    \\        kinds: catalog-file <id> <path> | catalog-url <id> <https-url> | huggingface <id> [<https-endpoint>]
    \\  aimgr sources enable <id>
    \\  aimgr sources disable <id>
    \\  aimgr sources remove <id>          (built-in sources can only be disabled)
    \\  aimgr sources refresh [<id>]       download catalog-url sources (network, explicit)
    \\
;

pub fn run(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, out: *std.Io.Writer, err: *std.Io.Writer, args: []const [:0]const u8) !u8 {
    const sub = if (args.len > 0) args[0] else "list";
    const loaded = try sources_io.load(arena, gpa, io, env);
    if (loaded.warning) |w| try err.print("aimgr: {s}\n", .{w});

    if (std.mem.eql(u8, sub, "list")) return list(arena, gpa, io, env, out, loaded);

    var items: std.ArrayList(sources.Source) = .empty;
    try items.appendSlice(arena, loaded.list);

    if (std.mem.eql(u8, sub, "refresh")) return refresh(arena, gpa, io, env, out, err, loaded.list, if (args.len > 1) args[1] else null);

    const path = loaded.path orelse {
        try err.writeAll("aimgr: cannot determine a config directory (HOME / XDG_CONFIG_HOME not set)\n");
        return 1;
    };

    if (std.mem.eql(u8, sub, "add")) {
        if (args.len < 3) return fail(err, usage);
        const kind = sources.Kind.parse(args[1]) orelse return fail(err, sources.errorText(error.UnknownKind));
        if (kind == .bundled or kind == .overlay) {
            try err.writeAll("aimgr: bundled and overlay sources are built in; enable or disable them instead\n");
            return 2;
        }
        var location: ?[]const u8 = null;
        var enabled = true;
        for (args[3..]) |a| {
            if (std.mem.eql(u8, a, "--disabled")) enabled = false else if (location == null) location = a else return fail(err, usage);
        }
        const src: sources.Source = .{ .id = args[2], .kind = kind, .enabled = enabled, .location = location };
        sources.add(arena, &items, src) catch |e| {
            try err.print("aimgr: {s}\n", .{sources.errorText(e)});
            return 2;
        };
        if (kind == .catalog_file) std.Io.Dir.cwd().access(io, location.?, .{}) catch try err.print("warning: {s} does not exist yet; the source will be skipped until it does\n", .{location.?});
        try sources_io.save(arena, io, path, items.items);
        try out.print("added source '{s}' ({s}, {s})\n", .{ src.id, kind.text(), if (enabled) "enabled" else "disabled" });
        if (kind == .catalog_url) try out.print("download it with: aimgr sources refresh {s}   (uses the network)\n", .{src.id});
        return 0;
    }
    if (std.mem.eql(u8, sub, "enable") or std.mem.eql(u8, sub, "disable")) {
        if (args.len != 2) return fail(err, usage);
        const on = std.mem.eql(u8, sub, "enable");
        sources.setEnabled(items.items, args[1], on) catch |e| {
            try err.print("aimgr: {s}: '{s}'\n", .{ sources.errorText(e), args[1] });
            return 1;
        };
        try sources_io.save(arena, io, path, items.items);
        try out.print("source '{s}' {s}\n", .{ args[1], if (on) "enabled" else "disabled" });
        return 0;
    }
    if (std.mem.eql(u8, sub, "remove")) {
        if (args.len != 2) return fail(err, usage);
        sources.remove(&items, args[1]) catch |e| {
            try err.print("aimgr: {s}: '{s}'\n", .{ sources.errorText(e), args[1] });
            return 1;
        };
        try sources_io.save(arena, io, path, items.items);
        try out.print("removed source '{s}' (cached downloads, if any, are left in the cache directory)\n", .{args[1]});
        return 0;
    }
    return fail(err, usage);
}

fn fail(err: *std.Io.Writer, msg: []const u8) !u8 {
    try err.print("aimgr: {s}{s}", .{ msg, if (std.mem.endsWith(u8, msg, "\n")) "" else "\n" });
    return 2;
}

fn state(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, s: sources.Source) ![]const u8 {
    switch (s.kind) {
        .bundled => return "built in (dated snapshot)",
        .huggingface => return "online: used by search / browse only",
        .overlay, .catalog_file, .catalog_url => {
            const path = switch (s.kind) {
                .overlay => s.location orelse ((try @import("config.zig").configPath(arena, env, "models.toml")) orelse return "no config dir"),
                .catalog_file => s.location.?,
                else => (try sources_io.cacheFile(arena, env, s.id)) orelse return "no cache dir",
            };
            std.Io.Dir.cwd().access(io, path, .{}) catch return if (s.kind == .catalog_url) "not downloaded (aimgr sources refresh)" else "file not found";
            _ = gpa;
            return if (s.kind == .catalog_url) "downloaded (cached copy)" else "file present";
        },
    }
}

fn list(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, out: *std.Io.Writer, loaded: sources_io.Loaded) !u8 {
    try out.print("sources (order = precedence for catalogs; config: {s})\n", .{loaded.path orelse "(none)"});
    for (loaded.list) |s| {
        try out.print("  {s:<9} {s:<14} {s:<13} {s}  [{s}]\n", .{
            if (s.enabled) "enabled" else "disabled",
            s.kind.text(),
            s.id,
            s.location orelse "-",
            try state(arena, gpa, io, env, s),
        });
    }
    return 0;
}

fn refresh(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, out: *std.Io.Writer, err: *std.Io.Writer, list_: []const sources.Source, only: ?[]const u8) !u8 {
    var code: u8 = 0;
    var any = false;
    for (list_) |s| {
        if (s.kind != .catalog_url) continue;
        if (only) |o| if (!std.mem.eql(u8, o, s.id)) continue;
        if (only == null and !s.enabled) continue;
        any = true;
        try out.print("downloading '{s}' from {s} (network)...\n", .{ s.id, s.location.? });
        try out.flush();
        const n = sources_io.refresh(arena, gpa, io, env, s) catch |e| {
            try err.print("aimgr: {s}: {s}\n", .{ s.id, sources_io.refreshErrorText(e) });
            code = 1;
            continue;
        };
        try out.print("  ok: {d} entries cached\n", .{n});
    }
    if (!any) {
        try err.writeAll(if (only != null) "aimgr: no such catalog-url source\n" else "aimgr: no enabled catalog-url sources to refresh\n");
        return 1;
    }
    return code;
}

test "usage mentions every subcommand" {
    for ([_][]const u8{ "add", "enable", "disable", "remove", "refresh" }) |w| try std.testing.expect(std.mem.indexOf(u8, usage, w) != null);
    _ = catalog_io;
}
