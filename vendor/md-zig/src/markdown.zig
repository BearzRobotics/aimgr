//! Writes a tree back out as CommonMark (plus the extensions the tree was
//! parsed with), so a document can be read, edited and saved as Markdown.
//!
//! The text is not the original text: the tree does not remember how a
//! construct was spelled. What is kept is the meaning (parsing the output gives
//! a tree that renders to the same HTML) and everything that is stored
//! verbatim, above all **raw HTML, and with it `<!-- comments -->`**, which are
//! `html_block` and `html_inline` nodes and are written exactly as read. Front
//! matter is also written back unchanged.
//!
//! What is normalised: headings are ATX (`# x`), code is fenced, emphasis is
//! `_x_` (or `*x*` inside a word) and `**x**`, thematic breaks are `***`,
//! bullets keep their character except that neighbouring lists alternate so
//! they stay separate, links are inline (`[x](url "title")`; reference
//! definitions are resolved and not written), tables are padded with single
//! spaces. Text is backslash-escaped where it could be mistaken for markup.
//!
//! Nesting deeper than `max_depth` fails with `error.TooDeep` instead of
//! exhausting the stack.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const Node = ast.Node;
const Kind = ast.Kind;
const Extensions = @import("options.zig").Extensions;

pub const Error = Io.Writer.Error || Allocator.Error || error{TooDeep};

pub const max_depth = 200;

/// Writes `root` (a document node) as Markdown.
pub fn write(gpa: Allocator, root: *Node, ext: Extensions, w: *Io.Writer) Error!void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var g: Gen = .{ .a = arena.allocator(), .ext = ext };
    const out = try g.blocks(root, false);
    try w.writeAll(out);
}

const Gen = struct {
    a: Allocator,
    ext: Extensions,
    depth: u32 = 0,
    in_cell: bool = false,

    fn enter(self: *Gen) Error!void {
        if (self.depth >= max_depth) return error.TooDeep;
        self.depth += 1;
    }

    // ---- blocks ------------------------------------------------------------

    /// The children of `parent` as blocks. Each block ends with a newline;
    /// blocks are separated by a blank line unless `tight`.
    fn blocks(self: *Gen, parent: *Node, tight: bool) Error![]const u8 {
        try self.enter();
        defer self.depth -= 1;
        var out: std.ArrayList(u8) = .empty;
        var child = parent.first_child;
        var prev: ?*Node = null;
        while (child) |c| : (child = c.next) {
            if (prev != null and !tight) try out.append(self.a, '\n');
            const text = try self.block(c, prev);
            try out.appendSlice(self.a, text);
            if (text.len == 0 or text[text.len - 1] != '\n') try out.append(self.a, '\n');
            prev = c;
        }
        return out.items;
    }

    fn block(self: *Gen, n: *Node, prev: ?*Node) Error![]const u8 {
        switch (n.kind) {
            .paragraph => return self.line(try self.inlines(n, .paragraph)),
            .heading => {
                var out: std.ArrayList(u8) = .empty;
                try out.appendNTimes(self.a, '#', @max(@as(u8, 1), @min(n.level, 6)));
                if (n.level <= 2 and hasBreak(n)) {
                    const body = try self.inlines(n, .paragraph);
                    const under: []const u8 = if (n.level == 1) "===\n" else "---\n";
                    return std.mem.concat(self.a, u8, &.{ body, "\n", under });
                }
                const body = try self.inlines(n, .heading);
                if (body.len != 0) {
                    try out.append(self.a, ' ');
                    try out.appendSlice(self.a, body);
                }
                return self.line(out.items);
            },
            .thematic_break => return "***\n",
            .html_block => return self.line(n.literal),
            .front_matter => return try std.fmt.allocPrint(self.a, "---\n{s}---\n", .{n.literal}),
            .code_block => return self.codeBlock(n),
            .block_quote => {
                const inner = try self.blocks(n, false);
                if (inner.len == 0) return ">\n";
                return self.prefixed(inner, "> ", "> ");
            },
            .list => return self.list(n, prev),
            .table => return self.table(n),
            .footnote_def => {
                const inner = try self.blocks(n, false);
                const head = try std.fmt.allocPrint(self.a, "[^{s}]: ", .{n.literal});
                return self.prefixed(inner, head, "    ");
            },
            .deflist => return self.deflist(n),
            // Inlines or parts of a larger node never reach here from a valid tree;
            // treat a stray one as a paragraph of its own.
            else => return self.line(try self.inlineNode(n, .paragraph, false)),
        }
    }

    fn hasBreak(n: *Node) bool {
        var w = ast.Walker.init(n);
        while (w.next()) |ev| {
            if (ev.entering and (ev.node.kind == .softbreak or ev.node.kind == .linebreak)) return true;
        }
        return false;
    }

    fn line(self: *Gen, s: []const u8) []const u8 {
        _ = self;
        return s;
    }

    fn codeBlock(self: *Gen, n: *Node) Error![]const u8 {
        const info = n.title;
        const ch: u8 = if (std.mem.findScalar(u8, info, '`') != null) '~' else '`';
        var len: usize = 3;
        // The fence must be longer than any run of the fence character that
        // starts a line of the code.
        var it = std.mem.splitScalar(u8, n.literal, '\n');
        while (it.next()) |l| {
            const t = std.mem.trimStart(u8, l, " ");
            var run: usize = 0;
            while (run < t.len and t[run] == ch) run += 1;
            if (run >= len) len = run + 1;
        }
        var out: std.ArrayList(u8) = .empty;
        try out.appendNTimes(self.a, ch, len);
        try out.appendSlice(self.a, info);
        try out.append(self.a, '\n');
        try out.appendSlice(self.a, n.literal);
        if (n.literal.len != 0 and n.literal[n.literal.len - 1] != '\n') try out.append(self.a, '\n');
        try out.appendNTimes(self.a, ch, len);
        try out.append(self.a, '\n');
        return out.items;
    }

    fn list(self: *Gen, n: *Node, prev: ?*Node) Error![]const u8 {
        const ld = n.list;
        // Two lists in a row with the same marker would read as one list.
        const after_list = prev != null and prev.?.kind == .list and prev.?.list.kind == ld.kind;
        var bullet: u8 = if (ld.bullet_char == '*' or ld.bullet_char == '+' or ld.bullet_char == '-') ld.bullet_char else '-';
        var delim: u8 = if (ld.delimiter == ')') ')' else '.';
        if (after_list) {
            const pb = prev.?.list;
            if (ld.kind == .bullet) {
                const pc: u8 = if (pb.bullet_char == '*' or pb.bullet_char == '+' or pb.bullet_char == '-') pb.bullet_char else '-';
                if (pc == bullet) bullet = if (bullet == '-') '*' else '-';
            } else {
                const pd: u8 = if (pb.delimiter == ')') ')' else '.';
                if (pd == delim) delim = if (delim == '.') ')' else '.';
            }
        }

        var out: std.ArrayList(u8) = .empty;
        var number: u32 = ld.start;
        var item = n.first_child;
        var first = true;
        while (item) |it| : (item = it.next) {
            if (!first and !ld.tight) try out.append(self.a, '\n');
            first = false;
            const marker: []const u8 = if (ld.kind == .bullet)
                try std.fmt.allocPrint(self.a, "{c} ", .{bullet})
            else
                try std.fmt.allocPrint(self.a, "{d}{c} ", .{ number, delim });
            number +%= 1;
            var inner = try self.itemBody(it, ld.tight);
            const pad = try self.a.alloc(u8, marker.len);
            @memset(pad, ' ');
            if (inner.len == 0) {
                try out.appendSlice(self.a, std.mem.trimEnd(u8, marker, " "));
                try out.append(self.a, '\n');
                continue;
            }
            if (it.task != .none and self.ext.task_lists) {
                const box: []const u8 = if (it.task == .checked) "[x] " else "[ ] ";
                inner = try std.mem.concat(self.a, u8, &.{ box, inner });
            }
            try out.appendSlice(self.a, try self.prefixed(inner, marker, pad));
        }
        return out.items;
    }

    fn itemBody(self: *Gen, item: *Node, tight: bool) Error![]const u8 {
        return self.blocks(item, tight);
    }

    fn deflist(self: *Gen, n: *Node) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var child = n.first_child;
        var prev: ?Kind = null;
        while (child) |c| : (child = c.next) {
            // A term is followed at once by its first definition; a blank line
            // between definitions (or before the next term) makes the list loose.
            if (prev != null and !n.list.tight and !(prev.? == .deflist_term and c.kind == .deflist_term) and
                !(prev.? == .deflist_term and c.kind == .deflist_def)) try out.append(self.a, '\n');
            switch (c.kind) {
                .deflist_term => {
                    try out.appendSlice(self.a, try self.inlines(c, .paragraph));
                    try out.append(self.a, '\n');
                },
                else => {
                    const inner = try self.blocks(c, n.list.tight);
                    try out.appendSlice(self.a, try self.prefixed(inner, ": ", "  "));
                },
            }
            prev = c.kind;
        }
        return out.items;
    }

    fn table(self: *Gen, n: *Node) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        const saved = self.in_cell;
        self.in_cell = true;
        defer self.in_cell = saved;
        var row = n.first_child;
        var first = true;
        while (row) |r| : (row = r.next) {
            try out.append(self.a, '|');
            var cell = r.first_child;
            while (cell) |c| : (cell = c.next) {
                try out.append(self.a, ' ');
                try out.appendSlice(self.a, try self.inlines(c, .cell));
                try out.appendSlice(self.a, " |");
            }
            try out.append(self.a, '\n');
            if (first) {
                first = false;
                try out.append(self.a, '|');
                var h = r.first_child;
                while (h) |c| : (h = c.next) {
                    try out.appendSlice(self.a, switch (c.align_) {
                        .none => " --- |",
                        .left => " :-- |",
                        .center => " :-: |",
                        .right => " --: |",
                    });
                }
                try out.append(self.a, '\n');
            }
        }
        return out.items;
    }

    /// `text` with `first` before its first line and `rest` before the others.
    /// Blank lines get the prefix without its trailing spaces.
    fn prefixed(self: *Gen, text: []const u8, first: []const u8, rest: []const u8) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var it = std.mem.splitScalar(u8, text, '\n');
        var i: usize = 0;
        while (it.next()) |l| : (i += 1) {
            // The text ends with a newline, so the last piece is empty.
            if (it.peek() == null and l.len == 0) break;
            const p = if (i == 0) first else rest;
            if (l.len == 0) {
                try out.appendSlice(self.a, std.mem.trimEnd(u8, p, " "));
            } else {
                try out.appendSlice(self.a, p);
                try out.appendSlice(self.a, l);
            }
            try out.append(self.a, '\n');
        }
        return out.items;
    }

    // ---- inlines -----------------------------------------------------------

    const Ctx = enum { paragraph, heading, cell };

    fn inlines(self: *Gen, parent: *Node, ctx: Ctx) Error![]const u8 {
        try self.enter();
        defer self.depth -= 1;
        var out: std.ArrayList(u8) = .empty;
        var bol = true;
        var child = parent.first_child;
        while (child) |c| {
            child = c.next;
            switch (c.kind) {
                .softbreak => {
                    try out.appendSlice(self.a, if (ctx == .paragraph) "\n" else " ");
                    bol = ctx == .paragraph;
                },
                .linebreak => {
                    try out.appendSlice(self.a, if (ctx == .paragraph) "\\\n" else " ");
                    bol = ctx == .paragraph;
                },
                .text => {
                    // Escapes split text into several nodes; read them as one.
                    var run: std.ArrayList(u8) = .empty;
                    var last = c;
                    try run.appendSlice(self.a, c.literal);
                    while (last.next) |nx| : (last = nx) {
                        if (nx.kind != .text) break;
                        try run.appendSlice(self.a, nx.literal);
                    }
                    try self.escape(&out, run.items, last.next, bol);
                    bol = false;
                    child = last.next;
                },
                else => {
                    try out.appendSlice(self.a, try self.inlineNode(c, ctx, bol));
                    bol = false;
                },
            }
        }
        var s = out.items;
        // A closing run of `#` would be read as part of the heading marker.
        if (ctx == .heading and s.len != 0 and s[s.len - 1] == '#') {
            const idx = s.len - 1;
            if (idx == 0 or s[idx - 1] != '\\') {
                s = try std.mem.concat(self.a, u8, &.{ s[0..idx], "\\#" });
            }
        }
        return s;
    }

    fn inlineNode(self: *Gen, n: *Node, ctx: Ctx, bol: bool) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        switch (n.kind) {
            .text => try self.escape(&out, n.literal, n.next, bol),
            .code => try self.codeSpan(&out, n.literal),
            .html_inline => try out.appendSlice(self.a, n.literal),
            .emph => {
                const d: []const u8 = if (self.intraword(n)) "*" else "_";
                try out.appendSlice(self.a, d);
                try out.appendSlice(self.a, try self.inlines(n, ctx));
                try out.appendSlice(self.a, d);
            },
            .strong => {
                try out.appendSlice(self.a, "**");
                try out.appendSlice(self.a, try self.inlines(n, ctx));
                try out.appendSlice(self.a, "**");
            },
            .strikethrough => {
                try out.appendSlice(self.a, "~~");
                try out.appendSlice(self.a, try self.inlines(n, ctx));
                try out.appendSlice(self.a, "~~");
            },
            .link, .image => {
                if (n.kind == .image) try out.append(self.a, '!');
                try out.append(self.a, '[');
                try out.appendSlice(self.a, try self.inlines(n, ctx));
                try out.appendSlice(self.a, "](");
                try self.destination(&out, n.literal);
                if (n.title.len != 0) {
                    try out.appendSlice(self.a, " \"");
                    for (n.title) |c| {
                        if (c == '"' or c == '\\') try out.append(self.a, '\\');
                        try out.append(self.a, c);
                    }
                    try out.append(self.a, '"');
                }
                try out.append(self.a, ')');
            },
            .footnote_ref => {
                try out.appendSlice(self.a, "[^");
                try out.appendSlice(self.a, n.literal);
                try out.append(self.a, ']');
            },
            .softbreak => try out.append(self.a, '\n'),
            .linebreak => try out.appendSlice(self.a, "\\\n"),
            else => {},
        }
        return out.items;
    }

    /// Is the emphasis `n` written next to a letter or digit? `_` would not
    /// open or close emphasis there.
    fn intraword(self: *Gen, n: *Node) bool {
        _ = self;
        // `_` directly inside `_` would read as `__`.
        if (n.first_child) |f| if (f.kind == .emph or f.kind == .strong) return true;
        if (n.last_child) |l| if (l.kind == .emph or l.kind == .strong) return true;
        if (n.prev) |p| {
            if (p.kind == .text and p.literal.len != 0 and std.ascii.isAlphanumeric(p.literal[p.literal.len - 1])) return true;
            if (p.kind == .code or p.kind == .emph or p.kind == .strong) return true;
        }
        if (n.next) |nx| {
            if (nx.kind == .text and nx.literal.len != 0 and std.ascii.isAlphanumeric(nx.literal[0])) return true;
            if (nx.kind == .code or nx.kind == .emph or nx.kind == .strong) return true;
        }
        return false;
    }

    fn codeSpan(self: *Gen, out: *std.ArrayList(u8), lit: []const u8) Error!void {
        // The fence is a backtick run no other run in the code can equal.
        var longest: usize = 0;
        var run: usize = 0;
        for (lit) |c| {
            if (c == '`') {
                run += 1;
                longest = @max(longest, run);
            } else run = 0;
        }
        // Find a length not used by any run.
        var len: usize = 1;
        while (true) : (len += 1) {
            var used = false;
            var r: usize = 0;
            for (lit, 0..) |c, i| {
                if (c == '`') r += 1;
                if (c != '`' or i + 1 == lit.len or lit[i + 1] != '`') {
                    if (c == '`' and r == len) used = true;
                    r = 0;
                }
            }
            if (!used) break;
        }
        const pad = lit.len != 0 and (lit[0] == '`' or lit[lit.len - 1] == '`' or
            (lit[0] == ' ' and lit[lit.len - 1] == ' ' and std.mem.trim(u8, lit, " ").len != 0));
        try out.appendNTimes(self.a, '`', len);
        if (pad) try out.append(self.a, ' ');
        for (lit) |c| {
            if (c == '|' and self.in_cell) try out.append(self.a, '\\');
            try out.append(self.a, c);
        }
        if (pad) try out.append(self.a, ' ');
        try out.appendNTimes(self.a, '`', len);
    }

    fn destination(self: *Gen, out: *std.ArrayList(u8), dest: []const u8) Error!void {
        var plain = dest.len != 0;
        var depth: i32 = 0;
        for (dest) |c| {
            if (c <= ' ' or c == 0x7F) plain = false;
            if (c == '(') depth += 1;
            if (c == ')') {
                depth -= 1;
                if (depth < 0) plain = false;
            }
        }
        if (depth != 0) plain = false;
        if (plain) {
            for (dest, 0..) |c, i| {
                if (c == '\\' or (c == '&' and i + 1 < dest.len and (std.ascii.isAlphanumeric(dest[i + 1]) or dest[i + 1] == '#')) or c == '<' and i == 0)
                    try out.append(self.a, '\\');
                try out.append(self.a, c);
            }
            return;
        }
        try out.append(self.a, '<');
        for (dest, 0..) |c, i| {
            if (c == '\n') {
                try out.appendSlice(self.a, "%0A");
                continue;
            }
            if (c == '<' or c == '>' or c == '\\' or (c == '&' and i + 1 < dest.len and (std.ascii.isAlphanumeric(dest[i + 1]) or dest[i + 1] == '#')))
                try out.append(self.a, '\\');
            try out.append(self.a, c);
        }
        try out.append(self.a, '>');
    }

    /// Text with a backslash before whatever might start markup.
    fn escape(self: *Gen, out: *std.ArrayList(u8), s: []const u8, after: ?*Node, bol: bool) Error!void {
        var at_start = bol;
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            const next: u8 = if (i + 1 < s.len) s[i + 1] else 0;
            var esc = false;
            switch (c) {
                '\n' => {
                    try out.appendSlice(self.a, "&#10;");
                    continue;
                },
                '\r' => {
                    try out.appendSlice(self.a, "&#13;");
                    continue;
                },
                ' ', '\t' => if (at_start) {
                    try out.appendSlice(self.a, if (c == ' ') "&#32;" else "&#9;");
                    at_start = false;
                    continue;
                },
                '\\', '`', '*', '[', ']', '<' => esc = true,
                '_' => {
                    // Inside a word `_` cannot open or close emphasis.
                    const prev_alnum = if (i > 0) std.ascii.isAlphanumeric(s[i - 1]) else false;
                    const next_alnum = std.ascii.isAlphanumeric(next);
                    esc = !(prev_alnum and next_alnum);
                },
                '&' => esc = std.ascii.isAlphanumeric(next) or next == '#',
                '!' => esc = next == '[' or (i + 1 == s.len and after != null and (after.?.kind == .link or after.?.kind == .footnote_ref)),
                '~' => esc = self.ext.strikethrough or at_start,
                '|' => esc = self.ext.tables or self.in_cell,
                '#', '>', '-', '+', '=' => esc = at_start,
                ':' => esc = at_start and self.ext.definition_lists,
                '0'...'9' => {
                    if (at_start) {
                        var j = i;
                        while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
                        if (j < s.len and (s[j] == '.' or s[j] == ')')) {
                            try out.appendSlice(self.a, s[i..j]);
                            try out.append(self.a, '\\');
                            try out.append(self.a, s[j]);
                            i = j;
                            at_start = false;
                            continue;
                        }
                    }
                },
                else => {},
            }
            if (esc) try out.append(self.a, '\\');
            try out.append(self.a, c);
            if (c != ' ' and c != '\t') at_start = false;
        }
    }
};
