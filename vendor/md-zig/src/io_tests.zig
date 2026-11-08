//! Tests of the std.Io.Reader / std.Io.Writer boundary: short reads, readers
//! that fail part-way, tiny reader buffers, and writers that fail part-way.

const std = @import("std");
const md = @import("root.zig");
const testing = std.testing;
const Io = std.Io;

const sample =
    \\# Title
    \\
    \\Some *emphasis*, **strong** text and a [link][ref] with `code`.
    \\
    \\> quote
    \\> more
    \\
    \\- one
    \\- two
    \\  1. nested
    \\
    \\```zig
    \\const x = 1;
    \\```
    \\
    \\[ref]: /url "Title"
    \\
;

/// A Reader over `data` with a buffer of `buf.len` bytes that hands out at most
/// `chunk` bytes per `stream` call, and fails once `fail_after` bytes were given.
const TrickleReader = struct {
    data: []const u8,
    pos: usize = 0,
    chunk: usize,
    fail_after: ?usize,
    buf: [64]u8 = undefined,
    interface: Io.Reader,

    fn setup(self: *TrickleReader, data: []const u8, buffer_len: usize, chunk: usize, fail_after: ?usize) void {
        self.* = .{ .data = data, .chunk = chunk, .fail_after = fail_after, .interface = undefined };
        self.interface = .{ .vtable = &.{ .stream = stream }, .buffer = self.buf[0..buffer_len], .seek = 0, .end = 0 };
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *TrickleReader = @fieldParentPtr("interface", r);
        if (self.fail_after) |n| if (self.pos >= n) return error.ReadFailed;
        if (self.pos >= self.data.len) return error.EndOfStream;
        var n = @min(self.chunk, self.data.len - self.pos);
        if (self.fail_after) |f| n = @min(n, f - self.pos);
        const give = @min(n, @backingInt(limit));
        try w.writeAll(self.data[self.pos..][0..give]);
        self.pos += give;
        return give;
    }
};

/// A Writer that accepts `limit` bytes in total, then fails. Its small buffer
/// exercises both the buffered and the `drain` paths.
const LimitedWriter = struct {
    out: std.ArrayList(u8) = .empty,
    limit: usize,
    buf: [8]u8 = undefined,
    interface: Io.Writer,

    fn setup(self: *LimitedWriter, limit: usize) void {
        self.* = .{ .limit = limit, .interface = undefined };
        self.interface = .{ .vtable = &.{ .drain = drain }, .buffer = &self.buf };
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *LimitedWriter = @fieldParentPtr("interface", w);
        try self.accept(w.buffered());
        w.end = 0;
        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            try self.accept(d);
            consumed += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| try self.accept(last);
        return consumed + last.len * splat;
    }

    fn accept(self: *LimitedWriter, bytes: []const u8) Io.Writer.Error!void {
        if (self.out.items.len + bytes.len > self.limit) return error.WriteFailed;
        self.out.appendSlice(testing.allocator, bytes) catch return error.WriteFailed;
    }
};

fn reference(gpa: std.mem.Allocator) ![]u8 {
    var doc = try md.Document.parse(gpa, sample, .{});
    defer doc.deinit();
    return doc.toHtmlAlloc(gpa);
}

test "parseReader gives the same result for every buffer and chunk size" {
    const gpa = testing.allocator;
    const want = try reference(gpa);
    defer gpa.free(want);

    for ([_]usize{ 1, 2, 3, 7, 64 }) |buffer_len| {
        for ([_]usize{ 1, 2, 5, 64 }) |chunk| {
            var tr: TrickleReader = undefined;
            tr.setup(sample, buffer_len, chunk, null);
            var doc = try md.Document.parseReader(gpa, &tr.interface, .{});
            defer doc.deinit();
            const got = try doc.toHtmlAlloc(gpa);
            defer gpa.free(got);
            try testing.expectEqualStrings(want, got);
        }
    }
}

test "a line longer than the reader's buffer is read whole" {
    const gpa = testing.allocator;
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(gpa);
    for (0..100) |_| try long.appendSlice(gpa, "word ");
    try long.append(gpa, '\n');
    var tr: TrickleReader = undefined;
    tr.setup(long.items, 4, 3, null);
    var doc = try md.Document.parseReader(gpa, &tr.interface, .{});
    defer doc.deinit();
    const got = try doc.toHtmlAlloc(gpa);
    defer gpa.free(got);
    try testing.expectEqualStrings("<p>", got[0..3]);
    try testing.expectEqual(@as(usize, 3 + 499 + 5), got.len);
}

test "parseReader reports ReadFailed wherever the reader dies, without leaking" {
    for (0..sample.len) |n| {
        var tr: TrickleReader = undefined;
        tr.setup(sample, 3, 3, n);
        try testing.expectError(error.ReadFailed, md.Document.parseReader(testing.allocator, &tr.interface, .{}));
    }
}

test "limits on size and line length" {
    var tr: TrickleReader = undefined;
    tr.setup(sample, 8, 1, null);
    try testing.expectError(error.InputTooLarge, md.Document.parseReader(testing.allocator, &tr.interface, .{ .max_bytes = 10 }));
    tr.setup(sample, 8, 1, null);
    try testing.expectError(error.LineTooLong, md.Document.parseReader(testing.allocator, &tr.interface, .{ .max_line_bytes = 10 }));
}

test "writeHtml is identical through a small-buffer writer" {
    const gpa = testing.allocator;
    const want = try reference(gpa);
    defer gpa.free(want);
    var doc = try md.Document.parse(gpa, sample, .{});
    defer doc.deinit();

    var lw: LimitedWriter = undefined;
    lw.setup(std.math.maxInt(usize));
    defer lw.out.deinit(gpa);
    try doc.writeHtml(gpa, &lw.interface);
    try lw.interface.flush();
    try testing.expectEqualStrings(want, lw.out.items);
}

test "writeHtml reports WriteFailed wherever the writer dies" {
    const gpa = testing.allocator;
    const full = try reference(gpa);
    defer gpa.free(full);
    var doc = try md.Document.parse(gpa, sample, .{});
    defer doc.deinit();

    for (0..full.len) |limit| {
        var lw: LimitedWriter = undefined;
        lw.setup(limit);
        defer lw.out.deinit(gpa);
        const result = doc.writeHtml(gpa, &lw.interface);
        const flushed = lw.interface.flush();
        try testing.expect(std.meta.isError(result) or std.meta.isError(flushed));
    }
}

test "line endings: CRLF, lone CR and a missing final newline" {
    const gpa = testing.allocator;
    for ([_][]const u8{ "a\r\nb\r\n", "a\rb\r", "a\nb", "a\r\nb" }) |src| {
        var doc = try md.Document.parse(gpa, src, .{});
        defer doc.deinit();
        const got = try doc.toHtmlAlloc(gpa);
        defer gpa.free(got);
        try testing.expectEqualStrings("<p>a\nb</p>\n", got);
    }
}

test "NUL becomes the replacement character" {
    const gpa = testing.allocator;
    var doc = try md.Document.parse(gpa, "a\x00b\n", .{});
    defer doc.deinit();
    const got = try doc.toHtmlAlloc(gpa);
    defer gpa.free(got);
    try testing.expectEqualStrings("<p>a\u{fffd}b</p>\n", got);
}

test "deeply nested input does not overflow the stack" {
    const gpa = testing.allocator;
    const depth = 20000;
    const src = try gpa.alloc(u8, depth + 2);
    defer gpa.free(src);
    @memset(src[0..depth], '>');
    src[depth] = 'x';
    src[depth + 1] = '\n';
    var doc = try md.Document.parse(gpa, src, .{});
    defer doc.deinit();
    const got = try doc.toHtmlAlloc(gpa);
    defer gpa.free(got);
    try testing.expect(got.len > depth);
}
