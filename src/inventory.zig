//! Discovery: probe + list each backend independently. Failures are kept per
//! backend and never hide the other backend's models. Duplicates across
//! backends are kept distinct (backend + exact ID).
const std = @import("std");
const backend = @import("backend.zig");
const ollama = @import("backends/ollama.zig");
const llama = @import("backends/llama.zig");

pub const BackendReport = struct {
    kind: backend.Kind,
    probe: backend.ProbeStatus,
    /// Null when the backend is unavailable or listing failed.
    models: ?[]backend.Model = null,
    list_error: ?backend.ListError = null,
};

pub const Inventory = struct {
    reports: [2]BackendReport,
};

pub fn discover(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io) Inventory {
    return .{ .reports = .{
        scan(.ollama, ollama, arena, gpa, io),
        scan(.llama, llama, arena, gpa, io),
    } };
}

fn scan(kind: backend.Kind, comptime B: type, arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io) BackendReport {
    var rep: BackendReport = .{ .kind = kind, .probe = B.probe(arena, gpa, io) };
    if (rep.probe != .available) return rep;
    if (B.list(arena, gpa, io)) |m| {
        rep.models = m;
    } else |e| rep.list_error = e;
    return rep;
}

pub fn listErrorText(e: backend.ListError) []const u8 {
    return switch (e) {
        error.BackendMissing => "executable not found",
        error.BackendFailed => "command failed",
        error.UnsupportedFormat => "output format not recognized for this version (refusing to guess)",
        error.OutOfMemory => "out of memory",
    };
}
