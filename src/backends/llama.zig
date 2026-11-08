//! llama (llama.cpp distribution) adapter. Verified against
//! `llama version` 0.9.0-dev build 12182 (installed via upstream curl script).
//! This version has no `ls`/`pull`: listing uses `llama cli --cache-list`,
//! downloading uses `llama download -hf`. No removal command was found.
const std = @import("std");
const backend = @import("../backend.zig");
const process = @import("../process.zig");

pub const capabilities: backend.Capabilities = .{
    .list = true,
    .pull = true, // via `llama download -hf` (not yet implemented in aimgr)
    .remove = false,
    .remove_reason = "llama 0.9.0-dev provides no supported removal command",
};

pub fn parseVersion(text: []const u8) ?[]const u8 {
    const prefix = "version: ";
    var it = std.mem.tokenizeAny(u8, text, "\r\n");
    const first = it.next() orelse return null;
    if (!std.mem.startsWith(u8, first, prefix)) return null;
    return std.mem.trim(u8, first[prefix.len..], " ");
}

/// Parse `llama cli --cache-list`:
///   number of models in cache: N
///      1. repo/name:QUANT
pub fn parseCacheList(arena: std.mem.Allocator, text: []const u8) backend.ListError![]backend.Model {
    const header = "number of models in cache: ";
    var it = std.mem.tokenizeAny(u8, text, "\r\n");
    const first = it.next() orelse return error.UnsupportedFormat;
    if (!std.mem.startsWith(u8, first, header)) return error.UnsupportedFormat;
    const expected = std.fmt.parseInt(usize, std.mem.trim(u8, first[header.len..], " "), 10) catch
        return error.UnsupportedFormat;

    var models: std.ArrayList(backend.Model) = .empty;
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0) continue;
        const dot = std.mem.indexOfScalar(u8, line, '.') orelse return error.UnsupportedFormat;
        _ = std.fmt.parseInt(usize, line[0..dot], 10) catch return error.UnsupportedFormat;
        const id = std.mem.trim(u8, line[dot + 1 ..], " ");
        if (id.len == 0) return error.UnsupportedFormat;
        const quant: ?[]const u8 = if (std.mem.lastIndexOfScalar(u8, id, ':')) |c|
            try arena.dupe(u8, id[c + 1 ..])
        else
            null;
        try models.append(arena, .{ .backend = .llama, .id = try arena.dupe(u8, id), .quant = quant });
    }
    if (models.items.len != expected) return error.UnsupportedFormat;
    return models.toOwnedSlice(arena);
}

pub fn probe(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io) backend.ProbeStatus {
    const r = process.run(gpa, io, &.{ "llama", "version" }, 10);
    defer r.deinit(gpa);
    switch (r.outcome) {
        .not_found => return .missing,
        .exited => |c| if (c != 0) return .{ .failed = "llama version exited non-zero" },
        else => return .{ .failed = "llama version could not run" },
    }
    const v = parseVersion(r.stdout) orelse return .{ .failed = "unrecognized llama version output" };
    return .{ .available = arena.dupe(u8, v) catch return .{ .failed = "out of memory" } };
}

pub fn list(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io) backend.ListError![]backend.Model {
    const r = process.run(gpa, io, &.{ "llama", "cli", "--cache-list" }, 30);
    defer r.deinit(gpa);
    switch (r.outcome) {
        .not_found => return error.BackendMissing,
        .exited => |c| if (c != 0) return error.BackendFailed,
        else => return error.BackendFailed,
    }
    return parseCacheList(arena, r.stdout);
}

test "parse cache list (real capture)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = try parseCacheList(arena.allocator(), @embedFile("../fixtures/llama-cache-list.txt"));
    try std.testing.expectEqual(@as(usize, 4), m.len);
    try std.testing.expectEqualStrings("ggml-org/gpt-oss-20b-GGUF:MXFP4", m[0].id);
    try std.testing.expectEqualStrings("MXFP4", m[0].quant.?);
}

test "count mismatch is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnsupportedFormat, parseCacheList(arena.allocator(), "number of models in cache: 2\n   1. a/b:Q4\n"));
}

test "unknown format is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnsupportedFormat, parseCacheList(arena.allocator(), "hello\n"));
}

test "parse version (real capture)" {
    try std.testing.expectEqualStrings("0.9.0-dev (build 12182, commit fd27b2034)", parseVersion(@embedFile("../fixtures/llama-version.txt")).?);
}
