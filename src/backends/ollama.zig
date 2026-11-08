//! Ollama adapter. Verified against `ollama list` / `ollama --version` 0.40.15.
const std = @import("std");
const backend = @import("../backend.zig");
const process = @import("../process.zig");

pub const capabilities: backend.Capabilities = .{
    .list = true,
    .pull = true,
    .remove = true,
};

const expected_header = [_][]const u8{ "NAME", "ID", "SIZE", "MODIFIED" };

/// Splits a line on runs of two or more spaces (or tabs). Single spaces are
/// kept ("4.7 GB", "2 weeks ago").
fn splitColumns(line: []const u8, out: [][]const u8) usize {
    var n: usize = 0;
    var start: ?usize = null;
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        const prev_ws = i > 0 and (line[i - 1] == ' ' or line[i - 1] == '\t');
        const next_ws = i + 1 >= line.len or line[i + 1] == ' ' or line[i + 1] == '\t';
        const sep = c == '\t' or (c == ' ' and (prev_ws or next_ws));
        if (sep) {
            if (start) |s| {
                if (n < out.len) out[n] = line[s..i];
                n += 1;
                start = null;
            }
        } else if (start == null) start = i;
        i += 1;
    }
    if (start) |s| {
        if (n < out.len) out[n] = line[s..];
        n += 1;
    }
    return n;
}

pub fn parseVersion(text: []const u8) ?[]const u8 {
    const prefix = "ollama version is ";
    const t = std.mem.trim(u8, text, " \r\n");
    if (!std.mem.startsWith(u8, t, prefix)) return null;
    return t[prefix.len..];
}

/// Parse `ollama list` output. Fails with UnsupportedFormat on header/shape mismatch.
pub fn parseList(arena: std.mem.Allocator, text: []const u8) backend.ListError![]backend.Model {
    var it = std.mem.tokenizeAny(u8, text, "\r\n");
    const header = it.next() orelse return error.UnsupportedFormat;
    var cols: [8][]const u8 = undefined;
    const hn = splitColumns(header, &cols);
    if (hn != expected_header.len) return error.UnsupportedFormat;
    for (expected_header, 0..) |h, i| if (!std.mem.eql(u8, h, cols[i])) return error.UnsupportedFormat;

    var models: std.ArrayList(backend.Model) = .empty;
    while (it.next()) |line| {
        if (std.mem.trim(u8, line, " \t").len == 0) continue;
        const n = splitColumns(line, &cols);
        if (n != expected_header.len) return error.UnsupportedFormat;
        try models.append(arena, .{
            .backend = .ollama,
            .id = try arena.dupe(u8, cols[0]),
            .digest = try arena.dupe(u8, cols[1]),
            .size_text = try arena.dupe(u8, cols[2]),
            .modified = try arena.dupe(u8, cols[3]),
        });
    }
    return models.toOwnedSlice(arena);
}

pub fn probe(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io) backend.ProbeStatus {
    const r = process.run(gpa, io, &.{ "ollama", "--version" }, 10);
    defer r.deinit(gpa);
    switch (r.outcome) {
        .not_found => return .missing,
        .exited => |c| if (c != 0) return .{ .failed = "ollama --version exited non-zero" },
        else => return .{ .failed = "ollama --version could not run" },
    }
    const v = parseVersion(r.stdout) orelse return .{ .failed = "unrecognized ollama --version output" };
    return .{ .available = arena.dupe(u8, v) catch return .{ .failed = "out of memory" } };
}

pub fn list(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io) backend.ListError![]backend.Model {
    const r = process.run(gpa, io, &.{ "ollama", "list" }, 30);
    defer r.deinit(gpa);
    switch (r.outcome) {
        .not_found => return error.BackendMissing,
        .exited => |c| if (c != 0) return error.BackendFailed,
        else => return error.BackendFailed,
    }
    return parseList(arena, r.stdout);
}

test "parse empty list (real capture)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = try parseList(arena.allocator(), @embedFile("../fixtures/ollama-list-empty.txt"));
    try std.testing.expectEqual(@as(usize, 0), m.len);
}

test "parse list (synthetic fixture)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = try parseList(arena.allocator(), @embedFile("../fixtures/ollama-list-synthetic.txt"));
    try std.testing.expectEqual(@as(usize, 2), m.len);
    try std.testing.expectEqualStrings("llama3.2:3b", m[0].id);
    try std.testing.expectEqualStrings("2.0 GB", m[0].size_text.?);
    try std.testing.expectEqualStrings("3 days ago", m[1].modified.?);
}

test "unknown header is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnsupportedFormat, parseList(arena.allocator(), "FOO  BAR\nx  y\n"));
}

test "parse version (real capture)" {
    try std.testing.expectEqualStrings("0.40.15", parseVersion(@embedFile("../fixtures/ollama-version.txt")).?);
}

test "parse list (real capture with a model)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const m = try parseList(arena.allocator(), @embedFile("../fixtures/ollama-list-real.txt"));
    try std.testing.expect(m.len >= 1);
    try std.testing.expectEqual(backend.Kind.ollama, m[0].backend);
}
