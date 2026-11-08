//! The inline parser: turns the raw text of a paragraph or heading into
//! emphasis, links, code spans and so on. It follows the CommonMark spec's
//! appendix "A parsing strategy" (delimiter stack for emphasis, bracket stack
//! for links).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const text = @import("text.zig");
const scan = @import("scan.zig");
const unicode = @import("unicode.zig");
const opts = @import("options.zig");
const autolink = @import("autolink.zig");
const Node = ast.Node;

pub const Ref = struct { destination: []const u8, title: []const u8 };
pub const RefMap = std.StringHashMapUnmanaged(Ref);

const Delim = struct {
    cc: u8,
    num: usize,
    orig: usize,
    node: *Node,
    prev: ?*Delim,
    next: ?*Delim = null,
    can_open: bool,
    can_close: bool,
};

const Bracket = struct {
    node: *Node,
    prev: ?*Bracket,
    prev_delim: ?*Delim,
    index: usize,
    image: bool,
    active: bool = true,
    bracket_after: bool = false,
};

const Inl = struct {
    a: Allocator,
    refs: *const RefMap,
    ext: opts.Extensions = .{},
    footnotes: ?*const std.StringHashMapUnmanaged(*Node) = null,
    subject: []const u8,
    pos: usize = 0,
    delims: ?*Delim = null,
    brackets: ?*Bracket = null,

    fn peek(self: *const Inl) ?u8 {
        return if (self.pos < self.subject.len) self.subject[self.pos] else null;
    }

    fn newNode(self: *Inl, kind: ast.Kind) Allocator.Error!*Node {
        const n = try self.a.create(Node);
        n.* = .{ .kind = kind };
        return n;
    }

    fn newText(self: *Inl, s: []const u8) Allocator.Error!*Node {
        const n = try self.newNode(.text);
        n.literal = s;
        return n;
    }

    // ---- main loop -------------------------------------------------------------------

    fn parseAll(self: *Inl, block: *Node) Allocator.Error!void {
        while (self.pos < self.subject.len) try self.parseInline(block);
        try self.processEmphasis(null);
    }

    fn parseInline(self: *Inl, block: *Node) Allocator.Error!void {
        const c = self.subject[self.pos];
        const handled = switch (c) {
            '\n' => try self.parseNewline(block),
            '\\' => try self.parseBackslash(block),
            '`' => try self.parseBackticks(block),
            '*', '_' => try self.handleDelim(c, block),
            '~' => if (self.ext.strikethrough) try self.handleDelim(c, block) else try self.parseString(block),
            '[' => try self.parseOpenBracket(block),
            '!' => try self.parseBang(block),
            ']' => try self.parseCloseBracket(block),
            '<' => try self.parseAutolink(block) or try self.parseHtmlTag(block),
            '&' => try self.parseEntity(block),
            else => try self.parseString(block),
        };
        if (!handled) {
            self.pos += 1;
            block.appendChild(try self.newText(self.subject[self.pos - 1 .. self.pos]));
        }
    }

    fn parseString(self: *Inl, block: *Node) Allocator.Error!bool {
        const start = self.pos;
        while (self.pos < self.subject.len) {
            const c = self.subject[self.pos];
            if (std.mem.findScalar(u8, "\n`[]\\!<&*_~", c) != null and (c != '~' or self.ext.strikethrough)) break;
            self.pos += 1;
        }
        if (self.pos == start) return false;
        block.appendChild(try self.newText(self.subject[start..self.pos]));
        return true;
    }

    fn parseNewline(self: *Inl, block: *Node) Allocator.Error!bool {
        self.pos += 1; // the newline
        var hard = false;
        if (block.last_child) |last| {
            if (last.kind == .text and last.literal.len > 0 and last.literal[last.literal.len - 1] == ' ') {
                hard = last.literal.len >= 2 and last.literal[last.literal.len - 2] == ' ';
                last.literal = std.mem.trimEnd(u8, last.literal, " ");
            }
        }
        block.appendChild(try self.newNode(if (hard) .linebreak else .softbreak));
        // Leading spaces of the next line are dropped.
        while (self.pos < self.subject.len and self.subject[self.pos] == ' ') self.pos += 1;
        return true;
    }

    fn parseBackslash(self: *Inl, block: *Node) Allocator.Error!bool {
        self.pos += 1;
        if (self.peek()) |c| {
            if (c == '\n') {
                self.pos += 1;
                block.appendChild(try self.newNode(.linebreak));
                while (self.pos < self.subject.len and self.subject[self.pos] == ' ') self.pos += 1;
                return true;
            }
            if (unicode.isAsciiPunct(c)) {
                block.appendChild(try self.newText(self.subject[self.pos .. self.pos + 1]));
                self.pos += 1;
                return true;
            }
        }
        block.appendChild(try self.newText("\\"));
        return true;
    }

    fn parseBackticks(self: *Inl, block: *Node) Allocator.Error!bool {
        const s = self.subject;
        var p = self.pos;
        while (p < s.len and s[p] == '`') p += 1;
        const ticks = p - self.pos;
        const after_open = p;
        // Look for a closing run of exactly the same length.
        var q = after_open;
        while (q < s.len) {
            const run_start = std.mem.findScalarPos(u8, s, q, '`') orelse break;
            var run_end = run_start;
            while (run_end < s.len and s[run_end] == '`') run_end += 1;
            if (run_end - run_start == ticks) {
                const raw = s[after_open..run_start];
                // Line endings become spaces; one space is stripped from both
                // ends when both are spaces and the content is not all spaces.
                var buf = try self.a.dupe(u8, raw);
                for (buf) |*ch| if (ch.* == '\n') {
                    ch.* = ' ';
                };
                if (buf.len >= 2 and buf[0] == ' ' and buf[buf.len - 1] == ' ' and std.mem.findNone(u8, buf, " ") != null) {
                    buf = buf[1 .. buf.len - 1];
                }
                const n = try self.newNode(.code);
                n.literal = buf;
                block.appendChild(n);
                self.pos = run_end;
                return true;
            }
            q = run_end;
        }
        block.appendChild(try self.newText(s[self.pos..after_open]));
        self.pos = after_open;
        return true;
    }

    fn parseEntity(self: *Inl, block: *Node) Allocator.Error!bool {
        const n = text.matchEntity(self.subject, self.pos) orelse return false;
        var out: std.ArrayList(u8) = .empty;
        try text.appendEntity(&out, self.a, self.subject[self.pos .. self.pos + n]);
        block.appendChild(try self.newText(out.items));
        self.pos += n;
        return true;
    }

    fn parseAutolink(self: *Inl, block: *Node) Allocator.Error!bool {
        const s = self.subject;
        if (scan.emailAutolink(s, self.pos)) |end| {
            const dest = s[self.pos + 1 .. end - 1];
            const link = try self.newNode(.link);
            link.literal = try text.encodeUrl(self.a, try std.mem.concat(self.a, u8, &.{ "mailto:", dest }));
            link.appendChild(try self.newText(dest));
            block.appendChild(link);
            self.pos = end;
            return true;
        }
        if (scan.uriAutolink(s, self.pos)) |end| {
            const dest = s[self.pos + 1 .. end - 1];
            const link = try self.newNode(.link);
            link.literal = try text.encodeUrl(self.a, dest);
            link.appendChild(try self.newText(dest));
            block.appendChild(link);
            self.pos = end;
            return true;
        }
        return false;
    }

    fn parseHtmlTag(self: *Inl, block: *Node) Allocator.Error!bool {
        const end = scan.htmlInline(self.subject, self.pos) orelse return false;
        const n = try self.newNode(.html_inline);
        n.literal = self.subject[self.pos..end];
        block.appendChild(n);
        self.pos = end;
        return true;
    }

    // ---- emphasis ----------------------------------------------------------------------

    const Scan = struct { num: usize, can_open: bool, can_close: bool };

    fn scanDelims(self: *Inl, cc: u8) Scan {
        const s = self.subject;
        const start = self.pos;
        var p = start;
        while (p < s.len and s[p] == cc) p += 1;
        const num = p - start;

        const before: u21 = if (start == 0) '\n' else unicode.decodeBefore(s, start);
        const after: u21 = if (p >= s.len) '\n' else unicode.decodeAt(s, p).cp;
        const after_ws = unicode.isUnicodeWhitespace(after);
        const after_punct = unicode.isUnicodePunct(after);
        const before_ws = unicode.isUnicodeWhitespace(before);
        const before_punct = unicode.isUnicodePunct(before);

        const left = !after_ws and (!after_punct or before_ws or before_punct);
        const right = !before_ws and (!before_punct or after_ws or after_punct);
        if (cc == '_') {
            return .{ .num = num, .can_open = left and (!right or before_punct), .can_close = right and (!left or after_punct) };
        }
        return .{ .num = num, .can_open = left, .can_close = right };
    }

    fn handleDelim(self: *Inl, cc: u8, block: *Node) Allocator.Error!bool {
        const res = self.scanDelims(cc);
        const start = self.pos;
        self.pos += res.num;
        const node = try self.newText(self.subject[start..self.pos]);
        block.appendChild(node);
        // Strikethrough uses runs of one or two tildes only.
        const usable = cc != '~' or res.num <= 2;
        if (usable and (res.can_open or res.can_close)) {
            const d = try self.a.create(Delim);
            d.* = .{
                .cc = cc,
                .num = res.num,
                .orig = res.num,
                .node = node,
                .prev = self.delims,
                .can_open = res.can_open,
                .can_close = res.can_close,
            };
            if (d.prev) |p| p.next = d;
            self.delims = d;
        }
        return true;
    }

    fn removeDelimiter(self: *Inl, d: *Delim) void {
        if (d.prev) |p| p.next = d.next;
        if (d.next) |n| n.prev = d.prev else self.delims = d.prev;
    }

    fn removeDelimitersBetween(bottom: *Delim, top: *Delim) void {
        if (bottom.next != top) {
            bottom.next = top;
            top.prev = bottom;
        }
    }

    fn processEmphasis(self: *Inl, stack_bottom: ?*Delim) Allocator.Error!void {
        // Per kind of closer, how far down openers were already searched in vain.
        var openers_bottom: [13]?*Delim = @splat(stack_bottom);

        var closer = self.delims;
        while (closer != null and closer.?.prev != stack_bottom) closer = closer.?.prev;

        while (closer) |cl| {
            if (!cl.can_close) {
                closer = cl.next;
                continue;
            }
            if (cl.cc == '~') {
                closer = try self.closeStrikethrough(cl, stack_bottom, &openers_bottom[12]);
                continue;
            }
            // Closers of different kinds, openness and length mod 3 can match
            // different openers, so each combination keeps its own search limit.
            const slot: usize = (if (cl.cc == '_') @as(usize, 0) else 6) + (if (cl.can_open) @as(usize, 3) else 0) + cl.orig % 3;

            var opener = cl.prev;
            var found = false;
            while (opener != null and opener != stack_bottom and opener != openers_bottom[slot]) : (opener = opener.?.prev) {
                const op = opener.?;
                const odd_match = (cl.can_open or op.can_close) and cl.orig % 3 != 0 and (op.orig + cl.orig) % 3 == 0;
                if (op.cc == cl.cc and op.can_open and !odd_match) {
                    found = true;
                    break;
                }
            }

            const old_closer = cl;
            if (found) {
                const op = opener.?;
                const use: usize = if (cl.num >= 2 and op.num >= 2) 2 else 1;
                const op_node = op.node;
                const cl_node = cl.node;
                op.num -= use;
                cl.num -= use;
                op_node.literal = op_node.literal[0 .. op_node.literal.len - use];
                cl_node.literal = cl_node.literal[0 .. cl_node.literal.len - use];

                const emph = try self.newNode(if (use == 1) .emph else .strong);
                var tmp = op_node.next;
                while (tmp) |t| {
                    if (t == cl_node) break;
                    const next = t.next;
                    t.unlink();
                    emph.appendChild(t);
                    tmp = next;
                }
                op_node.insertAfter(emph);
                removeDelimitersBetween(op, cl);
                if (op.num == 0) {
                    op_node.unlink();
                    self.removeDelimiter(op);
                }
                if (cl.num == 0) {
                    cl_node.unlink();
                    const next = cl.next;
                    self.removeDelimiter(cl);
                    closer = next;
                }
                // else: the same closer is tried again with what is left of it
            } else {
                closer = cl.next;
                openers_bottom[slot] = old_closer.prev;
                if (!old_closer.can_open) self.removeDelimiter(old_closer);
            }
        }

        while (self.delims != null and self.delims != stack_bottom) self.removeDelimiter(self.delims.?);
    }

    /// Matches a `~` closer with an opener of the same length. Returns the
    /// delimiter to continue with.
    fn closeStrikethrough(self: *Inl, cl: *Delim, stack_bottom: ?*Delim, bottom: *?*Delim) Allocator.Error!?*Delim {
        var opener = cl.prev;
        while (opener != null and opener != stack_bottom and opener != bottom.*) : (opener = opener.?.prev) {
            const op = opener.?;
            if (op.cc == '~' and op.can_open and op.num == cl.num) break;
        } else {
            // Nothing to match: remember where the search failed.
            bottom.* = cl.prev;
            const next = cl.next;
            if (!cl.can_open) self.removeDelimiter(cl);
            return next;
        }
        const op = opener.?;
        const del = try self.newNode(.strikethrough);
        var tmp = op.node.next;
        while (tmp) |t| {
            if (t == cl.node) break;
            const next = t.next;
            t.unlink();
            del.appendChild(t);
            tmp = next;
        }
        op.node.insertAfter(del);
        removeDelimitersBetween(op, cl);
        op.node.unlink();
        cl.node.unlink();
        self.removeDelimiter(op);
        const next = cl.next;
        self.removeDelimiter(cl);
        return next;
    }

    // ---- links and images --------------------------------------------------------------

    fn addBracket(self: *Inl, node: *Node, index: usize, image: bool) Allocator.Error!void {
        if (self.brackets) |b| b.bracket_after = true;
        const b = try self.a.create(Bracket);
        b.* = .{ .node = node, .prev = self.brackets, .prev_delim = self.delims, .index = index, .image = image };
        self.brackets = b;
    }

    fn parseOpenBracket(self: *Inl, block: *Node) Allocator.Error!bool {
        const start = self.pos;
        self.pos += 1;
        const node = try self.newText("[");
        block.appendChild(node);
        try self.addBracket(node, start, false);
        return true;
    }

    fn parseBang(self: *Inl, block: *Node) Allocator.Error!bool {
        const start = self.pos;
        self.pos += 1;
        // With footnotes, `![^x]` is a "!" followed by a footnote reference.
        if (self.ext.footnotes and self.peek() == '[' and self.pos + 1 < self.subject.len and self.subject[self.pos + 1] == '^') {
            block.appendChild(try self.newText("!"));
            return true;
        }
        if (self.peek() == '[') {
            self.pos += 1;
            const node = try self.newText("![");
            block.appendChild(node);
            try self.addBracket(node, start + 1, true);
        } else {
            block.appendChild(try self.newText("!"));
        }
        return true;
    }

    fn spnl(self: *Inl) void {
        const s = self.subject;
        while (self.pos < s.len and s[self.pos] == ' ') self.pos += 1;
        if (self.pos < s.len and s[self.pos] == '\n') {
            self.pos += 1;
            while (self.pos < s.len and s[self.pos] == ' ') self.pos += 1;
        }
    }

    /// Length of a `[label]` at the current position (brackets included), or 0.
    fn parseLinkLabel(self: *Inl) usize {
        const s = self.subject;
        if (self.pos >= s.len or s[self.pos] != '[') return 0;
        var p = self.pos + 1;
        var items: usize = 0;
        while (p < s.len) {
            const c = s[p];
            if (c == ']') return p + 1 - self.pos;
            if (c == '[') return 0;
            if (c == '\\' and p + 1 < s.len) {
                p += 2;
            } else p += 1;
            items += 1;
            if (items > 1000) return 0;
        }
        return 0;
    }

    fn parseLinkDestination(self: *Inl) Allocator.Error!?[]const u8 {
        const s = self.subject;
        if (self.peek() == '<') {
            var p = self.pos + 1;
            while (p < s.len) {
                const c = s[p];
                if (c == '>') {
                    const raw = s[self.pos + 1 .. p];
                    self.pos = p + 1;
                    return try text.encodeUrl(self.a, try text.unescape(self.a, raw));
                }
                if (c == '<' or c == '\n' or c == 0) break;
                if (c == '\\' and p + 1 < s.len and s[p + 1] != '\n') {
                    p += 2;
                } else p += 1;
            }
            return null; // an opening < that never closes properly
        }
        const start = self.pos;
        var depth: usize = 0;
        var p = start;
        while (p < s.len) {
            const c = s[p];
            if (c == '\\' and p + 1 < s.len and unicode.isAsciiPunct(s[p + 1])) {
                p += 2;
            } else if (c == '(') {
                depth += 1;
                p += 1;
            } else if (c == ')') {
                if (depth == 0) break;
                depth -= 1;
                p += 1;
            } else if (c <= 0x20 or c == 0x7f) {
                break;
            } else p += 1;
        }
        if (p == start and (p >= s.len or s[p] != ')')) return null;
        if (depth != 0) return null;
        self.pos = p;
        return try text.encodeUrl(self.a, try text.unescape(self.a, s[start..p]));
    }

    fn parseLinkTitle(self: *Inl) Allocator.Error!?[]const u8 {
        const s = self.subject;
        if (self.pos >= s.len) return null;
        const open = s[self.pos];
        const close: u8 = switch (open) {
            '"' => '"',
            '\'' => '\'',
            '(' => ')',
            else => return null,
        };
        var p = self.pos + 1;
        while (p < s.len) {
            const c = s[p];
            if (c == '\\' and p + 1 < s.len and unicode.isAsciiPunct(s[p + 1])) {
                p += 2;
            } else if (c == close) {
                const raw = s[self.pos + 1 .. p];
                self.pos = p + 1;
                return try text.unescape(self.a, raw);
            } else if (open == '(' and c == '(') {
                return null;
            } else p += 1;
        }
        return null;
    }

    fn parseCloseBracket(self: *Inl, block: *Node) Allocator.Error!bool {
        self.pos += 1;
        const start = self.pos;

        const opener = self.brackets orelse {
            block.appendChild(try self.newText("]"));
            return true;
        };
        if (!opener.active) {
            block.appendChild(try self.newText("]"));
            self.brackets = opener.prev;
            return true;
        }

        const is_image = opener.image;
        const save = self.pos;
        var dest: ?[]const u8 = null;
        var title: ?[]const u8 = null;
        var matched = false;

        // A footnote reference: [^label] with a matching definition.
        var footnote_key: ?[]const u8 = null;
        if (self.ext.footnotes and !is_image and self.footnotes != null) {
            const inner = self.subject[opener.index + 1 .. start - 1];
            if (inner.len > 1 and inner[0] == '^' and std.mem.findAny(u8, inner, " \t\n[]") == null) {
                const key = try text.normalizeLabel(self.a, inner[1..]);
                if (self.footnotes.?.contains(key)) footnote_key = key;
            }
        }

        // An inline link: ( destination "title" )
        if (footnote_key != null) {
            matched = true;
        } else if (self.peek() == '(') {
            self.pos += 1;
            self.spnl();
            if (try self.parseLinkDestination()) |d| {
                dest = d;
                self.spnl();
                // A title needs white space before it.
                if (self.pos > 0 and text.isWhitespace(self.subject[self.pos - 1])) title = try self.parseLinkTitle();
                self.spnl();
                if (self.peek() == ')') {
                    self.pos += 1;
                    matched = true;
                }
            }
            if (!matched) self.pos = save;
        }

        if (!matched and footnote_key == null) {
            // A reference link: [text][label], [text][] or [text].
            const before_label = self.pos;
            const n = self.parseLinkLabel();
            var label: ?[]const u8 = null;
            if (n > 2) {
                label = self.subject[before_label .. before_label + n];
                self.pos = before_label + n;
            } else if (!opener.bracket_after) {
                label = self.subject[opener.index..start];
            }
            if (n == 0) self.pos = save;
            if (n == 2) self.pos = before_label + 2; // "[]" is consumed
            if (label) |l| {
                const key = try text.normalizeLabel(self.a, l[1 .. l.len - 1]);
                if (self.refs.get(key)) |ref| {
                    dest = ref.destination;
                    title = ref.title;
                    matched = true;
                }
            }
            if (!matched) self.pos = if (n == 0) save else self.pos;
        }

        if (matched) {
            const node = try self.newNode(if (footnote_key != null) .footnote_ref else if (is_image) .image else .link);
            node.literal = footnote_key orelse (dest orelse "");
            node.title = title orelse "";
            var tmp = opener.node.next;
            while (tmp) |t| {
                const next = t.next;
                t.unlink();
                node.appendChild(t);
                tmp = next;
            }
            block.appendChild(node);
            try self.processEmphasis(opener.prev_delim);
            self.brackets = opener.prev;
            opener.node.unlink();
            if (!is_image) {
                var o = self.brackets;
                while (o) |b| : (o = b.prev) {
                    if (!b.image) b.active = false;
                }
            }
            return true;
        }

        self.brackets = opener.prev;
        self.pos = start;
        block.appendChild(try self.newText("]"));
        return true;
    }
};

/// Parses a link reference definition at the start of `content` and stores it.
/// Returns the number of bytes it used, or 0 when there is none.
pub fn parseReference(a: Allocator, refs: *RefMap, content: []const u8) Allocator.Error!usize {
    var p: Inl = .{ .a = a, .refs = refs, .subject = content };
    const n = p.parseLinkLabel();
    if (n == 0) return 0;
    const raw_label = content[0..n];
    p.pos = n;
    if (p.peek() != ':') return 0;
    p.pos += 1;
    p.spnl();
    const dest = (try p.parseLinkDestination()) orelse return 0;

    const before_title = p.pos;
    p.spnl();
    var title: ?[]const u8 = null;
    if (p.pos != before_title) title = try p.parseLinkTitle();
    if (title == null) p.pos = before_title;

    var at_line_end = true;
    if (!atLineEnd(&p)) {
        if (title == null) {
            at_line_end = false;
        } else {
            // The title is not alone on its line; the reference may still be
            // valid without it.
            title = null;
            p.pos = before_title;
            at_line_end = atLineEnd(&p);
        }
    }
    if (!at_line_end) return 0;

    const key = try text.normalizeLabel(a, raw_label[1 .. raw_label.len - 1]);
    if (key.len == 0) return 0;
    const gop = try refs.getOrPut(a, key);
    if (!gop.found_existing) gop.value_ptr.* = .{ .destination = dest, .title = title orelse "" };
    return p.pos;
}

/// Consumes `' *(\n|$)'`.
fn atLineEnd(p: *Inl) bool {
    var q = p.pos;
    while (q < p.subject.len and p.subject[q] == ' ') q += 1;
    if (q >= p.subject.len) {
        p.pos = q;
        return true;
    }
    if (p.subject[q] == '\n') {
        p.pos = q + 1;
        return true;
    }
    return false;
}

/// Parses the inline content of every paragraph, heading and table cell below
/// `root`.
pub fn processTree(
    a: Allocator,
    root: *Node,
    refs: *const RefMap,
    footnotes: *const std.StringHashMapUnmanaged(*Node),
    ext: opts.Extensions,
) Allocator.Error!void {
    var walker = ast.Walker.init(root);
    while (walker.next()) |ev| {
        if (!ev.entering) continue;
        switch (ev.node.kind) {
            .paragraph, .heading, .table_cell, .deflist_term => {
                const node = ev.node;
                var p: Inl = .{
                    .a = a,
                    .refs = refs,
                    .ext = ext,
                    .footnotes = footnotes,
                    .subject = std.mem.trim(u8, node.literal, " \t\n\r\x0b\x0c"),
                };
                node.literal = "";
                try p.parseAll(node);
                if (ext.autolinks) try autolink.process(a, node);
            },
            else => {},
        }
    }
}
