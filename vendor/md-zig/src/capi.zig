//! Optional C interface (see include/md.h). EXPERIMENTAL: no stability promise.
//!
//! This file only adapts the native API (`md`) to C types. The native API does
//! not depend on it. Allocation uses `std.heap.smp_allocator`, so the C side
//! needs no allocator and no libc.

const std = @import("std");
const md = @import("md");

const gpa = std.heap.smp_allocator;

const ok = 0;
const err_invalid_argument = 1;
const err_out_of_memory = 2;
const err_input_too_large = 3;
const err_line_too_long = 4;
const err_read_failed = 5;

const ext_bits = [_]struct { u32, []const u8 }{
    .{ 1 << 0, "tables" },
    .{ 1 << 1, "strikethrough" },
    .{ 1 << 2, "task_lists" },
    .{ 1 << 3, "autolinks" },
    .{ 1 << 4, "tagfilter" },
    .{ 1 << 5, "footnotes" },
    .{ 1 << 6, "front_matter" },
    .{ 1 << 7, "definition_lists" },
};

fn extensionsFromFlags(flags: u32) md.Extensions {
    var e: md.Extensions = .{};
    inline for (ext_bits) |b| {
        if (flags & b[0] != 0) @field(e, b[1]) = true;
    }
    return e;
}

/// What the C side sees as `md_document*`.
const Handle = struct { doc: md.Document };

export fn md_version() [*:0]const u8 {
    return "0.3.0";
}

export fn md_parse(src: ?[*]const u8, len: usize, extensions: u32, out: ?*?*Handle) c_int {
    const o = out orelse return err_invalid_argument;
    o.* = null;
    if (src == null and len != 0) return err_invalid_argument;
    const bytes: []const u8 = if (src) |p| p[0..len] else "";

    const handle = gpa.create(Handle) catch return err_out_of_memory;
    handle.doc = md.Document.parse(gpa, bytes, .{ .extensions = extensionsFromFlags(extensions) }) catch |e| {
        gpa.destroy(handle);
        return switch (e) {
            error.OutOfMemory => err_out_of_memory,
            error.InputTooLarge => err_input_too_large,
            error.LineTooLong => err_line_too_long,
            error.ReadFailed => err_read_failed,
        };
    };
    o.* = handle;
    return ok;
}

export fn md_free(doc: ?*Handle) void {
    const h = doc orelse return;
    h.doc.deinit();
    gpa.destroy(h);
}

fn give(result: []u8, out: *?[*]u8, out_len: *usize) c_int {
    out.* = result.ptr;
    out_len.* = result.len;
    return ok;
}

export fn md_to_html(doc: ?*const Handle, out: ?*?[*]u8, out_len: ?*usize) c_int {
    const o = out orelse return err_invalid_argument;
    const l = out_len orelse return err_invalid_argument;
    o.* = null;
    l.* = 0;
    const h = doc orelse return err_invalid_argument;
    const s = h.doc.toHtmlAlloc(gpa) catch return err_out_of_memory;
    return give(s, o, l);
}

export fn md_to_text(doc: ?*const Handle, width: usize, color: c_int, out: ?*?[*]u8, out_len: ?*usize) c_int {
    const o = out orelse return err_invalid_argument;
    const l = out_len orelse return err_invalid_argument;
    o.* = null;
    l.* = 0;
    const h = doc orelse return err_invalid_argument;
    const s = h.doc.toTextAlloc(gpa, .{ .width = width, .color = color != 0 }) catch return err_out_of_memory;
    return give(s, o, l);
}

export fn md_free_string(ptr: ?[*]u8, len: usize) void {
    const p = ptr orelse return;
    gpa.free(p[0..len]);
}
