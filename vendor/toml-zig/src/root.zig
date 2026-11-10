//! toml-zig: a TOML 1.0.0 parser and writer.
//!
//! ```zig
//! var diag: toml.Diagnostic = .{};
//! var doc = toml.Document.parse(gpa, source, .{}, &diag) catch |e| {
//!     std.log.err("config: {f}: {s}", .{ diag, @errorName(e) });
//!     return e;
//! };
//! defer doc.deinit();
//! const pos = doc.root.lookup("panel.position");
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Value = @import("value.zig").Value;
pub const Table = @import("value.zig").Table;
pub const TableKind = @import("value.zig").TableKind;
pub const Array = @import("value.zig").Array;
pub const Comments = @import("value.zig").Comments;
pub const Datetime = @import("value.zig").Datetime;
pub const Date = @import("value.zig").Date;
pub const Time = @import("value.zig").Time;
pub const ParseError = @import("parser.zig").Error;
pub const Options = @import("parser.zig").Options;
pub const Version = @import("parser.zig").Version;
pub const Diagnostic = @import("parser.zig").Diagnostic;
pub const ParseReaderError = ParseError || error{ReadFailed};
pub const WriteError = @import("writer.zig").Error;

/// A parsed document. Owns an arena holding every string, table and array
/// reachable from `root`; `deinit` frees all of it at once.
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root: *Table,

    /// An empty document, for building one with the setters.
    pub fn init(gpa: Allocator) Allocator.Error!Document {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const root = try arena.allocator().create(Table);
        root.* = .{};
        return .{ .arena = arena, .root = root };
    }

    /// Parses `source` (UTF-8). `source` is not retained. On failure the
    /// optional `diag` receives a 1-based line and column.
    pub fn parse(gpa: Allocator, source: []const u8, options: Options, diag: ?*Diagnostic) ParseError!Document {
        var doc = try init(gpa);
        errdefer doc.deinit();
        var r: std.Io.Reader = .fixed(source);
        @import("parser.zig").parse(gpa, doc.arena.allocator(), doc.root, &r, options, diag) catch |e| switch (e) {
            error.ReadFailed => unreachable, // a fixed reader cannot fail
            else => |parse_err| return parse_err,
        };
        return doc;
    }

    /// Parses TOML read incrementally from `r`; the input is never held in
    /// memory as a whole. Fails with `error.LimitExceeded` once more than
    /// `options.max_bytes` have been consumed, and with `error.ReadFailed` if
    /// `r` does.
    pub fn parseReader(gpa: Allocator, r: *std.Io.Reader, options: Options, diag: ?*Diagnostic) ParseReaderError!Document {
        var doc = try init(gpa);
        errdefer doc.deinit();
        try @import("parser.zig").parse(gpa, doc.arena.allocator(), doc.root, r, options, diag);
        return doc;
    }

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The allocator that owns this document's contents; use it for any value
    /// passed to `Table.put`.
    pub fn allocator(self: *Document) Allocator {
        return self.arena.allocator();
    }

    /// Duplicates `s` into the document so it can be stored as a value or key.
    pub fn dupe(self: *Document, s: []const u8) Allocator.Error![]const u8 {
        return self.allocator().dupe(u8, s);
    }

    /// Sets `a.b.c = value`, creating intermediate tables. Fails with
    /// `error.NotATable` if a path segment already holds a non-table value.
    /// `value` must already be arena-owned (use `dupe` for strings).
    pub fn set(self: *Document, path: []const []const u8, v: Value) (Allocator.Error || error{NotATable})!void {
        std.debug.assert(path.len > 0);
        const a = self.allocator();
        var cur = self.root;
        for (path[0 .. path.len - 1]) |seg| {
            if (cur.getPtr(seg)) |existing| {
                switch (existing.*) {
                    .table => |t| cur = t,
                    else => return error.NotATable,
                }
            } else {
                const t = try a.create(Table);
                t.* = .{ .kind = .explicit };
                try cur.put(a, try self.dupe(seg), .{ .table = t });
                cur = t;
            }
        }
        try cur.put(a, try self.dupe(path[path.len - 1]), v);
    }

    /// Attaches comments to the item at `path`: its `key = value` line, or its
    /// `[header]` line if it is a table written as a section. For an array of
    /// tables, the header of its last element. Strings in `c` are copied. Fails
    /// with `error.NotFound` if there is no such item and `error.InvalidComment`
    /// if a line is not empty or `#...`.
    pub fn setComments(self: *Document, path: []const []const u8, c: Comments) (Allocator.Error || error{ NotFound, InvalidComment })!void {
        std.debug.assert(path.len > 0);
        try @import("value.zig").checkComments(c);
        var cur = self.root;
        for (path[0 .. path.len - 1]) |seg| {
            switch (cur.get(seg) orelse return error.NotFound) {
                .table => |t| cur = t,
                .array => |a| {
                    if (!a.is_table_array or a.items.items.len == 0) return error.NotFound;
                    cur = a.items.items[a.items.items.len - 1].table;
                },
                else => return error.NotFound,
            }
        }
        const last = path[path.len - 1];
        const a = self.allocator();
        const own: Comments = .{
            .before = blk: {
                const out = try a.alloc([]const u8, c.before.len);
                for (c.before, out) |l, *o| o.* = try a.dupe(u8, l);
                break :blk out;
            },
            .after = if (c.after) |x| try a.dupe(u8, x) else null,
        };
        const v = cur.get(last) orelse return error.NotFound;
        switch (v) {
            .table => |t| if (t.kind != .inline_table) {
                t.header = own;
                return;
            },
            .array => |arr| if (arr.is_table_array and arr.items.items.len > 0) {
                arr.items.items[arr.items.items.len - 1].table.header = own;
                return;
            },
            else => {},
        }
        try cur.setComments(a, last, own);
    }

    /// Writes the document as TOML. See `writer.zig` for what is preserved.
    pub fn write(self: *const Document, gpa: Allocator, w: *std.Io.Writer) WriteError!void {
        try @import("writer.zig").writeTable(gpa, w, self.root);
    }

    /// Returns the TOML text; caller frees with `gpa`.
    pub fn toOwnedString(self: *const Document, gpa: Allocator) WriteError![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        try self.write(gpa, &aw.writer);
        return aw.toOwnedSlice();
    }
};

test {
    _ = @import("tests.zig");
    _ = @import("io_tests.zig");
}
