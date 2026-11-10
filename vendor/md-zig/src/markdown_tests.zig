//! The Markdown writer: parse -> write -> parse must give the same HTML, for
//! every CommonMark and GFM example; plus checks on what is kept verbatim.

const std = @import("std");
const md = @import("root.zig");

const Example = struct { markdown: []const u8, html: []const u8, example: u32, section: []const u8 };

/// Parses `src`, writes it as Markdown, and returns the HTML of both trees.
fn roundTrip(gpa: std.mem.Allocator, src: []const u8, ext: md.Extensions) !struct { before: []u8, after: []u8, text: []u8 } {
    var doc = try md.Document.parse(gpa, src, .{ .extensions = ext });
    defer doc.deinit();
    const before = try doc.toHtmlAlloc(gpa);
    errdefer gpa.free(before);
    const text = try doc.toMarkdownAlloc(gpa);
    errdefer gpa.free(text);
    var doc2 = try md.Document.parse(gpa, text, .{ .extensions = ext });
    defer doc2.deinit();
    const after = try doc2.toHtmlAlloc(gpa);
    return .{ .before = before, .after = after, .text = text };
}

fn run(comptime json: []const u8, ext: md.Extensions, name: []const u8, allowed_failures: usize) !void {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice([]Example, gpa, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var failed: usize = 0;
    for (parsed.value) |ex| {
        if (std.mem.eql(u8, ex.html, "<IGNORE>\n")) continue;
        const r = try roundTrip(gpa, ex.markdown, ext);
        defer gpa.free(r.before);
        defer gpa.free(r.after);
        defer gpa.free(r.text);
        if (!std.mem.eql(u8, r.before, r.after)) {
            failed += 1;
            std.debug.print("{s} example {d} ({s}) changes\n--- markdown\n{s}--- written\n{s}--- html before\n{s}--- html after\n{s}\n", .{ name, ex.example, ex.section, ex.markdown, r.text, r.before, r.after });
        }
    }
    std.debug.print("{s}: {d} of {d} examples round-trip\n", .{ name, parsed.value.len - failed, parsed.value.len });
    try std.testing.expect(failed <= allowed_failures);
}

test "writer round trip: CommonMark 0.31.2 examples" {
    try run(@embedFile("spec-0.31.2.json"), .{}, "spec", 0);
}

test "writer round trip: GFM and footnote examples" {
    try run(@embedFile("gfm-extensions.json"), md.Extensions.all, "gfm", 0);
}

fn written(src: []const u8, ext: md.Extensions) ![]u8 {
    var doc = try md.Document.parse(std.testing.allocator, src, .{ .extensions = ext });
    defer doc.deinit();
    return doc.toMarkdownAlloc(std.testing.allocator);
}

test "HTML comments are written back exactly" {
    const src =
        \\# Title
        \\
        \\<!-- a block comment
        \\     spanning lines -->
        \\
        \\Some *text* <!-- inline note --> after.
        \\
    ;
    const out = try written(src, .{});
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "<!-- a block comment\n     spanning lines -->\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<!-- inline note -->") != null);
}

test "front matter is written back unchanged" {
    const out = try written("---\ntitle: x\n# yaml comment\n---\n# Hi\n", .{ .front_matter = true });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("---\ntitle: x\n# yaml comment\n---\n\n# Hi\n", out);
}

test "definition lists round trip" {
    const gpa = std.testing.allocator;
    const srcs = [_][]const u8{
        "Term\n: Definition\n",
        "Term\n: One\n: Two\n\nOther\n: Three\n",
        "Term\n: One\n\n: Two\n",
    };
    for (srcs) |src| {
        const r = try roundTrip(gpa, src, md.Extensions.all);
        defer gpa.free(r.before);
        defer gpa.free(r.after);
        defer gpa.free(r.text);
        if (!std.mem.eql(u8, r.before, r.after)) std.debug.print("deflist changes\n{s}--- written\n{s}--- {s}--- {s}\n", .{ src, r.text, r.before, r.after });
        try std.testing.expectEqualStrings(r.before, r.after);
    }
}

test "text that looks like markup is escaped" {
    const gpa = std.testing.allocator;
    const srcs = [_][]const u8{
        "\\# not a heading\n",
        "1\\. not a list\n",
        "\\- not a bullet\n",
        "a \\*star\\* and snake_case and \\_under\\_\n",
        "\\[not a link\\](x) and &amp;amp; and \\<b>\n",
        "x\n\\> not a quote\n",
        "| a | b |\n| - | - |\n| \\| | 2 |\n",
    };
    for (srcs) |src| {
        const r = try roundTrip(gpa, src, md.Extensions.gfm);
        defer gpa.free(r.before);
        defer gpa.free(r.after);
        defer gpa.free(r.text);
        if (!std.mem.eql(u8, r.before, r.after)) std.debug.print("changes\n{s}--- written\n{s}--- {s}--- {s}\n", .{ src, r.text, r.before, r.after });
        try std.testing.expectEqualStrings(r.before, r.after);
    }
}

test "nesting that is too deep fails cleanly" {
    const gpa = std.testing.allocator;
    const src = try gpa.alloc(u8, 2000);
    defer gpa.free(src);
    @memset(src, '>');
    src[src.len - 1] = 'x';
    var doc = try md.Document.parse(gpa, src, .{});
    defer doc.deinit();
    try std.testing.expectError(error.TooDeep, doc.toMarkdownAlloc(gpa));
}
