//! Pull / update / remove planning. Pure: builds argv and advisory text only.
//! Verified: `ollama pull MODEL`, `ollama rm MODEL` (0.40.15);
//! `llama download -hf <repo>[:quant]` (0.9.0-dev build 12182).
//! llama has no removal command in `llama help all`, so removal is disabled.
const std = @import("std");
const backend = @import("backend.zig");
const launcher = @import("launcher.zig");

pub const Action = enum { pull, update, remove };

pub const Error = error{
    InvalidModelId,
    /// llama ids must look like <user>/<model>[:quant].
    InvalidLlamaId,
    Unsupported,
    OutOfMemory,
};

pub fn errorText(e: Error) []const u8 {
    return switch (e) {
        error.InvalidModelId => "model id is empty, starts with '-', or has control characters",
        error.InvalidLlamaId => "llama ids must look like <user>/<model>[:quant]",
        error.Unsupported => "this action is not supported by the backend",
        error.OutOfMemory => "out of memory",
    };
}

/// Why an action is unavailable for a backend, or null when supported.
pub fn unsupportedReason(kind: backend.Kind, action: Action) ?[]const u8 {
    return switch (kind) {
        .ollama => null,
        .llama => if (action == .remove)
            "llama 0.9.0-dev has no supported removal command (not in 'llama help all'); aimgr will not delete cache files directly"
        else
            null,
    };
}

pub fn plan(arena: std.mem.Allocator, kind: backend.Kind, action: Action, id: []const u8) Error![]const []const u8 {
    if (!launcher.validModelId(id)) return error.InvalidModelId;
    if (unsupportedReason(kind, action) != null) return error.Unsupported;
    var argv: std.ArrayList([]const u8) = .empty;
    switch (kind) {
        .ollama => switch (action) {
            .pull, .update => try argv.appendSlice(arena, &.{ "ollama", "pull", id }),
            .remove => try argv.appendSlice(arena, &.{ "ollama", "rm", id }),
        },
        .llama => {
            const slash = std.mem.indexOfScalar(u8, id, '/') orelse return error.InvalidLlamaId;
            if (slash == 0 or slash + 1 >= id.len) return error.InvalidLlamaId;
            try argv.appendSlice(arena, &.{ "llama", "download", "-hf", id });
        },
    }
    return argv.toOwnedSlice(arena);
}

pub const mutable_tag_warning = "warning: updating re-downloads the identifier; mutable tags (e.g. ':latest') may now point at different content. aimgr cannot check revisions and does not claim to.";

/// A comparable base name: text after the last '/', before ':', lowercase, without "-gguf".
pub fn baseName(buf: []u8, id: []const u8) []const u8 {
    var s = id;
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| s = s[i + 1 ..];
    if (std.mem.indexOfScalar(u8, s, ':')) |i| s = s[0..i];
    const n = @min(s.len, buf.len);
    const lower = std.ascii.lowerString(buf[0..n], s[0..n]);
    return if (std.mem.endsWith(u8, lower, "-gguf")) lower[0 .. lower.len - 5] else lower;
}

pub const Duplicate = struct {
    model: backend.Model,
    /// True: identical id on another backend. False: same base name, different variant/backend.
    exact_id: bool,
};

/// Other installed models that share the target's identifier or base name.
pub fn duplicates(arena: std.mem.Allocator, all: []const backend.Model, kind: backend.Kind, id: []const u8) ![]Duplicate {
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    const base = baseName(&b1, id);
    var out: std.ArrayList(Duplicate) = .empty;
    for (all) |m| {
        if (m.backend == kind and std.mem.eql(u8, m.id, id)) continue;
        const exact = std.mem.eql(u8, m.id, id);
        if (exact or std.mem.eql(u8, baseName(&b2, m.id), base)) {
            try out.append(arena, .{ .model = m, .exact_id = exact });
        }
    }
    return out.toOwnedSlice(arena);
}

test "argv for each backend/action" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "ollama", "pull", "qwen3:8b" }), try plan(a.allocator(), .ollama, .pull, "qwen3:8b"));
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "ollama", "pull", "qwen3:8b" }), try plan(a.allocator(), .ollama, .update, "qwen3:8b"));
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "ollama", "rm", "qwen3:8b" }), try plan(a.allocator(), .ollama, .remove, "qwen3:8b"));
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "llama", "download", "-hf", "o/m:Q4_K_M" }), try plan(a.allocator(), .llama, .pull, "o/m:Q4_K_M"));
}

test "llama removal is disabled, not guessed" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expect(unsupportedReason(.llama, .remove) != null);
    try std.testing.expectError(error.Unsupported, plan(a.allocator(), .llama, .remove, "o/m:Q4"));
}

test "invalid ids" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectError(error.InvalidModelId, plan(a.allocator(), .ollama, .pull, "-x"));
    try std.testing.expectError(error.InvalidLlamaId, plan(a.allocator(), .llama, .pull, "noslash"));
    try std.testing.expectError(error.InvalidLlamaId, plan(a.allocator(), .llama, .pull, "/x"));
}

test "duplicate detection" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const all = [_]backend.Model{
        .{ .backend = .ollama, .id = "qwen3:8b" },
        .{ .backend = .llama, .id = "Qwen/Qwen3-GGUF:Q4_K_M" },
        .{ .backend = .llama, .id = "other/Mistral-GGUF:Q4" },
        .{ .backend = .llama, .id = "qwen3:8b" },
    };
    const d = try duplicates(a.allocator(), &all, .ollama, "qwen3:8b");
    try std.testing.expectEqual(@as(usize, 2), d.len);
    try std.testing.expect(!d[0].exact_id); // Qwen3 by base name
    try std.testing.expect(d[1].exact_id); // same id on llama
}
