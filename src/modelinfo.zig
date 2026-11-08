//! Facts about an installed Ollama model, parsed from `ollama show <id>` (0.40.15 layout):
//!
//!   Model
//!     architecture        gemma4
//!     parameters          11.9B
//!     context length      262144
//!     quantization        Q4_K_M
//!   Capabilities
//!     completion
//!     tools
//!     thinking
//!         levels     false, true
//!
//! This is what the backend itself reports (authoritative), unlike the catalog's derived hints.
//! Unknown layouts simply yield fewer fields; nothing is guessed.
const std = @import("std");
const process = @import("process.zig");

pub const Info = struct {
    architecture: ?[]const u8 = null,
    /// As printed, e.g. "11.9B".
    parameters: ?[]const u8 = null,
    context_length: ?u64 = null,
    quantization: ?[]const u8 = null,
    /// Capability names exactly as reported: completion, tools, vision, thinking, audio, embedding, ...
    caps: []const []const u8 = &.{},

    pub fn hasCap(self: Info, name: []const u8) bool {
        for (self.caps) |c| if (std.mem.eql(u8, c, name)) return true;
        return false;
    }

    /// Billions of parameters from text like "11.9B", "494M", "1.2T".
    pub fn paramsB(self: Info) ?f64 {
        const t = self.parameters orelse return null;
        if (t.len < 2) return null;
        const v = std.fmt.parseFloat(f64, t[0 .. t.len - 1]) catch return null;
        return switch (std.ascii.toUpper(t[t.len - 1])) {
            'B' => v,
            'M' => v / 1000.0,
            'K' => v / 1_000_000.0,
            'T' => v * 1000.0,
            else => null,
        };
    }
};

fn indentOf(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') n += 1;
    return n;
}

pub fn parseShow(arena: std.mem.Allocator, text: []const u8) !Info {
    var info: Info = .{};
    var caps: std.ArrayList([]const u8) = .empty;
    const Section = enum { none, model, capabilities, other };
    var section: Section = .none;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \r\t");
        if (line.len == 0) continue;
        const ind = indentOf(line);
        const body = line[ind..];
        if (ind <= 2) {
            section = if (std.mem.eql(u8, body, "Model")) .model else if (std.mem.eql(u8, body, "Capabilities")) .capabilities else .other;
            continue;
        }
        if (ind > 4) continue; // sub-attributes such as "levels"
        switch (section) {
            .model => {
                const gap = std.mem.indexOf(u8, body, "  ") orelse continue;
                const key = body[0..gap];
                const val = std.mem.trim(u8, body[gap..], " ");
                if (val.len == 0) continue;
                if (std.mem.eql(u8, key, "architecture")) info.architecture = try arena.dupe(u8, val) else if (std.mem.eql(u8, key, "parameters")) info.parameters = try arena.dupe(u8, val) else if (std.mem.eql(u8, key, "quantization")) info.quantization = try arena.dupe(u8, val) else if (std.mem.eql(u8, key, "context length")) info.context_length = std.fmt.parseInt(u64, val, 10) catch null;
            },
            .capabilities => {
                var tok = std.mem.tokenizeScalar(u8, body, ' ');
                const name = tok.next() orelse continue;
                if (name.len > 40) continue;
                try caps.append(arena, try arena.dupe(u8, name));
            },
            else => {},
        }
    }
    info.caps = try caps.toOwnedSlice(arena);
    return info;
}

/// Runs `ollama show <id>` (argv only, 10 s limit). Null if it fails or prints nothing usable.
pub fn fetchOllama(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, id: []const u8) ?Info {
    const r = process.run(gpa, io, &.{ "ollama", "show", id }, 10);
    defer r.deinit(gpa);
    if (!r.ok()) return null;
    const info = parseShow(arena, r.stdout) catch return null;
    if (info.caps.len == 0 and info.architecture == null) return null;
    return info;
}

test "parse real ollama show output" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const text =
        "  Model\n    architecture        gemma4             \n    parameters          11.9B              \n" ++
        "    context length      262144             \n    embedding length    3840               \n" ++
        "    quantization        Q4_K_M             \n    requires            0.30.9             \n\n" ++
        "  Capabilities\n    completion     \n    vision         \n    audio          \n    tools          \n" ++
        "    thinking       \n        levels     false, true    \n        default    true           \n\n" ++
        "  Parameters\n    temperature    1    \n\n  License\n    Apache License\n";
    const i = try parseShow(a.allocator(), text);
    try std.testing.expectEqualStrings("gemma4", i.architecture.?);
    try std.testing.expectEqualStrings("11.9B", i.parameters.?);
    try std.testing.expectEqual(@as(?u64, 262144), i.context_length);
    try std.testing.expectEqualStrings("Q4_K_M", i.quantization.?);
    try std.testing.expectEqual(@as(usize, 5), i.caps.len);
    try std.testing.expect(i.hasCap("tools") and i.hasCap("vision") and i.hasCap("thinking"));
    try std.testing.expect(!i.hasCap("levels")); // sub-attribute, not a capability
    try std.testing.expectApproxEqAbs(@as(f64, 11.9), i.paramsB().?, 1e-9);
}

test "capabilities only (small model) and junk" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const i = try parseShow(a.allocator(), "  Capabilities\n    tools         \n    completion    \n");
    try std.testing.expect(i.hasCap("tools"));
    try std.testing.expect(i.architecture == null);
    const j = try parseShow(a.allocator(), "garbage\n\x00\x01 text\n");
    try std.testing.expectEqual(@as(usize, 0), j.caps.len);
    try std.testing.expect(j.paramsB() == null);
    const m: Info = .{ .parameters = "494M" };
    try std.testing.expectApproxEqAbs(@as(f64, 0.494), m.paramsB().?, 1e-9);
}
