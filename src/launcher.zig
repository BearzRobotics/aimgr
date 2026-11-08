//! Launch profiles, validation, and argv construction. Pure functions: nothing
//! here spawns a process or touches the network, so everything is unit-tested.
//! Flags verified against `llama serve|cli --help` (0.9.0-dev build 12182) and
//! `ollama run|serve --help` (0.40.15). No shell is involved anywhere.
const std = @import("std");
const backend = @import("backend.zig");

pub const Mode = enum { chat, server };

/// GPU layers: llama accepts an integer, "auto" or "all".
pub const GpuLayers = union(enum) { auto, all, count: u16 };

pub const Profile = struct {
    ctx: ?u32 = null,
    gpu_layers: ?GpuLayers = null,
    host: []const u8 = default_host,
    port: ?u16 = null,
};

pub const default_host = "127.0.0.1";
pub const default_llama_port: u16 = 9931;
pub const default_ollama_port: u16 = 11434;

pub const Error = error{
    InvalidModelId,
    InvalidHost,
    InvalidPort,
    InvalidContext,
    /// The backend has no supported way to apply this option in this mode.
    UnsupportedOption,
    ModelRequired,
    ModelNotAllowed,
    OutOfMemory,
};

pub fn errorText(e: Error) []const u8 {
    return switch (e) {
        error.InvalidModelId => "model id is empty, starts with '-', or has control characters",
        error.InvalidHost => "host must be an IPv4/IPv6 literal or 'localhost'",
        error.InvalidPort => "port must be 1-65535",
        error.InvalidContext => "context must be 128-4194304",
        error.UnsupportedOption => "option is not supported by this backend in this mode",
        error.ModelRequired => "this launch needs a model id",
        error.ModelNotAllowed => "this launch does not take a model (model preload is separate)",
        error.OutOfMemory => "out of memory",
    };
}

pub const Plan = struct {
    argv: []const []const u8,
    /// Extra environment variables (key, value) layered over the parent's.
    env: []const [2][]const u8 = &.{},
    /// Host/port a server plan will listen on (null for chat).
    listen_host: ?[]const u8 = null,
    listen_port: ?u16 = null,
    /// True when the host is not loopback; callers must confirm with the user.
    public_bind: bool = false,
};

pub fn validModelId(id: []const u8) bool {
    if (id.len == 0 or id[0] == '-' or id.len > 512) return false;
    for (id) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

fn isIpLiteral(s: []const u8) bool {
    if (s.len == 0 or s.len > 45) return false;
    for (s) |c| {
        if (!(std.ascii.isHex(c) or c == '.' or c == ':')) return false;
    }
    return true;
}

pub fn validHost(h: []const u8) bool {
    return std.mem.eql(u8, h, "localhost") or isIpLiteral(h);
}

pub fn isLoopback(h: []const u8) bool {
    if (std.mem.eql(u8, h, "localhost") or std.mem.eql(u8, h, "::1")) return true;
    return std.mem.startsWith(u8, h, "127.");
}

fn validate(kind: backend.Kind, mode: Mode, model: ?[]const u8, p: Profile) Error!void {
    if (p.port) |port| if (port == 0) return error.InvalidPort;
    if (p.ctx) |c| if (c < 128 or c > 4194304) return error.InvalidContext;
    if (!validHost(p.host)) return error.InvalidHost;
    switch (kind) {
        .llama => {
            const m = model orelse return error.ModelRequired;
            if (!validModelId(m)) return error.InvalidModelId;
        },
        .ollama => switch (mode) {
            .chat => {
                const m = model orelse return error.ModelRequired;
                if (!validModelId(m)) return error.InvalidModelId;
                // `ollama run` has no context / GPU / host flags.
                if (p.ctx != null or p.gpu_layers != null or p.port != null) return error.UnsupportedOption;
            },
            .server => {
                if (model != null) return error.ModelNotAllowed;
                if (p.gpu_layers != null) return error.UnsupportedOption;
            },
        },
    }
}

/// Build the launch plan. `model` is the exact installed backend identifier.
pub fn plan(arena: std.mem.Allocator, kind: backend.Kind, mode: Mode, model: ?[]const u8, p: Profile) Error!Plan {
    try validate(kind, mode, model, p);
    var argv: std.ArrayList([]const u8) = .empty;
    switch (kind) {
        .ollama => switch (mode) {
            .chat => {
                try argv.appendSlice(arena, &.{ "ollama", "run", "--", model.? });
                return .{ .argv = try argv.toOwnedSlice(arena) };
            },
            .server => {
                const port = p.port orelse default_ollama_port;
                var env: std.ArrayList([2][]const u8) = .empty;
                try env.append(arena, .{ "OLLAMA_HOST", try std.fmt.allocPrint(arena, "{s}:{d}", .{ bracket(arena, p.host) catch p.host, port }) });
                if (p.ctx) |c| try env.append(arena, .{ "OLLAMA_CONTEXT_LENGTH", try std.fmt.allocPrint(arena, "{d}", .{c}) });
                try argv.appendSlice(arena, &.{ "ollama", "serve" });
                return .{
                    .argv = try argv.toOwnedSlice(arena),
                    .env = try env.toOwnedSlice(arena),
                    .listen_host = p.host,
                    .listen_port = port,
                    .public_bind = !isLoopback(p.host),
                };
            },
        },
        .llama => {
            // --offline: launch only what is already cached, never download.
            try argv.appendSlice(arena, &.{ "llama", if (mode == .chat) "cli" else "serve", "--offline", "-hf", model.? });
            if (p.ctx) |c| try argv.appendSlice(arena, &.{ "-c", try std.fmt.allocPrint(arena, "{d}", .{c}) });
            if (p.gpu_layers) |g| try argv.appendSlice(arena, &.{ "-ngl", switch (g) {
                .auto => "auto",
                .all => "all",
                .count => |n| try std.fmt.allocPrint(arena, "{d}", .{n}),
            } });
            if (mode == .chat) {
                if (p.port != null) return error.UnsupportedOption;
                return .{ .argv = try argv.toOwnedSlice(arena) };
            }
            const port = p.port orelse default_llama_port;
            try argv.appendSlice(arena, &.{ "--host", p.host, "--port", try std.fmt.allocPrint(arena, "{d}", .{port}) });
            return .{
                .argv = try argv.toOwnedSlice(arena),
                .listen_host = p.host,
                .listen_port = port,
                .public_bind = !isLoopback(p.host),
            };
        },
    }
}

fn bracket(arena: std.mem.Allocator, h: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, h, ':') != null) return std.fmt.allocPrint(arena, "[{s}]", .{h});
    return h;
}

pub fn parseGpuLayers(s: []const u8) ?GpuLayers {
    if (std.mem.eql(u8, s, "auto")) return .auto;
    if (std.mem.eql(u8, s, "all")) return .all;
    return .{ .count = std.fmt.parseInt(u16, s, 10) catch return null };
}

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

test "llama chat argv" {
    var a = testArena();
    defer a.deinit();
    const pl = try plan(a.allocator(), .llama, .chat, "org/m-GGUF:Q4_K_M", .{ .ctx = 8192, .gpu_layers = .{ .count = 20 } });
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "llama", "cli", "--offline", "-hf", "org/m-GGUF:Q4_K_M", "-c", "8192", "-ngl", "20" }), pl.argv);
    try std.testing.expect(pl.listen_port == null);
}

test "llama server defaults to localhost and is not public" {
    var a = testArena();
    defer a.deinit();
    const pl = try plan(a.allocator(), .llama, .server, "org/m:Q8_0", .{});
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "llama", "serve", "--offline", "-hf", "org/m:Q8_0", "--host", "127.0.0.1", "--port", "9931" }), pl.argv);
    try std.testing.expect(!pl.public_bind);
}

test "public bind is flagged" {
    var a = testArena();
    defer a.deinit();
    try std.testing.expect((try plan(a.allocator(), .llama, .server, "m", .{ .host = "0.0.0.0" })).public_bind);
    try std.testing.expect((try plan(a.allocator(), .llama, .server, "m", .{ .host = "192.168.1.5" })).public_bind);
    try std.testing.expect(!(try plan(a.allocator(), .llama, .server, "m", .{ .host = "::1" })).public_bind);
}

test "ollama chat uses -- and rejects unsupported options" {
    var a = testArena();
    defer a.deinit();
    const pl = try plan(a.allocator(), .ollama, .chat, "qwen3.8:27b", .{});
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "ollama", "run", "--", "qwen3.8:27b" }), pl.argv);
    try std.testing.expectError(error.UnsupportedOption, plan(a.allocator(), .ollama, .chat, "x", .{ .ctx = 4096 }));
}

test "ollama server uses env, takes no model" {
    var a = testArena();
    defer a.deinit();
    const pl = try plan(a.allocator(), .ollama, .server, null, .{ .ctx = 8192 });
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "ollama", "serve" }), pl.argv);
    try std.testing.expectEqualStrings("127.0.0.1:11434", pl.env[0][1]);
    try std.testing.expectEqualStrings("8192", pl.env[1][1]);
    try std.testing.expectError(error.ModelNotAllowed, plan(a.allocator(), .ollama, .server, "x", .{}));
}

test "hostile identifiers and hosts are rejected" {
    var a = testArena();
    defer a.deinit();
    try std.testing.expectError(error.InvalidModelId, plan(a.allocator(), .llama, .chat, "--help", .{}));
    try std.testing.expectError(error.InvalidModelId, plan(a.allocator(), .llama, .chat, "a\nb", .{}));
    try std.testing.expectError(error.InvalidHost, plan(a.allocator(), .llama, .server, "m", .{ .host = "1.2.3.4,0.0.0.0" }));
    try std.testing.expectError(error.InvalidHost, plan(a.allocator(), .llama, .server, "m", .{ .host = "$(id)" }));
    try std.testing.expectError(error.InvalidPort, plan(a.allocator(), .llama, .server, "m", .{ .port = 0 }));
    try std.testing.expectError(error.ModelRequired, plan(a.allocator(), .llama, .chat, null, .{}));
}

test "metacharacters in a model id stay one argv element" {
    var a = testArena();
    defer a.deinit();
    const pl = try plan(a.allocator(), .ollama, .chat, "x;rm -rf ~ $(id)", .{});
    try std.testing.expectEqualStrings("x;rm -rf ~ $(id)", pl.argv[3]);
}
