//! The TOML data model: values, tables, arrays and datetimes.
//!
//! Ownership: every `Value`, `Table` and `Array` reachable from a `Document`
//! lives in that document's arena. Nothing here is freed individually.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Date = struct {
    year: u16,
    month: u8,
    day: u8,
};

pub const Time = struct {
    hour: u8,
    minute: u8,
    second: u8,
    nanosecond: u32 = 0,
};

/// One of the four TOML datetime forms, distinguished by which fields are set:
/// offset date-time (date, time, offset), local date-time (date, time),
/// local date (date) and local time (time).
pub const Datetime = struct {
    date: ?Date = null,
    time: ?Time = null,
    /// Minutes east of UTC. `0` means "Z" or "+00:00". Only set with date and time.
    offset_minutes: ?i16 = null,

    pub fn format(self: Datetime, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.date) |d| try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day });
        if (self.date != null and self.time != null) try w.writeByte('T');
        if (self.time) |t| {
            try w.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ t.hour, t.minute, t.second });
            if (t.nanosecond != 0) {
                var buf: [9]u8 = undefined;
                _ = std.fmt.bufPrint(&buf, "{d:0>9}", .{t.nanosecond}) catch unreachable;
                var n: usize = 9;
                while (buf[n - 1] == '0') n -= 1;
                try w.print(".{s}", .{buf[0..n]});
            }
        }
        if (self.offset_minutes) |off| {
            if (off == 0) {
                try w.writeByte('Z');
            } else {
                const abs: u16 = @abs(off);
                try w.print("{c}{d:0>2}:{d:0>2}", .{ @as(u8, if (off < 0) '-' else '+'), abs / 60, abs % 60 });
            }
        }
    }
};

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    datetime: Datetime,
    array: *Array,
    table: *Table,

    pub fn typeName(self: Value) []const u8 {
        return @tagName(self);
    }
};

/// How a table came to exist. This decides which later definitions are legal
/// (TOML 1.0.0, "Table" and "Inline Table" sections).
pub const TableKind = enum {
    /// Created only as the parent of a `[a.b.c]` header; may still be defined once.
    implicit,
    /// Defined by its own `[header]` or `[[header]]`, or created by the API.
    explicit,
    /// Created by a dotted key (`a.b = 1`); closed to `[header]` definitions.
    dotted,
    /// Written as `{ ... }`; fully closed once parsed.
    inline_table,
};

pub const Array = struct {
    items: std.ArrayList(Value) = .empty,
    /// True for an array created by `[[header]]`. Only such arrays may be
    /// extended by another `[[header]]`.
    is_table_array: bool = false,
};

pub const Table = struct {
    /// Insertion-ordered, so a document written back keeps its key order.
    entries: std.StringArrayHashMapUnmanaged(Value) = .empty,
    kind: TableKind = .explicit,

    pub fn count(self: *const Table) usize {
        return self.entries.count();
    }

    pub fn get(self: *const Table, key: []const u8) ?Value {
        return self.entries.get(key);
    }

    pub fn getPtr(self: *Table, key: []const u8) ?*Value {
        return self.entries.getPtr(key);
    }

    /// Returns the value only if it is a string.
    pub fn getString(self: *const Table, key: []const u8) ?[]const u8 {
        return switch (self.get(key) orelse return null) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn getInt(self: *const Table, key: []const u8) ?i64 {
        return switch (self.get(key) orelse return null) {
            .integer => |i| i,
            else => null,
        };
    }

    /// Returns a float, accepting an integer too (so `size = 12` works for a float key).
    pub fn getFloat(self: *const Table, key: []const u8) ?f64 {
        return switch (self.get(key) orelse return null) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => null,
        };
    }

    pub fn getBool(self: *const Table, key: []const u8) ?bool {
        return switch (self.get(key) orelse return null) {
            .boolean => |b| b,
            else => null,
        };
    }

    pub fn getTable(self: *const Table, key: []const u8) ?*Table {
        return switch (self.get(key) orelse return null) {
            .table => |t| t,
            else => null,
        };
    }

    pub fn getArray(self: *const Table, key: []const u8) ?*Array {
        return switch (self.get(key) orelse return null) {
            .array => |a| a,
            else => null,
        };
    }

    /// Looks up `a.b.c` style paths through nested tables. Segments are split
    /// on '.', so keys that contain a dot cannot be reached this way; use
    /// `get` for those.
    pub fn lookup(self: *const Table, path: []const u8) ?Value {
        var cur: *const Table = self;
        var it = std.mem.splitScalar(u8, path, '.');
        while (it.next()) |seg| {
            const v = cur.get(seg) orelse return null;
            if (it.peek() == null) return v;
            switch (v) {
                .table => |t| cur = t,
                else => return null,
            }
        }
        return null;
    }

    /// Sets `key`, replacing any existing value. `key` and any string/array/table
    /// storage in `value` must outlive the table (allocate from the document arena).
    pub fn put(self: *Table, arena: Allocator, key: []const u8, value: Value) Allocator.Error!void {
        const gop = try self.entries.getOrPut(arena, key);
        if (!gop.found_existing) gop.key_ptr.* = key;
        gop.value_ptr.* = value;
    }

    /// Removes `key`, keeping the order of the remaining entries.
    pub fn remove(self: *Table, key: []const u8) bool {
        return self.entries.orderedRemove(key);
    }
};
