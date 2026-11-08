//! Minimal HTTPS GET used only by explicit network commands (search, browse,
//! `sources refresh`). Nothing here runs unless the user asked for it.
const std = @import("std");

pub const Error = error{ NetworkFailed, BadStatus, TooLarge, OutOfMemory };

/// Returns the response body (caller frees with `gpa`). Only https:// URLs are accepted.
pub fn get(gpa: std.mem.Allocator, io: std.Io, url: []const u8, max_bytes: usize) Error![]u8 {
    if (!std.mem.startsWith(u8, url, "https://")) return error.NetworkFailed;
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const res = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
        .extra_headers = &.{.{ .name = "user-agent", .value = "aimgr (local model manager)" }},
    }) catch return error.NetworkFailed;
    if (res.status != .ok) return error.BadStatus;
    if (body.written().len > max_bytes) return error.TooLarge;
    return gpa.dupe(u8, body.written());
}

/// POST a JSON body. Allowed targets: https://..., or plain http:// to the loopback interface only
/// (the local Ollama daemon). Returns the response body (caller frees with `gpa`).
pub fn postJson(gpa: std.mem.Allocator, io: std.Io, url: []const u8, body: []const u8, max_bytes: usize) Error![]u8 {
    const loopback = std.mem.startsWith(u8, url, "http://127.0.0.1:") or std.mem.startsWith(u8, url, "http://localhost:") or std.mem.startsWith(u8, url, "http://[::1]:");
    if (!loopback and !std.mem.startsWith(u8, url, "https://")) return error.NetworkFailed;
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .response_writer = &out.writer,
        .extra_headers = &.{
            .{ .name = "user-agent", .value = "aimgr (local model manager)" },
            .{ .name = "content-type", .value = "application/json" },
        },
    }) catch return error.NetworkFailed;
    // Ollama reports API errors as JSON with a non-200 status; hand the body to the caller either way.
    if (out.written().len > max_bytes) return error.TooLarge;
    if (res.status != .ok and out.written().len == 0) return error.BadStatus;
    return gpa.dupe(u8, out.written());
}

test "postJson refuses non-loopback plain http" {
    try std.testing.expectError(error.NetworkFailed, postJson(std.testing.allocator, std.testing.io, "http://example.org/x", "{}", 10));
    try std.testing.expectError(error.NetworkFailed, postJson(std.testing.allocator, std.testing.io, "http://192.168.1.5:11434/api/chat", "{}", 10));
    try std.testing.expectError(error.NetworkFailed, postJson(std.testing.allocator, std.testing.io, "ftp://127.0.0.1:1/", "{}", 10));
}

/// GET from the loopback interface only (health / props of a server aimgr started itself).
pub fn getLocal(gpa: std.mem.Allocator, io: std.Io, url: []const u8, max_bytes: usize) Error![]u8 {
    const loopback = std.mem.startsWith(u8, url, "http://127.0.0.1:") or std.mem.startsWith(u8, url, "http://localhost:") or std.mem.startsWith(u8, url, "http://[::1]:");
    if (!loopback) return error.NetworkFailed;
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const res = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &out.writer,
        .extra_headers = &.{.{ .name = "user-agent", .value = "aimgr (local model manager)" }},
    }) catch return error.NetworkFailed;
    if (res.status != .ok) return error.BadStatus;
    if (out.written().len > max_bytes) return error.TooLarge;
    return gpa.dupe(u8, out.written());
}

test "getLocal refuses anything but loopback" {
    try std.testing.expectError(error.NetworkFailed, getLocal(std.testing.allocator, std.testing.io, "http://example.org/x", 10));
    try std.testing.expectError(error.NetworkFailed, getLocal(std.testing.allocator, std.testing.io, "https://127.0.0.1:1/", 10));
}
