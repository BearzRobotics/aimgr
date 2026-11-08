//! Serializes a table tree back to TOML text.
//!
//! Output is deterministic: keys appear in insertion order, scalar keys before
//! sub-tables. Comments and original formatting are NOT preserved (the data
//! model does not store them); unknown keys are preserved because the whole
//! tree is.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value = @import("value.zig");
const Value = value.Value;
const Table = value.Table;
const Writer = std.Io.Writer;

pub const Error = Writer.Error || Allocator.Error;

pub fn writeTable(gpa: Allocator, w: *Writer, root: *const Table) Error!void {
    var path: std.ArrayList([]const u8) = .empty;
    defer path.deinit(gpa);
    var first = true;
    try emit(gpa, w, root, &path, false, &first);
}

/// Can `t` be written as a `[header]` section? Inline tables, and anything
/// nested inside a static array, are written inline instead.
fn isSection(v: Value) bool {
    return switch (v) {
        .table => |t| t.kind != .inline_table,
        .array => |a| a.is_table_array and a.items.items.len > 0,
        else => false,
    };
}

fn emit(gpa: Allocator, w: *Writer, t: *const Table, path: *std.ArrayList([]const u8), is_array_elem: bool, first: *bool) Error!void {
    _ = is_array_elem;
    const keys = t.entries.keys();
    const vals = t.entries.values();
    for (keys, vals) |k, v| {
        if (isSection(v)) continue;
        try writeKey(w, k);
        try w.writeAll(" = ");
        try writeInline(w, v);
        try w.writeByte('\n');
        first.* = false;
    }
    for (keys, vals) |k, v| {
        if (!isSection(v)) continue;
        try path.append(gpa, k);
        defer _ = path.pop();
        switch (v) {
            .table => |sub| {
                // An implicit parent with only sub-tables needs no header of its own.
                if (!onlySections(sub)) {
                    try header(w, path.items, false, first);
                }
                try emit(gpa, w, sub, path, false, first);
            },
            .array => |a| for (a.items.items) |item| {
                try header(w, path.items, true, first);
                try emit(gpa, w, item.table, path, true, first);
            },
            else => unreachable,
        }
    }
}

fn onlySections(t: *const Table) bool {
    if (t.kind != .implicit) return false;
    for (t.entries.values()) |v| if (!isSection(v)) return false;
    return true;
}

fn header(w: *Writer, path: []const []const u8, array: bool, first: *bool) Writer.Error!void {
    if (!first.*) try w.writeByte('\n');
    first.* = false;
    try w.writeAll(if (array) "[[" else "[");
    for (path, 0..) |seg, i| {
        if (i != 0) try w.writeByte('.');
        try writeKey(w, seg);
    }
    try w.writeAll(if (array) "]]\n" else "]\n");
}

pub fn writeKey(w: *Writer, key: []const u8) Writer.Error!void {
    var bare = key.len != 0;
    for (key) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) bare = false;
    }
    if (bare) try w.writeAll(key) else try writeString(w, key);
}

pub fn writeString(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0C => try w.writeAll("\\f"),
            0...0x07, 0x0B, 0x0E...0x1F, 0x7F => try w.print("\\u{X:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

fn writeInline(w: *Writer, v: Value) Writer.Error!void {
    switch (v) {
        .string => |s| try writeString(w, s),
        .integer => |i| try w.print("{d}", .{i}),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .datetime => |d| try d.format(w),
        .float => |f| try writeFloat(w, f),
        .array => |a| {
            try w.writeByte('[');
            for (a.items.items, 0..) |item, i| {
                if (i != 0) try w.writeAll(", ");
                try writeInline(w, item);
            }
            try w.writeByte(']');
        },
        .table => |t| {
            if (t.count() == 0) return w.writeAll("{}");
            try w.writeAll("{ ");
            for (t.entries.keys(), t.entries.values(), 0..) |k, sub, i| {
                if (i != 0) try w.writeAll(", ");
                try writeKey(w, k);
                try w.writeAll(" = ");
                try writeInline(w, sub);
            }
            try w.writeAll(" }");
        },
    }
}

fn writeFloat(w: *Writer, f: f64) Writer.Error!void {
    if (std.math.isNan(f)) return w.writeAll("nan");
    if (std.math.isInf(f)) return w.writeAll(if (f < 0) "-inf" else "inf");
    // Shortest representation that round-trips; TOML requires a '.' or exponent.
    var buf: [64]u8 = undefined;
    // {d} would print 300+ digits for 1e300, so use exponent form at the extremes.
    const abs = @abs(f);
    const s = if (abs != 0 and (abs >= 1e16 or abs < 1e-4))
        std.fmt.bufPrint(&buf, "{e}", .{f}) catch unreachable
    else
        std.fmt.bufPrint(&buf, "{d}", .{f}) catch unreachable;
    try w.writeAll(s);
    if (std.mem.indexOfAny(u8, s, ".eE") == null) try w.writeAll(".0");
}
