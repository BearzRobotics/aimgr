//! Tests of the std.Io.Reader / std.Io.Writer boundary: short reads, reads
//! that fail part-way, tiny writer buffers and writers that fail part-way.
//! These are independent of how the parser consumes its input, so they must
//! keep passing across parser redesigns.

const std = @import("std");
const toml = @import("root.zig");
const testing = std.testing;
const Io = std.Io;

const sample =
    \\title = "café"
    \\n = [1, 2, { k = "v" }]
    \\when = 2026-11-06T12:34:56Z
    \\multi = """
    \\a "quoted" \
    \\   b"""
    \\[server.http]
    \\port = 8080
    \\[[server.users]]
    \\name = 'x'
    \\[[server.users]]
    \\name = 'y'
    \\
;

/// A Reader over `data` that hands out at most `chunk` bytes per `stream`
/// call and, if `fail_after` is set, fails once that many bytes were given.
pub const TrickleReader = struct {
    data: []const u8,
    pos: usize = 0,
    chunk: usize,
    fail_after: ?usize = null,
    interface: Io.Reader,

    pub fn init(data: []const u8, chunk: usize, fail_after: ?usize) TrickleReader {
        return .{
            .data = data,
            .chunk = chunk,
            .fail_after = fail_after,
            .interface = .{ .vtable = &.{ .stream = stream }, .buffer = &.{}, .seek = 0, .end = 0 },
        };
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

/// A Writer that accepts `limit` bytes in total, then fails. It has a small
/// buffer so that both the buffered and the `drain` paths are exercised.
const LimitedWriter = struct {
    out: std.ArrayList(u8) = .empty,
    limit: usize,
    buf: [8]u8 = undefined,
    interface: Io.Writer,

    /// In place, because `interface.buffer` points into `self`.
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

test "parseReader gives the same result for every chunk size" {
    const gpa = testing.allocator;
    var ref = try toml.Document.parse(gpa, sample, .{}, null);
    defer ref.deinit();
    const want = try ref.toOwnedString(gpa);
    defer gpa.free(want);

    for ([_]usize{ 1, 2, 3, 5, 7, 64, 4096 }) |chunk| {
        var tr = TrickleReader.init(sample, chunk, null);
        var doc = try toml.Document.parseReader(gpa, &tr.interface, .{}, null);
        defer doc.deinit();
        const got = try doc.toOwnedString(gpa);
        defer gpa.free(got);
        try testing.expectEqualStrings(want, got);
    }
}

test "parseReader reports ReadFailed wherever the reader dies, without leaking" {
    for (0..sample.len) |n| {
        var tr = TrickleReader.init(sample, 3, n);
        try testing.expectError(error.ReadFailed, toml.Document.parseReader(testing.allocator, &tr.interface, .{}, null));
    }
}

test "parseReader enforces max_bytes on a trickling reader" {
    var tr = TrickleReader.init(sample, 1, null);
    try testing.expectError(error.LimitExceeded, toml.Document.parseReader(testing.allocator, &tr.interface, .{ .max_bytes = 10 }, null));
}

test "write is identical through a small-buffer writer" {
    const gpa = testing.allocator;
    var doc = try toml.Document.parse(gpa, sample, .{}, null);
    defer doc.deinit();
    const want = try doc.toOwnedString(gpa);
    defer gpa.free(want);

    var lw: LimitedWriter = undefined;
    lw.setup(std.math.maxInt(usize));
    defer lw.out.deinit(gpa);
    try doc.write(gpa, &lw.interface);
    try lw.interface.flush();
    try testing.expectEqualStrings(want, lw.out.items);
}

test "write reports WriteFailed wherever the writer dies" {
    const gpa = testing.allocator;
    var doc = try toml.Document.parse(gpa, sample, .{}, null);
    defer doc.deinit();
    const full = try doc.toOwnedString(gpa);
    defer gpa.free(full);

    for (0..full.len) |limit| {
        var lw: LimitedWriter = undefined;
        lw.setup(limit);
        defer lw.out.deinit(gpa);
        const res = doc.write(gpa, &lw.interface);
        // Small outputs may sit in the buffer until flush, so failure can
        // surface from either call.
        const failed = if (res) |_| blk: {
            lw.interface.flush() catch break :blk true;
            break :blk false;
        } else |e| blk: {
            try testing.expectEqual(error.WriteFailed, e);
            break :blk true;
        };
        try testing.expect(failed);
    }
}

test "invalid UTF-8 is rejected, however the bytes arrive" {
    const bad = [_][]const u8{
        "a = \"\xff\"",
        "a = \"\xc0\x80\"", // overlong
        "a = \"\xed\xa0\x80\"", // surrogate
        "a = \"\xf4\x90\x80\x80\"", // above U+10FFFF
        "a = \"\xe2\x82\"", // truncated, then closing quote
        "a = 1 # \xe2\x82", // truncated at end of input
    };
    for (bad) |src| {
        for ([_]usize{ 1, 2, 4096 }) |chunk| {
            var tr = TrickleReader.init(src, chunk, null);
            try testing.expectError(error.InvalidUtf8, toml.Document.parseReader(testing.allocator, &tr.interface, .{}, null));
        }
        try testing.expectError(error.InvalidUtf8, toml.Document.parse(testing.allocator, src, .{}, null));
    }
}

test "valid multi-byte text and a BOM survive one-byte reads" {
    const gpa = testing.allocator;
    const src = "\xEF\xBB\xBFk = \"\\u00e9 \xc3\xa9 \xe2\x82\xac \xf0\x9f\x98\x80\"\n";
    var tr = TrickleReader.init(src, 1, null);
    var doc = try toml.Document.parseReader(gpa, &tr.interface, .{}, null);
    defer doc.deinit();
    try testing.expectEqualStrings("\xc3\xa9 \xc3\xa9 \xe2\x82\xac \xf0\x9f\x98\x80", doc.root.getString("k").?);
}

test "empty and tiny inputs" {
    for ([_][]const u8{ "", "\n", "a", "a=1", "#" }) |src| {
        var tr = TrickleReader.init(src, 1, null);
        const via_reader = toml.Document.parseReader(testing.allocator, &tr.interface, .{}, null);
        const via_slice = toml.Document.parse(testing.allocator, src, .{}, null);
        try testing.expectEqual(std.meta.isError(via_slice), std.meta.isError(via_reader));
        if (via_reader) |d| {
            var dd = d;
            dd.deinit();
        } else |_| {}
        if (via_slice) |d| {
            var dd = d;
            dd.deinit();
        } else |_| {}
    }
}
