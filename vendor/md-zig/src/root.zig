//! md-zig: a Markdown parser and renderer for Zig, built on `std.Io`.
//!
//! Dialect: CommonMark 0.31.2 (https://spec.commonmark.org/0.31.2/). Input is
//! read line by line from a `std.Io.Reader`; output is written to a
//! `std.Io.Writer`. Nothing here touches the file system or the OS.
//!
//!     var doc = try md.Document.parse(gpa, "# Hello *world*\n", .{});
//!     defer doc.deinit();
//!     try doc.writeHtml(writer);

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const ast = @import("ast.zig");
pub const Node = ast.Node;
pub const Kind = ast.Kind;
pub const ListKind = ast.ListKind;
pub const ListData = ast.ListData;
pub const Walker = ast.Walker;
pub const Event = ast.Event;
pub const html = @import("html.zig");
pub const term = @import("term.zig");
pub const TextOptions = term.TextOptions;
const block = @import("block.zig");

pub const Options = @import("options.zig").Options;
pub const Extensions = @import("options.zig").Extensions;

pub const ParseError = error{
    OutOfMemory,
    /// The reader failed; see the reader's own error for the cause.
    ReadFailed,
    /// A line is longer than `Options.max_line_bytes`.
    LineTooLong,
    /// The input is longer than `Options.max_bytes`.
    InputTooLarge,
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root: *Node,
    extensions: Extensions = .{},
    footnotes: html.Footnotes = .empty,

    /// Parses a complete text.
    pub fn parse(gpa: Allocator, source: []const u8, options: Options) ParseError!Document {
        var r: Io.Reader = .fixed(source);
        return parseReader(gpa, &r, options);
    }

    /// Parses from a reader, one line at a time. The tree is owned by the
    /// returned document and freed by `deinit`.
    pub fn parseReader(gpa: Allocator, r: *Io.Reader, options: Options) ParseError!Document {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        var parser = try block.Parser.init(arena.allocator(), options.extensions);

        var line: Io.Writer.Allocating = .init(gpa);
        defer line.deinit();
        var total: usize = 0;
        while (true) {
            line.writer.end = 0;
            _ = r.streamDelimiterLimit(&line.writer, '\n', .limited(options.max_line_bytes)) catch |err| switch (err) {
                error.StreamTooLong => return error.LineTooLong,
                error.WriteFailed => return error.OutOfMemory,
                error.ReadFailed => return error.ReadFailed,
            };
            // The line ended at a newline, or the input ended.
            const have_newline = if (r.peekByte()) |b| b == '\n' else |err| switch (err) {
                error.EndOfStream => false,
                error.ReadFailed => return error.ReadFailed,
            };
            if (have_newline) r.toss(1);
            const text = line.written();
            if (!have_newline and text.len == 0) break;

            total += text.len + 1;
            if (total > options.max_bytes) return error.InputTooLarge;
            try feedLine(&parser, arena.allocator(), text);
            if (!have_newline) break;
        }
        try parser.finish();
        return .{ .arena = arena, .root = parser.doc, .extensions = options.extensions, .footnotes = parser.footnotes };
    }

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Writes the document as HTML.
    pub fn writeHtml(self: *const Document, gpa: Allocator, w: *Io.Writer) html.Error!void {
        try html.write(gpa, self.root, &self.footnotes, self.extensions, w);
    }

    /// Writes the document as text for a terminal (see `TextOptions`).
    pub fn writeText(self: *const Document, gpa: Allocator, w: *Io.Writer, options: TextOptions) term.Error!void {
        try term.write(gpa, self.root, &self.footnotes, options, w);
    }

    /// The document as terminal text in memory, owned by the caller.
    pub fn toTextAlloc(self: *const Document, gpa: Allocator, options: TextOptions) Allocator.Error![]u8 {
        var out: Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        self.writeText(gpa, &out.writer, options) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }

    /// The document as HTML in memory, owned by the caller.
    pub fn toHtmlAlloc(self: *const Document, gpa: Allocator) Allocator.Error![]u8 {
        var out: Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        self.writeHtml(gpa, &out.writer) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }
};

/// Hands one line (no line terminator) to the block parser. A trailing `\r`
/// is dropped, a lone `\r` also ends a line, and NUL becomes U+FFFD.
fn feedLine(parser: *block.Parser, a: Allocator, raw: []const u8) Allocator.Error!void {
    var text = raw;
    if (text.len > 0 and text[text.len - 1] == '\r') text = text[0 .. text.len - 1];
    var parts = std.mem.splitScalar(u8, text, '\r');
    while (parts.next()) |part| {
        if (std.mem.findScalar(u8, part, 0) != null) {
            var fixed: std.ArrayList(u8) = .empty;
            for (part) |c| {
                if (c == 0) try fixed.appendSlice(a, "\u{fffd}") else try fixed.append(a, c);
            }
            try parser.feed(fixed.items);
        } else {
            try parser.feed(part);
        }
    }
}

test {
    _ = @import("text.zig");
    _ = @import("scan.zig");
    _ = @import("tests.zig");
    _ = @import("io_tests.zig");
    _ = @import("term_tests.zig");
}
