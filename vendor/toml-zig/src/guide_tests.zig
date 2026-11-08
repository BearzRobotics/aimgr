//! Keeps docs/writing-toml.md honest: every ```toml block in it must parse.
//! Built as its own test module (see build.zig) because the guide lives
//! outside src/ and is handed in as an anonymous import.

const std = @import("std");
const toml = @import("toml");
const testing = std.testing;

const guide = @embedFile("writing-toml.md");

fn parses(version: toml.Version, src: []const u8) bool {
    var diag: toml.Diagnostic = .{};
    var doc = toml.Document.parse(testing.allocator, src, .{ .version = version }, &diag) catch {
        // A 1.0 rejection is expected for the one 1.1-only block; say nothing.
        if (version == .v1_1) std.debug.print("{f}\n---\n{s}\n---\n", .{ diag, src });
        return false;
    };
    doc.deinit();
    return true;
}

test "every toml block in the guide parses; only the 1.1-only block fails under 1.0" {
    var it = std.mem.splitSequence(u8, guide, "```toml\n");
    _ = it.next(); // text before the first block
    var blocks: usize = 0;
    var only11: usize = 0;
    while (it.next()) |rest| {
        const end = std.mem.indexOf(u8, rest, "```") orelse return error.UnterminatedBlock;
        const block = rest[0..end];
        blocks += 1;
        try testing.expect(parses(.v1_1, block));
        if (!parses(.v1_0, block)) {
            only11 += 1;
            try testing.expect(std.mem.indexOf(u8, block, "bg = ") != null);
        }
    }
    try testing.expect(blocks >= 8);
    try testing.expectEqual(@as(usize, 1), only11);
}
