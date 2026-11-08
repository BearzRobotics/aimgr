//! XDG paths. Only variables actually consulted: XDG_CONFIG_HOME, HOME.
const std = @import("std");

/// $XDG_CONFIG_HOME/aimgr/<file> or ~/.config/aimgr/<file>. Null if neither is set.
pub fn configPath(arena: std.mem.Allocator, env: *const std.process.Environ.Map, file: []const u8) !?[]const u8 {
    if (env.get("XDG_CONFIG_HOME")) |x| {
        if (x.len > 0 and x[0] == '/') return try std.fs.path.join(arena, &.{ x, "aimgr", file });
    }
    if (env.get("HOME")) |h| {
        if (h.len > 0) return try std.fs.path.join(arena, &.{ h, ".config", "aimgr", file });
    }
    return null;
}

/// $XDG_STATE_HOME/aimgr/<sub> or ~/.local/state/aimgr/<sub>.
pub fn statePath(arena: std.mem.Allocator, env: *const std.process.Environ.Map, sub: []const u8) !?[]const u8 {
    if (env.get("XDG_STATE_HOME")) |x| {
        if (x.len > 0 and x[0] == '/') return try std.fs.path.join(arena, &.{ x, "aimgr", sub });
    }
    if (env.get("HOME")) |h| {
        if (h.len > 0) return try std.fs.path.join(arena, &.{ h, ".local", "state", "aimgr", sub });
    }
    return null;
}

/// $XDG_DATA_HOME/aimgr or ~/.local/share/aimgr.
pub fn dataDir(arena: std.mem.Allocator, env: *const std.process.Environ.Map) !?[]const u8 {
    if (env.get("XDG_DATA_HOME")) |x| {
        if (x.len > 0 and x[0] == '/') return try std.fs.path.join(arena, &.{ x, "aimgr" });
    }
    if (env.get("HOME")) |h| {
        if (h.len > 0) return try std.fs.path.join(arena, &.{ h, ".local", "share", "aimgr" });
    }
    return null;
}

/// Directory holding bundled resources (abliterate/, llama-convert/): $AIMGR_RESOURCES,
/// else <exe dir>/../share/aimgr. Null if neither contains abliterate/helper.py.
pub fn resourceDir(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !?[]const u8 {
    if (env.get("AIMGR_RESOURCES")) |r| {
        if (hasHelper(io, arena, r)) return r;
        return null;
    }
    const exe_dir = std.process.executableDirPathAlloc(io, arena) catch return null;
    const cand = try std.fs.path.join(arena, &.{ exe_dir, "..", "share", "aimgr" });
    return if (hasHelper(io, arena, cand)) cand else null;
}

fn hasHelper(io: std.Io, arena: std.mem.Allocator, dir: []const u8) bool {
    const p = std.fs.path.join(arena, &.{ dir, "abliterate", "helper.py" }) catch return false;
    std.Io.Dir.cwd().access(io, p, .{}) catch return false;
    return true;
}
