//! Renders a tree as text for a terminal: word-wrapped paragraphs, indented
//! lists and quotes, aligned tables, and (optionally) ANSI colours.
//!
//! Without colour, emphasis is kept visible as Markdown-style markers so no
//! information is lost. Nesting deeper than `max_depth` containers is cut off.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const text = @import("text.zig");
const unicode = @import("unicode.zig");
const opts = @import("options.zig");
const Node = ast.Node;

pub const Error = Io.Writer.Error || Allocator.Error;

pub const TextOptions = struct {
    /// Columns to wrap at; 0 means do not wrap.
    width: usize = 80,
    /// Use ANSI escape sequences for styles. Without them, emphasis is shown
    /// with Markdown markers.
    color: bool = false,
    /// Draw rules, quote bars, bullets and table borders with Unicode line
    /// drawing characters; otherwise plain ASCII.
    unicode: bool = true,
    /// Show the address after the text of a link.
    show_urls: bool = true,
};

/// Containers nested deeper than this are not drawn.
pub const max_depth = 64;

const Style = struct {
    bold: u16 = 0,
    italic: u16 = 0,
    underline: u16 = 0,
    strike: u16 = 0,
    code: u16 = 0,
    link: u16 = 0,
    dim: u16 = 0,
};

const StyleField = enum { bold, italic, underline, strike, code, link, dim };

const Token = union(enum) {
    word: []const u8,
    space,
    hard_break,
    style: struct { field: StyleField, on: bool },
};

const Prefix = struct {
    /// Written on continuation lines.
    cont: []const u8,
    /// Written once instead of `cont`, on the next line.
    first: ?[]const u8 = null,
    /// Display width of `first` when it holds escape sequences.
    first_width: ?usize = null,

    fn width(self: Prefix) usize {
        if (self.first) |f| return self.first_width orelse unicode.stringWidth(f);
        return unicode.stringWidth(self.cont);
    }
};

const Used = struct { key: []const u8, def: *Node };

const Renderer = struct {
    w: *Io.Writer,
    a: Allocator,
    o: TextOptions,
    defs: *const std.StringHashMapUnmanaged(*Node),
    prefixes: std.ArrayList(Prefix) = .empty,
    style: Style = .{},
    need_blank: bool = false,
    started: bool = false,
    depth: usize = 0,
    used: std.ArrayList(Used) = .empty,
    used_index: std.StringHashMapUnmanaged(usize) = .empty,
    /// Narrowest width paragraphs are wrapped to (table cells go lower).
    min_width: usize = 20,

    // ---- low level -------------------------------------------------------------------

    fn prefixWidth(self: *const Renderer) usize {
        var n: usize = 0;
        for (self.prefixes.items) |p| n += p.width();
        return n;
    }

    fn available(self: *const Renderer) usize {
        if (self.o.width == 0) return std.math.maxInt(usize) / 2;
        const used = self.prefixWidth();
        return if (self.o.width > used + self.min_width) self.o.width - used else self.min_width;
    }

    fn writePrefix(self: *Renderer, trim: bool) Error!void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.a);
        for (self.prefixes.items) |*p| {
            try buf.appendSlice(self.a, p.first orelse p.cont);
            p.first = null;
        }
        const out = if (trim) std.mem.trimEnd(u8, buf.items, " ") else buf.items;
        try self.w.writeAll(out);
    }

    fn sgr(self: *Renderer) Error!void {
        if (!self.o.color) return;
        try self.w.writeAll("\x1b[0m");
        const s = self.style;
        if (s.bold > 0) try self.w.writeAll("\x1b[1m");
        if (s.dim > 0) try self.w.writeAll("\x1b[2m");
        if (s.italic > 0) try self.w.writeAll("\x1b[3m");
        if (s.underline > 0 or s.link > 0) try self.w.writeAll("\x1b[4m");
        if (s.strike > 0) try self.w.writeAll("\x1b[9m");
        if (s.code > 0) try self.w.writeAll("\x1b[36m");
        if (s.link > 0) try self.w.writeAll("\x1b[34m");
    }

    fn blankLine(self: *Renderer) Error!void {
        try self.writePrefix(true);
        try self.w.writeAll("\n");
    }

    /// Called before every block: a blank line separates it from the previous one.
    fn beginBlock(self: *Renderer) Error!void {
        if (self.need_blank and self.started) try self.blankLine();
        self.need_blank = false;
        self.started = true;
    }

    fn endBlock(self: *Renderer) void {
        self.need_blank = true;
    }

    // ---- inline text -------------------------------------------------------------------

    fn pushStyle(self: *Renderer, tokens: *std.ArrayList(Token), field: StyleField, on: bool, marker: []const u8) Allocator.Error!void {
        if (self.o.color) {
            try tokens.append(self.a, .{ .style = .{ .field = field, .on = on } });
        } else if (marker.len > 0) {
            // Markers touch the word next to them.
            try tokens.append(self.a, .{ .word = marker });
        }
    }

    fn addText(self: *Renderer, tokens: *std.ArrayList(Token), s: []const u8) Allocator.Error!void {
        var i: usize = 0;
        while (i < s.len) {
            if (text.isWhitespace(s[i])) {
                try tokens.append(self.a, .space);
                while (i < s.len and text.isWhitespace(s[i])) i += 1;
            } else {
                const start = i;
                while (i < s.len and !text.isWhitespace(s[i])) i += 1;
                try tokens.append(self.a, .{ .word = s[start..i] });
            }
        }
    }

    fn plain(self: *Renderer, n: *Node, out: *std.ArrayList(u8)) Allocator.Error!void {
        var walker = ast.Walker.init(n);
        while (walker.next()) |ev| {
            if (!ev.entering) continue;
            switch (ev.node.kind) {
                .text, .code => try out.appendSlice(self.a, ev.node.literal),
                .softbreak, .linebreak => try out.append(self.a, ' '),
                else => {},
            }
        }
    }

    fn footnoteNumber(self: *Renderer, key: []const u8) Allocator.Error!?usize {
        const def = self.defs.get(key) orelse return null;
        const gop = try self.used_index.getOrPut(self.a, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = self.used.items.len;
            try self.used.append(self.a, .{ .key = key, .def = def });
        }
        return gop.value_ptr.* + 1;
    }

    fn inlines(self: *Renderer, parent: *Node, tokens: *std.ArrayList(Token), depth: usize) Error!void {
        var child = parent.first_child;
        while (child) |n| : (child = n.next) {
            switch (n.kind) {
                .text => try self.addText(tokens, n.literal),
                .softbreak => try tokens.append(self.a, .space),
                .linebreak => try tokens.append(self.a, .hard_break),
                .code => {
                    try self.pushStyle(tokens, .code, true, "`");
                    try self.addText(tokens, n.literal);
                    try self.pushStyle(tokens, .code, false, "`");
                },
                .html_inline => {},
                .footnote_ref => {
                    if (try self.footnoteNumber(n.literal)) |num| {
                        const label = try std.fmt.allocPrint(self.a, "[{d}]", .{num});
                        try tokens.append(self.a, .{ .word = label });
                    }
                },
                .emph, .strong, .strikethrough, .link, .image => {
                    if (depth >= max_depth) {
                        try self.inlines(n, tokens, depth);
                        continue;
                    }
                    try self.styled(n, tokens, depth);
                },
                else => {},
            }
        }
    }

    fn styled(self: *Renderer, n: *Node, tokens: *std.ArrayList(Token), depth: usize) Error!void {
        switch (n.kind) {
            .emph => {
                try self.pushStyle(tokens, .italic, true, "_");
                try self.inlines(n, tokens, depth + 1);
                try self.pushStyle(tokens, .italic, false, "_");
            },
            .strong => {
                try self.pushStyle(tokens, .bold, true, "**");
                try self.inlines(n, tokens, depth + 1);
                try self.pushStyle(tokens, .bold, false, "**");
            },
            .strikethrough => {
                try self.pushStyle(tokens, .strike, true, "~~");
                try self.inlines(n, tokens, depth + 1);
                try self.pushStyle(tokens, .strike, false, "~~");
            },
            .link => {
                try self.pushStyle(tokens, .link, true, "");
                try self.inlines(n, tokens, depth + 1);
                try self.pushStyle(tokens, .link, false, "");
                if (self.o.show_urls and n.literal.len > 0) {
                    var label: std.ArrayList(u8) = .empty;
                    try self.plain(n, &label);
                    const dest = n.literal;
                    const same = std.mem.eql(u8, label.items, dest) or
                        (std.mem.startsWith(u8, dest, "mailto:") and std.mem.eql(u8, label.items, dest[7..]));
                    if (!same) {
                        try tokens.append(self.a, .space);
                        try self.pushStyle(tokens, .dim, true, "");
                        try tokens.append(self.a, .{ .word = try std.fmt.allocPrint(self.a, "<{s}>", .{dest}) });
                        try self.pushStyle(tokens, .dim, false, "");
                    }
                }
            },
            .image => {
                var alt: std.ArrayList(u8) = .empty;
                try self.plain(n, &alt);
                try tokens.append(self.a, .{ .word = "[image:" });
                try tokens.append(self.a, .space);
                try self.addText(tokens, alt.items);
                try tokens.append(self.a, .{ .word = "]" });
            },
            else => {},
        }
    }

    /// Writes tokens as wrapped lines under the current prefixes.
    fn flow(self: *Renderer, tokens: []const Token) Error!void {
        const avail = self.available();
        const base = self.prefixWidth();
        var col: usize = 0; // columns used after the prefix
        var line_open = false;
        var space = false;
        // True while the next word touches the one before it (no space token
        // between), as in "`code`)": such words wrap together, never apart.
        var glued = false;
        for (tokens, 0..) |t, idx| switch (t) {
            .style => |s| {
                const delta: u16 = 1;
                const ptr: *u16 = switch (s.field) {
                    .bold => &self.style.bold,
                    .italic => &self.style.italic,
                    .underline => &self.style.underline,
                    .strike => &self.style.strike,
                    .code => &self.style.code,
                    .link => &self.style.link,
                    .dim => &self.style.dim,
                };
                if (s.on) ptr.* += delta else ptr.* -|= delta;
                if (line_open) try self.sgr();
            },
            .space => {
                space = line_open;
                glued = false;
            },
            .hard_break => {
                if (line_open) try self.endLine();
                line_open = false;
                space = false;
                glued = false;
                col = 0;
            },
            .word => |word| {
                const ww = unicode.stringWidth(word);
                if (!glued and line_open and col + 1 + gluedWidth(tokens, idx) > avail) {
                    try self.endLine();
                    line_open = false;
                    space = false;
                    col = 0;
                }
                if (!line_open) {
                    try self.writePrefix(false);
                    try self.sgr();
                    line_open = true;
                    col = 0;
                } else if (space) {
                    try self.w.writeAll(" ");
                    col += 1;
                }
                space = false;
                glued = true;
                try self.w.writeAll(word);
                col += ww;
            },
        };
        if (line_open) try self.endLine();
        _ = base;
    }

    /// Width of the run of words that starts at `tokens[from]` and is not
    /// interrupted by a space or a line break (style changes do not interrupt it).
    fn gluedWidth(tokens: []const Token, from: usize) usize {
        var w: usize = 0;
        for (tokens[from..]) |t| switch (t) {
            .word => |word| w += unicode.stringWidth(word),
            .style => {},
            else => break,
        };
        return w;
    }

    fn endLine(self: *Renderer) Error!void {
        if (self.o.color) try self.w.writeAll("\x1b[0m");
        try self.w.writeAll("\n");
    }

    fn paragraphText(self: *Renderer, n: *Node) Error!void {
        var tokens: std.ArrayList(Token) = .empty;
        defer tokens.deinit(self.a);
        try self.inlines(n, &tokens, 0);
        try self.flow(tokens.items);
    }

    // ---- blocks ----------------------------------------------------------------------

    fn children(self: *Renderer, parent: *Node) Error!void {
        if (self.depth >= max_depth) {
            try self.beginBlock();
            try self.writePrefix(false);
            try self.w.writeAll("…\n");
            self.endBlock();
            return;
        }
        self.depth += 1;
        defer self.depth -= 1;
        var child = parent.first_child;
        while (child) |n| : (child = n.next) try self.block(n);
    }

    fn block(self: *Renderer, n: *Node) Error!void {
        switch (n.kind) {
            .paragraph => {
                try self.beginBlock();
                try self.paragraphText(n);
                const tight = if (n.parent) |p| ((p.kind == .item or p.kind == .deflist_def) and p.parent != null and p.parent.?.list.tight) else false;
                if (!tight) self.endBlock();
            },
            .heading => {
                try self.beginBlock();
                var tokens: std.ArrayList(Token) = .empty;
                defer tokens.deinit(self.a);
                if (self.o.color) {
                    try tokens.append(self.a, .{ .style = .{ .field = .bold, .on = true } });
                } else if (n.level <= 2) {
                    try tokens.append(self.a, .{ .word = if (n.level == 1) "#" else "##" });
                    try tokens.append(self.a, .space);
                }
                try self.inlines(n, &tokens, 0);
                if (self.o.color) try tokens.append(self.a, .{ .style = .{ .field = .bold, .on = false } });
                try self.flow(tokens.items);
                self.endBlock();
            },
            .thematic_break => {
                try self.beginBlock();
                try self.writePrefix(false);
                const n_cols = @min(self.available(), 60);
                for (0..n_cols) |_| try self.w.writeAll(if (self.o.unicode) "─" else "-");
                try self.w.writeAll("\n");
                self.endBlock();
            },
            .code_block => {
                try self.beginBlock();
                var lines = std.mem.splitScalar(u8, n.literal, '\n');
                while (lines.next()) |line| {
                    if (line.len == 0 and lines.peek() == null) break;
                    try self.writePrefix(false);
                    if (self.o.color) try self.w.writeAll("\x1b[36m");
                    if (n.indent == 0) {
                        try self.w.writeAll("    ");
                    } else if (n.indent != Node.flush) try self.w.splatByteAll(' ', n.indent);
                    try self.w.writeAll(line);
                    if (self.o.color) try self.w.writeAll("\x1b[0m");
                    try self.w.writeAll("\n");
                }
                self.endBlock();
            },
            .html_block => {
                try self.beginBlock();
                var lines = std.mem.splitScalar(u8, n.literal, '\n');
                while (lines.next()) |line| {
                    try self.writePrefix(false);
                    if (self.o.color) try self.w.writeAll("\x1b[2m");
                    try self.w.writeAll(line);
                    if (self.o.color) try self.w.writeAll("\x1b[0m");
                    try self.w.writeAll("\n");
                }
                self.endBlock();
            },
            .block_quote => {
                try self.beginBlock();
                // A quote with an indent hint (`indent`, set by readers of other
                // formats such as man pages) is plain indentation.
                const bar: []const u8 = if (n.indent > 0) try self.spaces(n.indent) else if (self.o.unicode) "│ " else "> ";
                try self.prefixes.append(self.a, .{ .cont = bar });
                try self.children(n);
                _ = self.prefixes.pop();
                self.endBlock();
            },
            .list => try self.list(n),
            .deflist => try self.deflist(n),
            .table => try self.table(n),
            else => {},
        }
    }

    fn spaces(self: *Renderer, n: usize) Allocator.Error![]const u8 {
        const s = try self.a.alloc(u8, n);
        @memset(s, ' ');
        return s;
    }

    /// Terms in bold, definitions indented below them. A definition with an
    /// indent hint (`indent`) starts on the term's line when the term is
    /// shorter than the indent, as in man pages.
    fn deflist(self: *Renderer, n: *Node) Error!void {
        try self.beginBlock();
        var child = n.first_child;
        while (child) |c| {
            var next = c.next;
            switch (c.kind) {
                .deflist_term => {
                    // Terms after the first are set off from the definitions above.
                    if (c.prev != null and c.prev.?.kind == .deflist_def) self.need_blank = true;
                    try self.beginBlock();
                    const def: ?*Node = if (c.next) |nx| (if (nx.kind == .deflist_def) nx else null) else null;
                    if (def) |d| {
                        if (d.indent > 0 and d.first_child != null) {
                            const lines = try self.cellLines(c, 0);
                            const tw = if (lines.len == 1) visibleWidth(lines[0]) else d.indent;
                            if (tw < d.indent) {
                                var first: std.ArrayList(u8) = .empty;
                                try first.appendSlice(self.a, lines[0]);
                                try first.appendNTimes(self.a, ' ', d.indent - tw);
                                try self.prefixes.append(self.a, .{
                                    .cont = try self.spaces(d.indent),
                                    .first = first.items,
                                    .first_width = d.indent,
                                });
                                self.need_blank = false;
                                try self.children(d);
                                _ = self.prefixes.pop();
                                self.need_blank = !n.list.tight and d.next != null;
                                next = d.next;
                                child = next;
                                continue;
                            }
                        }
                    }
                    var tokens: std.ArrayList(Token) = .empty;
                    defer tokens.deinit(self.a);
                    if (self.o.color) try tokens.append(self.a, .{ .style = .{ .field = .bold, .on = true } });
                    try self.inlines(c, &tokens, 0);
                    if (self.o.color) try tokens.append(self.a, .{ .style = .{ .field = .bold, .on = false } });
                    try self.flow(tokens.items);
                    self.need_blank = !n.list.tight and c.next != null and c.next.?.kind == .deflist_term;
                },
                .deflist_def => {
                    const indent = if (c.indent > 0) try self.spaces(c.indent) else "    ";
                    try self.prefixes.append(self.a, .{ .cont = indent });
                    self.need_blank = false;
                    try self.children(c);
                    _ = self.prefixes.pop();
                    self.need_blank = !n.list.tight and c.next != null and c.next.?.kind == .deflist_def;
                },
                else => {},
            }
            child = next;
        }
        self.endBlock();
    }

    fn list(self: *Renderer, n: *Node) Error!void {
        try self.beginBlock();
        var number: u32 = n.list.start;
        var item = n.first_child;
        // Width of the widest number, so the text of every item lines up.
        var last_number = n.list.start;
        var count: u32 = 0;
        var it = n.first_child;
        while (it) |x| : (it = x.next) count += 1;
        if (count > 0) last_number = n.list.start + count - 1;
        const num_width = std.fmt.count("{d}", .{last_number});

        while (item) |i| : (item = i.next) {
            const marker = blk: {
                var m: std.ArrayList(u8) = .empty;
                if (n.list.kind == .bullet) {
                    try m.appendSlice(self.a, if (self.o.unicode) "• " else "- ");
                } else {
                    const digits = std.fmt.count("{d}", .{number});
                    try m.appendNTimes(self.a, ' ', num_width - digits);
                    try m.print(self.a, "{d}{c} ", .{ number, n.list.delimiter });
                }
                switch (i.task) {
                    .none => {},
                    .unchecked => try m.appendSlice(self.a, "[ ] "),
                    .checked => try m.appendSlice(self.a, "[x] "),
                }
                break :blk m.items;
            };
            const cont = try self.a.alloc(u8, unicode.stringWidth(marker));
            @memset(cont, ' ');
            try self.prefixes.append(self.a, .{ .cont = cont, .first = marker });
            const saved_blank = self.need_blank;
            self.need_blank = false;
            _ = saved_blank;
            try self.children(i);
            _ = self.prefixes.pop();
            // Items of a loose list are separated by a blank line.
            self.need_blank = !n.list.tight and i.next != null;
            number += 1;
        }
        self.endBlock();
    }

    /// The lines of a table cell wrapped to `width` (0: no wrapping), styles
    /// reset at the end of each line.
    fn cellLines(self: *Renderer, cell: *Node, width: usize) Error![]const []const u8 {
        var buf: Io.Writer.Allocating = .init(self.a);
        var sub: Renderer = .{
            .w = &buf.writer,
            .a = self.a,
            .o = self.o,
            .defs = self.defs,
            .min_width = 4,
            .used = self.used,
            .used_index = self.used_index,
        };
        sub.o.width = width;
        var tokens: std.ArrayList(Token) = .empty;
        defer tokens.deinit(self.a);
        try sub.inlines(cell, &tokens, 0);
        try sub.flow(tokens.items);
        self.used = sub.used;
        self.used_index = sub.used_index;

        var lines: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, buf.written(), '\n');
        while (it.next()) |line| {
            if (line.len == 0 and it.peek() == null) break;
            try lines.append(self.a, line);
        }
        if (lines.items.len == 0) try lines.append(self.a, "");
        return lines.items;
    }

    /// Columns taken by `s`, not counting ANSI escape sequences.
    fn visibleWidth(s: []const u8) usize {
        var w: usize = 0;
        var i: usize = 0;
        while (i < s.len) {
            if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '[') {
                i += 2;
                while (i < s.len and !std.ascii.isAlphabetic(s[i])) i += 1;
                i += 1;
                continue;
            }
            const d = unicode.decodeAt(s, i);
            w += unicode.displayWidth(d.cp);
            i += d.len;
        }
        return w;
    }

    fn table(self: *Renderer, n: *Node) Error!void {
        try self.beginBlock();
        const cols = if (n.first_child) |r| countChildren(r) else 0;
        if (cols == 0) return self.endBlock();

        // Natural column widths: every cell on one line.
        const widths = try self.a.alloc(usize, cols);
        @memset(widths, 1);
        var row = n.first_child;
        while (row) |r| : (row = r.next) {
            var c = r.first_child;
            var i: usize = 0;
            while (c) |cell| : (c = cell.next) {
                if (i >= cols) break;
                for (try self.cellLines(cell, 0)) |line| widths[i] = @max(widths[i], visibleWidth(line));
                i += 1;
            }
        }

        // Too wide: narrow the widest column until the table fits.
        const avail = self.available();
        const frame = 3 * cols + 1;
        while (true) {
            var total: usize = frame;
            for (widths) |wd| total += wd;
            if (total <= avail) break;
            var widest: usize = 0;
            for (widths, 0..) |wd, i| {
                if (wd > widths[widest]) widest = i;
            }
            if (widths[widest] <= 6) break;
            widths[widest] -= 1;
        }

        const fancy = self.o.unicode;
        const h: []const u8 = if (fancy) "─" else "-";
        const v: []const u8 = if (fancy) "│" else "|";
        try self.border(widths, h, if (fancy) "┌" else "+", if (fancy) "┬" else "+", if (fancy) "┐" else "+");
        var row_node = n.first_child;
        while (row_node) |rn| : (row_node = rn.next) {
            // Wrap every cell, then write the row line by line.
            const cells = try self.a.alloc([]const []const u8, cols);
            const aligns = try self.a.alloc(ast.Align, cols);
            @memset(aligns, .none);
            var height: usize = 1;
            var c = rn.first_child;
            for (cells, 0..) |*slot, i| {
                if (c) |cn| {
                    slot.* = try self.cellLines(cn, widths[i]);
                    aligns[i] = cn.align_;
                    c = cn.next;
                } else slot.* = &.{""};
                height = @max(height, slot.len);
            }
            for (0..height) |line_no| {
                try self.writePrefix(false);
                try self.w.writeAll(v);
                for (cells, 0..) |lines, i| {
                    const cell_text: []const u8 = if (line_no < lines.len) lines[line_no] else "";
                    const pad = widths[i] -| visibleWidth(cell_text);
                    const left: usize = switch (aligns[i]) {
                        .right => pad,
                        .center => pad / 2,
                        else => 0,
                    };
                    try self.w.writeAll(" ");
                    try self.w.splatByteAll(' ', left);
                    if (rn.header and self.o.color) try self.w.writeAll("\x1b[1m");
                    try self.w.writeAll(cell_text);
                    if (rn.header and self.o.color) try self.w.writeAll("\x1b[0m");
                    try self.w.splatByteAll(' ', pad - left);
                    try self.w.writeAll(" ");
                    try self.w.writeAll(v);
                }
                try self.w.writeAll("\n");
            }
            if (rn.header) try self.border(widths, h, if (fancy) "├" else "+", if (fancy) "┼" else "+", if (fancy) "┤" else "+");
        }
        try self.border(widths, h, if (fancy) "└" else "+", if (fancy) "┴" else "+", if (fancy) "┘" else "+");
        self.endBlock();
    }

    fn countChildren(n: *Node) usize {
        var c: usize = 0;
        var x = n.first_child;
        while (x) |y| : (x = y.next) c += 1;
        return c;
    }

    fn border(self: *Renderer, widths: []const usize, h: []const u8, left: []const u8, mid: []const u8, right: []const u8) Error!void {
        try self.writePrefix(false);
        try self.w.writeAll(left);
        for (widths, 0..) |wd, i| {
            for (0..wd + 2) |_| try self.w.writeAll(h);
            try self.w.writeAll(if (i + 1 == widths.len) right else mid);
        }
        try self.w.writeAll("\n");
    }

    fn footnotes(self: *Renderer) Error!void {
        if (self.used.items.len == 0) return;
        try self.beginBlock();
        try self.writePrefix(false);
        for (0..@min(self.available(), 20)) |_| try self.w.writeAll(if (self.o.unicode) "─" else "-");
        try self.w.writeAll("\n");
        var i: usize = 0;
        while (i < self.used.items.len) : (i += 1) {
            const u = self.used.items[i];
            const marker = try std.fmt.allocPrint(self.a, "[{d}] ", .{i + 1});
            const cont = try self.a.alloc(u8, marker.len);
            @memset(cont, ' ');
            try self.prefixes.append(self.a, .{ .cont = cont, .first = marker });
            self.need_blank = false;
            try self.children(u.def);
            _ = self.prefixes.pop();
        }
    }
};

pub fn write(gpa: Allocator, root: *Node, defs: *const std.StringHashMapUnmanaged(*Node), options: TextOptions, w: *Io.Writer) Error!void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var r: Renderer = .{ .w = w, .a = arena.allocator(), .o = options, .defs = defs };
    try r.children(root);
    try r.footnotes();
}
