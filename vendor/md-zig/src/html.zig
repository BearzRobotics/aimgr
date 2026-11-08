//! Renders a tree as HTML, byte for byte like the CommonMark reference
//! implementation (and cmark-gfm for the extensions), so the specification's
//! examples can be compared exactly.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const text = @import("text.zig");
const opts = @import("options.zig");
const Node = ast.Node;

pub const Error = Io.Writer.Error || Allocator.Error;

pub const Footnotes = std.StringHashMapUnmanaged(*Node);

/// A footnote that is referenced, in order of first reference.
const Used = struct { key: []const u8, def: *Node, refs: usize };

const Renderer = struct {
    w: *Io.Writer,
    arena: Allocator,
    ext: opts.Extensions,
    defs: *const Footnotes,
    /// Last byte written, to decide whether a line break is needed.
    last: u8 = '\n',
    /// Greater than 0 inside an image description, where tags are left out.
    no_tags: u32 = 0,
    used: std.ArrayList(Used) = .empty,
    used_index: std.StringHashMapUnmanaged(usize) = .empty,
    /// While a footnote's content is written: the paragraph that takes the
    /// back-references, and their HTML.
    backref_para: ?*Node = null,
    backrefs: []const u8 = "",

    fn lit(self: *Renderer, s: []const u8) Error!void {
        if (s.len == 0) return;
        try self.w.writeAll(s);
        self.last = s[s.len - 1];
    }

    fn cr(self: *Renderer) Error!void {
        if (self.last != '\n') try self.lit("\n");
    }

    fn esc(self: *Renderer, s: []const u8) Error!void {
        var start: usize = 0;
        for (s, 0..) |c, i| {
            const rep: []const u8 = switch (c) {
                '&' => "&amp;",
                '<' => "&lt;",
                '>' => "&gt;",
                '"' => "&quot;",
                else => continue,
            };
            try self.lit(s[start..i]);
            try self.lit(rep);
            start = i + 1;
        }
        try self.lit(s[start..]);
    }

    /// Raw HTML, with the tags GFM disallows shown as text when `tagfilter` is on.
    fn raw(self: *Renderer, s: []const u8) Error!void {
        if (!self.ext.tagfilter) return self.lit(s);
        var start: usize = 0;
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            if (s[i] != '<' or !disallowedTag(s[i + 1 ..])) continue;
            try self.lit(s[start..i]);
            try self.lit("&lt;");
            start = i + 1;
        }
        try self.lit(s[start..]);
    }

    fn open(self: *Renderer, name: []const u8) Error!void {
        if (self.no_tags > 0) return;
        try self.lit("<");
        try self.lit(name);
        try self.lit(">");
    }

    fn close(self: *Renderer, name: []const u8) Error!void {
        if (self.no_tags > 0) return;
        try self.lit("</");
        try self.lit(name);
        try self.lit(">");
    }

    fn render(self: *Renderer, root: *Node) Error!void {
        var walker = ast.Walker.init(root);
        // Footnote definitions are written at the end, not where they stand.
        var skip: ?*Node = null;
        while (walker.next()) |ev| {
            if (skip) |s| {
                if (ev.node == s and !ev.entering) skip = null;
                continue;
            }
            if (ev.node.kind == .footnote_def and ev.entering) {
                skip = ev.node;
                continue;
            }
            try self.node(ev.node, ev.entering);
        }
    }

    fn firstRefSuffix(buf: []u8, n: usize) []const u8 {
        if (n <= 1) return "";
        return std.fmt.bufPrint(buf, "-{d}", .{n}) catch "";
    }

    fn footnoteRef(self: *Renderer, n: *Node) Error!void {
        const def = self.defs.get(n.literal) orelse return;
        const gop = try self.used_index.getOrPut(self.arena, n.literal);
        if (!gop.found_existing) {
            gop.value_ptr.* = self.used.items.len;
            try self.used.append(self.arena, .{ .key = n.literal, .def = def, .refs = 0 });
        }
        const u = &self.used.items[gop.value_ptr.*];
        u.refs += 1;
        const key = try text.encodeUrl(self.arena, n.literal);
        var nb: [24]u8 = undefined;
        const suffix = firstRefSuffix(&nb, u.refs);
        var ib: [24]u8 = undefined;
        const idx = std.fmt.bufPrint(&ib, "{d}", .{gop.value_ptr.* + 1}) catch unreachable;
        try self.lit("<sup class=\"footnote-ref\"><a href=\"#fn-");
        try self.lit(key);
        try self.lit("\" id=\"fnref-");
        try self.lit(key);
        try self.lit(suffix);
        try self.lit("\" data-footnote-ref>");
        try self.lit(idx);
        try self.lit("</a></sup>");
    }

    /// The `<section class="footnotes">` with every referenced footnote.
    fn footnotes(self: *Renderer) Error!void {
        if (self.used.items.len == 0) return;
        try self.cr();
        try self.lit("<section class=\"footnotes\" data-footnotes>\n<ol>\n");
        var i: usize = 0;
        while (i < self.used.items.len) : (i += 1) {
            const u = self.used.items[i];
            const key = try text.encodeUrl(self.arena, u.key);
            try self.lit("<li id=\"fn-");
            try self.lit(key);
            try self.lit("\">\n");

            var back: std.ArrayList(u8) = .empty;
            var k: usize = 1;
            while (k <= u.refs) : (k += 1) {
                if (k > 1) try back.append(self.arena, ' ');
                var sb: [24]u8 = undefined;
                const suffix = firstRefSuffix(&sb, k);
                var ib: [48]u8 = undefined;
                const idx = if (k == 1)
                    std.fmt.bufPrint(&ib, "{d}", .{i + 1}) catch unreachable
                else
                    std.fmt.bufPrint(&ib, "{d}-{d}", .{ i + 1, k }) catch unreachable;
                try back.print(self.arena, "<a href=\"#fnref-{s}{s}\" class=\"footnote-backref\" data-footnote-backref data-footnote-backref-idx=\"{s}\" aria-label=\"Back to reference {s}\">\u{21a9}", .{ key, suffix, idx, idx });
                if (k > 1) try back.print(self.arena, "<sup class=\"footnote-ref\">{d}</sup>", .{k});
                try back.appendSlice(self.arena, "</a>");
            }
            self.backrefs = back.items;
            self.backref_para = if (u.def.last_child) |lc| (if (lc.kind == .paragraph) lc else null) else null;

            var walker = ast.Walker.init(u.def);
            while (walker.next()) |ev| {
                if (ev.node == u.def) continue;
                try self.node(ev.node, ev.entering);
            }
            if (self.backref_para == null) {
                try self.lit(self.backrefs);
                try self.cr();
            }
            self.backref_para = null;
            try self.lit("</li>\n");
        }
        try self.lit("</ol>\n</section>\n");
    }

    fn cell(self: *Renderer, n: *Node, entering: bool) Error!void {
        const tag = if (n.header) "th" else "td";
        if (!entering) {
            try self.close(tag);
            return self.cr();
        }
        try self.lit("<");
        try self.lit(tag);
        switch (n.align_) {
            .none => {},
            .left => try self.lit(" align=\"left\""),
            .center => try self.lit(" align=\"center\""),
            .right => try self.lit(" align=\"right\""),
        }
        try self.lit(">");
    }

    fn row(self: *Renderer, n: *Node, entering: bool) Error!void {
        if (entering) {
            try self.cr();
            if (n.header) {
                try self.lit("<thead>\n<tr>\n");
            } else {
                if (n.prev != null and n.prev.?.header) try self.lit("<tbody>\n");
                try self.lit("<tr>\n");
            }
        } else {
            try self.lit("</tr>\n");
            if (n.header) try self.lit("</thead>\n");
            if (!n.header and n.next == null) try self.lit("</tbody>\n");
        }
    }

    fn node(self: *Renderer, n: *Node, entering: bool) Error!void {
        switch (n.kind) {
            .document, .front_matter, .footnote_def => {},
            .text => try self.esc(n.literal),
            .softbreak => try self.lit("\n"),
            .linebreak => {
                if (self.no_tags == 0) try self.lit("<br />");
                try self.cr();
            },
            .code => {
                try self.open("code");
                try self.esc(n.literal);
                try self.close("code");
            },
            .html_inline => if (self.no_tags == 0) try self.raw(n.literal),
            .html_block => {
                try self.cr();
                try self.raw(n.literal);
                try self.cr();
            },
            .emph => if (entering) try self.open("em") else try self.close("em"),
            .strong => if (entering) try self.open("strong") else try self.close("strong"),
            .strikethrough => if (entering) try self.open("del") else try self.close("del"),
            .footnote_ref => if (self.no_tags == 0) try self.footnoteRef(n),
            .link => {
                if (entering) {
                    if (self.no_tags == 0) {
                        try self.lit("<a href=\"");
                        try self.esc(n.literal);
                        try self.lit("\"");
                        if (n.title.len > 0) {
                            try self.lit(" title=\"");
                            try self.esc(n.title);
                            try self.lit("\"");
                        }
                        try self.lit(">");
                    }
                } else try self.close("a");
            },
            .image => {
                if (entering) {
                    if (self.no_tags == 0) {
                        try self.lit("<img src=\"");
                        try self.esc(n.literal);
                        try self.lit("\" alt=\"");
                    }
                    self.no_tags += 1;
                } else {
                    self.no_tags -= 1;
                    if (self.no_tags == 0) {
                        if (n.title.len > 0) {
                            try self.lit("\" title=\"");
                            try self.esc(n.title);
                        }
                        try self.lit("\" />");
                    }
                }
            },
            .paragraph => {
                if (!entering and self.backref_para == n) {
                    try self.lit(" ");
                    try self.lit(self.backrefs);
                }
                // In a tight list the paragraph's tags are left out.
                if (n.parent) |p| if (p.parent) |g| if ((g.kind == .list or g.kind == .deflist) and g.list.tight) return;
                if (entering) {
                    try self.cr();
                    try self.open("p");
                } else {
                    try self.close("p");
                    try self.cr();
                }
            },
            .heading => {
                var buf: [2]u8 = .{ 'h', '0' + n.level };
                if (entering) {
                    try self.cr();
                    try self.open(&buf);
                } else {
                    try self.close(&buf);
                    try self.cr();
                }
            },
            .thematic_break => {
                try self.cr();
                try self.lit("<hr />");
                try self.cr();
            },
            .block_quote => {
                if (entering) {
                    try self.cr();
                    try self.open("blockquote");
                    try self.cr();
                } else {
                    try self.cr();
                    try self.close("blockquote");
                    try self.cr();
                }
            },
            .list => {
                const name = if (n.list.kind == .bullet) "ul" else "ol";
                if (entering) {
                    try self.cr();
                    if (n.list.kind == .ordered and n.list.start != 1) {
                        var b: [16]u8 = undefined;
                        try self.lit("<ol start=\"");
                        try self.lit(std.fmt.bufPrint(&b, "{d}", .{n.list.start}) catch unreachable);
                        try self.lit("\">");
                    } else try self.open(name);
                    try self.cr();
                } else {
                    try self.cr();
                    try self.close(name);
                    try self.cr();
                }
            },
            .item => if (entering) {
                try self.open("li");
                switch (n.task) {
                    .none => {},
                    .unchecked => try self.lit("<input type=\"checkbox\" disabled=\"\" /> "),
                    .checked => try self.lit("<input type=\"checkbox\" checked=\"\" disabled=\"\" /> "),
                }
            } else {
                try self.close("li");
                try self.cr();
            },
            .deflist => {
                if (entering) {
                    try self.cr();
                    try self.lit("<dl>\n");
                } else {
                    try self.cr();
                    try self.lit("</dl>\n");
                }
            },
            .deflist_term => if (entering) {
                try self.cr();
                try self.open("dt");
            } else {
                try self.close("dt");
                try self.cr();
            },
            .deflist_def => if (entering) {
                try self.cr();
                try self.open("dd");
            } else {
                try self.close("dd");
                try self.cr();
            },
            .code_block => {
                try self.cr();
                try self.lit("<pre><code");
                var words = std.mem.tokenizeAny(u8, n.title, " \t\n\r\x0b\x0c");
                if (words.next()) |lang| {
                    try self.lit(" class=\"language-");
                    try self.esc(lang);
                    try self.lit("\"");
                }
                try self.lit(">");
                try self.esc(n.literal);
                try self.lit("</code></pre>");
                try self.cr();
            },
            .table => if (entering) {
                try self.cr();
                try self.lit("<table>\n");
            } else {
                try self.lit("</table>\n");
            },
            .table_row => try self.row(n, entering),
            .table_cell => try self.cell(n, entering),
        }
    }
};

/// Tags GFM does not let through as raw HTML.
fn disallowedTag(after_lt: []const u8) bool {
    var s = after_lt;
    if (s.len > 0 and s[0] == '/') s = s[1..];
    inline for (.{ "title", "textarea", "style", "xmp", "iframe", "noembed", "noframes", "script", "plaintext" }) |name| {
        if (s.len >= name.len and std.ascii.eqlIgnoreCase(s[0..name.len], name)) {
            if (s.len == name.len) return true;
            const c = s[name.len];
            if (text.isWhitespace(c) or c == '>' or c == '/') return true;
        }
    }
    return false;
}

pub fn write(gpa: Allocator, root: *Node, defs: *const Footnotes, ext: opts.Extensions, w: *Io.Writer) Error!void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var r: Renderer = .{ .w = w, .arena = arena.allocator(), .ext = ext, .defs = defs };
    try r.render(root);
    try r.footnotes();
}
