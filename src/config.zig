//! Per-user directories. Linux: XDG_CONFIG_HOME / XDG_STATE_HOME / XDG_DATA_HOME / XDG_CACHE_HOME, else
//! the standard places under HOME. Windows: %APPDATA% for config, %LOCALAPPDATA% for everything else.
const std = @import("std");
const builtin = @import("builtin");

const Env = std.process.Environ.Map;

/// The user's home directory: HOME, or USERPROFILE on Windows.
pub fn homeDir(env: *const Env) ?[]const u8 {
    if (env.get("HOME")) |h| if (h.len > 0) return h;
    if (builtin.os.tag == .windows) if (env.get("USERPROFILE")) |h| if (h.len > 0) return h;
    return null;
}

fn abs(v: ?[]const u8) ?[]const u8 {
    const x = v orelse return null;
    return if (x.len > 0 and std.fs.path.isAbsolute(x)) x else null;
}

fn pick(arena: std.mem.Allocator, env: *const Env, xdg: []const u8, win_var: []const u8, unix_rel: []const []const u8, sub: []const []const u8) !?[]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    if (abs(env.get(xdg))) |x| {
        try parts.append(arena, x);
    } else if (builtin.os.tag == .windows and abs(env.get(win_var)) != null) {
        try parts.append(arena, abs(env.get(win_var)).?);
    } else if (homeDir(env)) |h| {
        try parts.append(arena, h);
        try parts.appendSlice(arena, unix_rel);
    } else return null;
    try parts.append(arena, "aimgr");
    try parts.appendSlice(arena, sub);
    return try std.fs.path.join(arena, parts.items);
}

/// $XDG_CONFIG_HOME/aimgr/<file> or ~/.config/aimgr/<file> (Windows: %APPDATA%\aimgr\<file>). Null if undeterminable.
pub fn configPath(arena: std.mem.Allocator, env: *const Env, file: []const u8) !?[]const u8 {
    return pick(arena, env, "XDG_CONFIG_HOME", "APPDATA", &.{".config"}, &.{file});
}

/// $XDG_STATE_HOME/aimgr/<sub> or ~/.local/state/aimgr/<sub>.
pub fn statePath(arena: std.mem.Allocator, env: *const Env, sub: []const u8) !?[]const u8 {
    return pick(arena, env, "XDG_STATE_HOME", "LOCALAPPDATA", &.{ ".local", "state" }, &.{sub});
}

/// $XDG_DATA_HOME/aimgr or ~/.local/share/aimgr.
pub fn dataDir(arena: std.mem.Allocator, env: *const Env) !?[]const u8 {
    return pick(arena, env, "XDG_DATA_HOME", "LOCALAPPDATA", &.{ ".local", "share" }, &.{});
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

/// $XDG_CACHE_HOME/aimgr/<sub> or ~/.cache/aimgr/<sub>.
pub fn cachePath(arena: std.mem.Allocator, env: *const Env, sub: []const u8) !?[]const u8 {
    return pick(arena, env, "XDG_CACHE_HOME", "LOCALAPPDATA", &.{".cache"}, &.{ if (builtin.os.tag == .windows) "cache" else "", sub });
}
