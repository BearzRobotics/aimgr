//! The block parser: reads lines and builds the tree of blocks (quotes, lists,
//! code, headings, paragraphs, HTML). It follows the algorithm described in the
//! CommonMark spec's appendix "A parsing strategy": for each line, match the
//! open containers, try to start new blocks, then add the rest of the line to
//! the innermost open leaf. Inline content is parsed afterwards (inline.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const text = @import("text.zig");
const scan = @import("scan.zig");
const inl = @import("inline.zig");
const unicode = @import("unicode.zig");
const opts = @import("options.zig");
const Node = ast.Node;

const code_indent = 4;

pub const Parser = struct {
    a: Allocator,
    doc: *Node,
    tip: *Node,
    oldtip: *Node,
    last_matched: *Node,
    refs: inl.RefMap = .empty,
    ext: opts.Extensions,
    /// Footnote definitions by normalized label (first definition wins).
    footnotes: std.StringHashMapUnmanaged(*Node) = .empty,

    // Front matter: lines are held back until the closing fence shows up.
    fm_state: enum { unchecked, inside, done } = .unchecked,
    fm_lines: std.ArrayList([]const u8) = .empty,

    line: []const u8 = "",
    line_number: u32 = 0,
    offset: usize = 0,
    column: usize = 0,
    next_nonspace: usize = 0,
    next_nonspace_column: usize = 0,
    indent: usize = 0,
    indented: bool = false,
    blank: bool = false,
    partially_consumed_tab: bool = false,
    all_closed: bool = true,

    pub fn init(a: Allocator, ext: opts.Extensions) Allocator.Error!Parser {
        const doc = try a.create(Node);
        doc.* = .{ .kind = .document, .line = 1 };
        return .{ .a = a, .doc = doc, .tip = doc, .oldtip = doc, .last_matched = doc, .ext = ext };
    }

    // ---- helpers ---------------------------------------------------------------------

    /// The byte at `i` of the current line, or 0 past its end.
    fn at(self: *const Parser, i: usize) u8 {
        return if (i < self.line.len) self.line[i] else 0;
    }

    fn newNode(self: *Parser, kind: ast.Kind) Allocator.Error!*Node {
        const n = try self.a.create(Node);
        n.* = .{ .kind = kind, .line = self.line_number };
        return n;
    }

    fn findNextNonspace(self: *Parser) void {
        var i = self.offset;
        var cols = self.column;
        while (i < self.line.len) {
            const c = self.line[i];
            if (c == ' ') {
                i += 1;
                cols += 1;
            } else if (c == '\t') {
                i += 1;
                cols += 4 - (cols % 4);
            } else break;
        }
        self.blank = i >= self.line.len or self.line[i] == '\n' or self.line[i] == '\r';
        self.next_nonspace = i;
        self.next_nonspace_column = cols;
        self.indent = cols - self.column;
        self.indented = self.indent >= code_indent;
    }

    fn advanceNextNonspace(self: *Parser) void {
        self.offset = self.next_nonspace;
        self.column = self.next_nonspace_column;
        self.partially_consumed_tab = false;
    }

    /// Moves `count` characters (or columns, when `columns`) forward, splitting
    /// a tab when only part of it is consumed.
    fn advanceOffset(self: *Parser, count_in: usize, columns: bool) void {
        var count = count_in;
        while (count > 0 and self.offset < self.line.len) {
            const c = self.line[self.offset];
            if (c == '\t') {
                const to_tab = 4 - (self.column % 4);
                if (columns) {
                    self.partially_consumed_tab = to_tab > count;
                    const adv = if (to_tab > count) count else to_tab;
                    self.column += adv;
                    if (!self.partially_consumed_tab) self.offset += 1;
                    count -= adv;
                } else {
                    self.partially_consumed_tab = false;
                    self.column += to_tab;
                    self.offset += 1;
                    count -= 1;
                }
            } else {
                self.partially_consumed_tab = false;
                self.offset += 1;
                self.column += 1;
                count -= 1;
            }
        }
    }

    fn addLine(self: *Parser) Allocator.Error!void {
        // The line that starts a table (its delimiter row) adds nothing.
        if (self.tip.kind == .table and self.offset >= self.line.len) return;
        const content = &self.tip.build.content;
        if (self.partially_consumed_tab) {
            self.offset += 1; // the tab itself
            const to_tab = 4 - (self.column % 4);
            try content.appendNTimes(self.a, ' ', to_tab);
        }
        if (self.offset < self.line.len) try content.appendSlice(self.a, self.line[self.offset..]);
        try content.append(self.a, '\n');
    }

    fn canContain(parent: ast.Kind, child: ast.Kind) bool {
        return switch (parent) {
            .document, .block_quote, .item, .footnote_def, .deflist_def => child != .item and child != .deflist_def,
            .list => child == .item,
            .deflist => child == .deflist_def,
            else => false,
        };
    }

    fn acceptsLines(kind: ast.Kind) bool {
        return kind == .paragraph or kind == .code_block or kind == .html_block or kind == .table;
    }

    fn addChild(self: *Parser, kind: ast.Kind) Allocator.Error!*Node {
        while (!canContain(self.tip.kind, kind)) try self.finalize(self.tip);
        const n = try self.newNode(kind);
        self.tip.appendChild(n);
        self.tip = n;
        return n;
    }

    fn closeUnmatchedBlocks(self: *Parser) Allocator.Error!void {
        if (self.all_closed) return;
        while (self.oldtip != self.last_matched) {
            const parent = self.oldtip.parent.?;
            try self.finalize(self.oldtip);
            self.oldtip = parent;
        }
        self.all_closed = true;
    }

    // ---- finishing blocks ----------------------------------------------------------

    fn endsWithBlankLine(start: ?*Node) bool {
        var block = start;
        while (block) |b| {
            if (b.build.last_line_blank) return true;
            if (!b.build.last_line_checked and (b.kind == .list or b.kind == .item or b.kind == .deflist or b.kind == .deflist_def)) {
                b.build.last_line_checked = true;
                block = b.last_child;
            } else {
                b.build.last_line_checked = true;
                break;
            }
        }
        return false;
    }

    fn finalize(self: *Parser, block: *Node) Allocator.Error!void {
        const above = block.parent;
        block.build.open = false;
        switch (block.kind) {
            .paragraph => {
                var content: []const u8 = block.build.content.items;
                if (self.ext.task_lists) content = taskMarker(block, content);
                // Leading link reference definitions are removed from the paragraph.
                var had_defs = false;
                while (content.len > 0 and content[0] == '[') {
                    const used = try inl.parseReference(self.a, &self.refs, content);
                    if (used == 0) break;
                    content = content[used..];
                    had_defs = true;
                }
                block.literal = content;
                if (had_defs and isBlank(content)) block.unlink();
            },
            .heading => block.literal = block.build.content.items,
            .table => try self.buildTable(block),
            .code_block => {
                const content = block.build.content.items;
                if (block.build.fenced) {
                    // The first line is the info string; the rest is the code.
                    const nl = std.mem.findScalar(u8, content, '\n') orelse content.len;
                    const first = std.mem.trim(u8, content[0..nl], " \t");
                    block.title = try text.unescape(self.a, first);
                    block.literal = if (nl < content.len) content[nl + 1 ..] else "";
                } else {
                    // Trailing blank lines are not part of indented code: replace
                    // the final run of "\n *" with one newline.
                    const end = trailingBlankStart(content);
                    block.literal = content[0..@min(end + 1, content.len)];
                }
            },
            .html_block => {
                const content: []const u8 = block.build.content.items;
                block.literal = content[0..trailingBlankStart(content)];
            },
            .list => {
                var item = block.first_child;
                while (item) |it| : (item = it.next) {
                    if (endsWithBlankLine(it) and it.next != null) {
                        block.list.tight = false;
                        break;
                    }
                    var sub = it.first_child;
                    var loose = false;
                    while (sub) |s| : (sub = s.next) {
                        if (endsWithBlankLine(s) and (it.next != null or s.next != null)) {
                            loose = true;
                            break;
                        }
                    }
                    if (loose) {
                        block.list.tight = false;
                        break;
                    }
                }
            },
            .deflist => {
                var def = block.first_child;
                while (def) |d| : (def = d.next) {
                    if (d.kind != .deflist_def) continue;
                    if (endsWithBlankLine(d) and d.next != null) {
                        block.list.tight = false;
                        break;
                    }
                    var sub = d.first_child;
                    var loose = false;
                    while (sub) |s| : (sub = s.next) {
                        if (endsWithBlankLine(s) and (d.next != null or s.next != null)) {
                            loose = true;
                            break;
                        }
                    }
                    if (loose) {
                        block.list.tight = false;
                        break;
                    }
                }
            },
            else => {},
        }
        self.tip = above orelse self.doc;
    }

    // ---- continuation of open blocks -----------------------------------------------

    const Continue = enum { matched, not_matched, line_done };

    fn continueBlock(self: *Parser, container: *Node) Allocator.Error!Continue {
        switch (container.kind) {
            .document, .list, .deflist => return .matched,
            .block_quote => {
                if (!self.indented and self.at(self.next_nonspace) == '>') {
                    self.advanceNextNonspace();
                    self.advanceOffset(1, false);
                    if (text.isSpaceOrTab(self.at(self.offset))) self.advanceOffset(1, true);
                    return .matched;
                }
                return .not_matched;
            },
            .item, .deflist_def => {
                if (self.blank) {
                    // A blank line after an empty item ends it.
                    if (container.first_child == null) return .not_matched;
                    self.advanceNextNonspace();
                } else if (self.indent >= container.list.marker_offset + container.list.padding) {
                    self.advanceOffset(container.list.marker_offset + container.list.padding, true);
                } else return .not_matched;
                return .matched;
            },
            .heading, .thematic_break => return .not_matched,
            .code_block => {
                if (container.build.fenced) {
                    if (self.indent <= 3 and self.at(self.next_nonspace) == container.build.fence_char) {
                        if (closingFence(self.line[self.next_nonspace..], container.build.fence_char)) |len| {
                            if (len >= container.build.fence_length) {
                                try self.finalize(container);
                                return .line_done;
                            }
                        }
                    }
                    // Skip the fence's own indentation.
                    var i = container.build.fence_offset;
                    while (i > 0 and text.isSpaceOrTab(self.at(self.offset))) : (i -= 1) self.advanceOffset(1, true);
                } else {
                    if (self.indent >= code_indent) {
                        self.advanceOffset(code_indent, true);
                    } else if (self.blank) {
                        self.advanceNextNonspace();
                    } else return .not_matched;
                }
                return .matched;
            },
            .html_block => {
                const t = container.build.html_type;
                return if (self.blank and (t == 6 or t == 7)) .not_matched else .matched;
            },
            .paragraph => return if (self.blank) .not_matched else .matched,
            .table => {
                // A table ends at a blank line or where another block starts.
                if (self.blank or self.startsOtherBlock()) return .not_matched;
                return .matched;
            },
            .footnote_def => {
                if (self.blank) {
                    if (container.first_child == null) return .not_matched;
                    self.advanceNextNonspace();
                    return .matched;
                }
                if (self.indent < 4) return .not_matched;
                self.advanceOffset(4, true);
                return .matched;
            },
            else => return .not_matched,
        }
    }

    // ---- starting new blocks ---------------------------------------------------------

    /// 0: nothing started; 1: a container started; 2: a leaf started.
    fn tryBlockStart(self: *Parser, which: usize, container: *Node) Allocator.Error!u8 {
        switch (which) {
            0 => return self.startBlockQuote(),
            1 => return self.startAtxHeading(),
            2 => return self.startFencedCode(),
            3 => return self.startHtmlBlock(container),
            4 => return self.startFootnoteDef(),
            5 => return self.startDefinition(container),
            6 => return self.startTable(container),
            7 => return self.startSetextHeading(container),
            8 => return self.startThematicBreak(),
            9 => return self.startListItem(container),
            10 => return self.startIndentedCode(),
            else => unreachable,
        }
    }

    const block_start_count = 11;

    fn startBlockQuote(self: *Parser) Allocator.Error!u8 {
        if (self.indented or self.at(self.next_nonspace) != '>') return 0;
        self.advanceNextNonspace();
        self.advanceOffset(1, false);
        if (text.isSpaceOrTab(self.at(self.offset))) self.advanceOffset(1, true);
        try self.closeUnmatchedBlocks();
        _ = try self.addChild(.block_quote);
        return 1;
    }

    fn startAtxHeading(self: *Parser) Allocator.Error!u8 {
        if (self.indented) return 0;
        const rest = self.line[self.next_nonspace..];
        var hashes: usize = 0;
        while (hashes < rest.len and rest[hashes] == '#') hashes += 1;
        if (hashes == 0 or hashes > 6) return 0;
        if (hashes < rest.len and !text.isSpaceOrTab(rest[hashes])) return 0;
        var marker = hashes;
        while (marker < rest.len and text.isSpaceOrTab(rest[marker])) marker += 1;

        self.advanceNextNonspace();
        self.advanceOffset(marker, false);
        try self.closeUnmatchedBlocks();
        const h = try self.addChild(.heading);
        h.level = @intCast(hashes);
        h.build.content = .empty;
        try h.build.content.appendSlice(self.a, atxContent(self.line[self.offset..]));
        self.advanceOffset(self.line.len - self.offset, false);
        return 2;
    }

    /// Where the final run of "\n *" groups of `content` starts (its length when
    /// there is none).
    fn trailingBlankStart(content: []const u8) usize {
        var end = content.len;
        while (true) {
            var p = end;
            while (p > 0 and content[p - 1] == ' ') p -= 1;
            if (p > 0 and content[p - 1] == '\n') end = p - 1 else break;
        }
        return end;
    }

    /// The heading text with the optional closing run of `#` removed.
    fn atxContent(rest: []const u8) []const u8 {
        const trimmed = std.mem.trimEnd(u8, rest, " \t");
        var k: usize = 0;
        while (k < trimmed.len and trimmed[trimmed.len - 1 - k] == '#') k += 1;
        if (k == 0) return rest;
        const prefix = trimmed[0 .. trimmed.len - k];
        // Only hashes: an empty heading.
        if (std.mem.trim(u8, prefix, " \t").len == 0) return "";
        // A closing run must follow a space or tab.
        if (text.isSpaceOrTab(prefix[prefix.len - 1])) return std.mem.trimEnd(u8, prefix, " \t");
        return rest;
    }

    /// Length of an opening code fence at the start of `rest`, or null.
    fn openingFence(rest: []const u8) ?usize {
        if (rest.len < 3) return null;
        const c = rest[0];
        if (c != '`' and c != '~') return null;
        var n: usize = 0;
        while (n < rest.len and rest[n] == c) n += 1;
        if (n < 3) return null;
        // A backtick fence's info string may not contain a backtick.
        if (c == '`' and std.mem.findScalar(u8, rest[n..], '`') != null) return null;
        return n;
    }

    /// Length of a closing fence (only the fence character, then blanks).
    fn closingFence(rest: []const u8, c: u8) ?usize {
        var n: usize = 0;
        while (n < rest.len and rest[n] == c) n += 1;
        if (n < 3) return null;
        for (rest[n..]) |ch| if (!text.isSpaceOrTab(ch)) return null;
        return n;
    }

    fn startFencedCode(self: *Parser) Allocator.Error!u8 {
        if (self.indented) return 0;
        const len = openingFence(self.line[self.next_nonspace..]) orelse return 0;
        try self.closeUnmatchedBlocks();
        const c = try self.addChild(.code_block);
        c.build.fenced = true;
        c.build.fence_length = len;
        c.build.fence_char = self.line[self.next_nonspace];
        c.build.fence_offset = self.indent;
        self.advanceNextNonspace();
        self.advanceOffset(len, false);
        return 2;
    }

    fn startsWithNoCase(s: []const u8, prefix: []const u8) bool {
        return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
    }

    const block_tags = [_][]const u8{
        "address",  "article",  "aside",    "base",       "basefont", "blockquote", "body",   "caption",
        "center",   "col",      "colgroup", "dd",         "details",  "dialog",     "dir",    "div",
        "dl",       "dt",       "fieldset", "figcaption", "figure",   "footer",     "form",   "frame",
        "frameset", "h1",       "h2",       "h3",         "h4",       "h5",         "h6",     "head",
        "header",   "hr",       "html",     "iframe",     "legend",   "li",         "link",   "main",
        "menu",     "menuitem", "nav",      "noframes",   "ol",       "optgroup",   "option", "p",
        "param",    "search",   "section",  "summary",    "table",    "tbody",      "td",     "tfoot",
        "th",       "thead",    "title",    "tr",         "track",    "ul",
    };

    /// Which kind (1 to 7) of HTML block starts at `s`, or 0.
    fn htmlBlockKind(s: []const u8) u8 {
        if (s.len == 0 or s[0] != '<') return 0;
        // 1: <script, <pre, <textarea, <style
        inline for (.{ "script", "pre", "textarea", "style" }) |name| {
            if (startsWithNoCase(s[1..], name)) {
                const after = 1 + name.len;
                if (after >= s.len or text.isWhitespace(s[after]) or s[after] == '>') return 1;
            }
        }
        if (std.mem.startsWith(u8, s, "<!--")) return 2;
        if (std.mem.startsWith(u8, s, "<?")) return 3;
        if (s.len > 2 and s[1] == '!' and std.ascii.isAlphabetic(s[2])) return 4;
        if (std.mem.startsWith(u8, s, "<![CDATA[")) return 5;
        // 6: a block-level tag name.
        var p: usize = 1;
        if (p < s.len and s[p] == '/') p += 1;
        const name_start = p;
        while (p < s.len and std.ascii.isAlphanumeric(s[p])) p += 1;
        if (p > name_start) {
            const name = s[name_start..p];
            for (block_tags) |t| {
                if (std.ascii.eqlIgnoreCase(t, name)) {
                    if (p >= s.len or text.isWhitespace(s[p]) or s[p] == '>') return 6;
                    if (s[p] == '/' and p + 1 < s.len and s[p + 1] == '>') return 6;
                }
            }
        }
        // 7: any complete open or closing tag alone on the line.
        const end = scan.openTag(s, 0) orelse scan.closeTag(s, 0) orelse return 0;
        for (s[end..]) |ch| if (!text.isWhitespace(ch)) return 0;
        return 7;
    }

    fn htmlBlockEnds(kind: u8, s: []const u8) bool {
        return switch (kind) {
            1 => blk: {
                inline for (.{ "</script>", "</pre>", "</textarea>", "</style>" }) |t| {
                    var i: usize = 0;
                    while (i + t.len <= s.len) : (i += 1) {
                        if (startsWithNoCase(s[i..], t)) break :blk true;
                    }
                }
                break :blk false;
            },
            2 => std.mem.find(u8, s, "-->") != null,
            3 => std.mem.find(u8, s, "?>") != null,
            4 => std.mem.findScalar(u8, s, '>') != null,
            5 => std.mem.find(u8, s, "]]>") != null,
            else => false,
        };
    }

    fn startHtmlBlock(self: *Parser, container: *Node) Allocator.Error!u8 {
        if (self.indented or self.at(self.next_nonspace) != '<') return 0;
        const kind = htmlBlockKind(self.line[self.next_nonspace..]);
        if (kind == 0) return 0;
        // Type 7 cannot interrupt a paragraph.
        if (kind == 7 and (container.kind == .paragraph or (!self.all_closed and !self.blank and self.tip.kind == .paragraph))) return 0;
        try self.closeUnmatchedBlocks();
        const b = try self.addChild(.html_block);
        b.build.html_type = kind;
        return 2;
    }

    fn startSetextHeading(self: *Parser, container: *Node) Allocator.Error!u8 {
        if (self.indented or container.kind != .paragraph) return 0;
        const rest = self.line[self.next_nonspace..];
        if (rest.len == 0 or (rest[0] != '=' and rest[0] != '-')) return 0;
        var n: usize = 0;
        while (n < rest.len and rest[n] == rest[0]) n += 1;
        for (rest[n..]) |c| if (!text.isSpaceOrTab(c)) return 0;

        try self.closeUnmatchedBlocks();
        // Link reference definitions at the start of the paragraph are removed first.
        var content: []const u8 = container.build.content.items;
        while (content.len > 0 and content[0] == '[') {
            const used = try inl.parseReference(self.a, &self.refs, content);
            if (used == 0) break;
            content = content[used..];
        }
        if (content.len == 0) return 0;
        const h = try self.newNode(.heading);
        h.line = container.line;
        h.level = if (rest[0] == '=') 1 else 2;
        h.build.content = .empty;
        try h.build.content.appendSlice(self.a, content);
        container.insertAfter(h);
        container.unlink();
        self.tip = h;
        self.advanceOffset(self.line.len - self.offset, false);
        return 2;
    }

    fn isThematicBreak(s: []const u8) bool {
        if (s.len == 0) return false;
        const c = s[0];
        if (c != '*' and c != '_' and c != '-') return false;
        var count: usize = 0;
        for (s) |ch| {
            if (ch == c) {
                count += 1;
            } else if (!text.isSpaceOrTab(ch)) return false;
        }
        return count >= 3;
    }

    fn startThematicBreak(self: *Parser) Allocator.Error!u8 {
        if (self.indented or !isThematicBreak(self.line[self.next_nonspace..])) return 0;
        try self.closeUnmatchedBlocks();
        _ = try self.addChild(.thematic_break);
        self.advanceOffset(self.line.len - self.offset, false);
        return 2;
    }

    /// Reads a list marker at the next non-space; on success the parser is past
    /// the marker and its spacing.
    fn parseListMarker(self: *Parser, container: *Node) ?ast.ListData {
        if (self.indent >= 4) return null;
        const rest = self.line[self.next_nonspace..];
        var data: ast.ListData = .{ .marker_offset = self.indent };
        var marker_len: usize = 0;
        if (rest.len > 0 and (rest[0] == '*' or rest[0] == '+' or rest[0] == '-')) {
            data.kind = .bullet;
            data.bullet_char = rest[0];
            marker_len = 1;
        } else {
            var d: usize = 0;
            while (d < rest.len and d < 9 and std.ascii.isDigit(rest[d])) d += 1;
            if (d == 0 or d >= rest.len or (rest[d] != '.' and rest[d] != ')')) return null;
            const start = std.fmt.parseInt(u32, rest[0..d], 10) catch return null;
            if (container.kind == .paragraph and start != 1) return null;
            data.kind = .ordered;
            data.start = start;
            data.delimiter = rest[d];
            marker_len = d + 1;
        }
        // The marker needs a space, tab or the end of the line after it.
        const after = self.next_nonspace + marker_len;
        if (after < self.line.len and !text.isSpaceOrTab(self.line[after])) return null;
        // An item that starts a paragraph cannot be empty.
        if (container.kind == .paragraph) {
            var blank = true;
            for (self.line[after..]) |c| if (!text.isWhitespace(c)) {
                blank = false;
                break;
            };
            if (blank) return null;
        }

        self.advanceNextNonspace();
        self.advanceOffset(marker_len, true);
        const spaces_start_col = self.column;
        const spaces_start_offset = self.offset;
        while (true) {
            self.advanceOffset(1, true);
            if (!(self.column - spaces_start_col < 5 and text.isSpaceOrTab(self.at(self.offset)))) break;
        }
        const blank_item = self.offset >= self.line.len;
        const spaces_after = self.column - spaces_start_col;
        if (spaces_after >= 5 or spaces_after < 1 or blank_item) {
            data.padding = marker_len + 1;
            self.column = spaces_start_col;
            self.offset = spaces_start_offset;
            if (text.isSpaceOrTab(self.at(self.offset))) self.advanceOffset(1, true);
        } else {
            data.padding = marker_len + spaces_after;
        }
        return data;
    }

    fn listsMatch(a: ast.ListData, b: ast.ListData) bool {
        return a.kind == b.kind and a.delimiter == b.delimiter and a.bullet_char == b.bullet_char;
    }

    fn startListItem(self: *Parser, container: *Node) Allocator.Error!u8 {
        if (self.indented and container.kind != .list) return 0;
        const data = self.parseListMarker(container) orelse return 0;
        try self.closeUnmatchedBlocks();
        if (self.tip.kind != .list or !listsMatch(self.tip.list, data)) {
            const l = try self.addChild(.list);
            l.list = data;
        }
        const item = try self.addChild(.item);
        item.list = data;
        return 1;
    }

    fn startIndentedCode(self: *Parser) Allocator.Error!u8 {
        if (!self.indented or self.tip.kind == .paragraph or self.blank) return 0;
        self.advanceOffset(code_indent, true);
        try self.closeUnmatchedBlocks();
        _ = try self.addChild(.code_block);
        return 2;
    }

    fn maybeSpecial(self: *const Parser, c: u8) bool {
        if (std.mem.findScalar(u8, "#`~*+_=<>-", c) != null or std.ascii.isDigit(c)) return true;
        if (self.ext.tables and (c == '|' or c == ':')) return true;
        if (self.ext.definition_lists and c == ':') return true;
        return self.ext.footnotes and c == '[';
    }

    // ---- extensions ------------------------------------------------------------------

    /// Handles a line while the start of the document may be front matter.
    /// True when the line was consumed.
    fn frontMatterLine(self: *Parser, ln: []const u8) Allocator.Error!bool {
        const trimmed = std.mem.trimEnd(u8, ln, " \t");
        switch (self.fm_state) {
            .unchecked => {
                if (self.line_number != 0 or !std.mem.eql(u8, trimmed, "---")) {
                    self.fm_state = .done;
                    return false;
                }
                self.fm_state = .inside;
                try self.fm_lines.append(self.a, try self.a.dupe(u8, ln));
                return true;
            },
            .inside => {
                if (std.mem.eql(u8, trimmed, "---") or std.mem.eql(u8, trimmed, "...")) {
                    var body: std.ArrayList(u8) = .empty;
                    for (self.fm_lines.items[1..]) |l| {
                        try body.appendSlice(self.a, l);
                        try body.append(self.a, '\n');
                    }
                    const n = try self.newNode(.front_matter);
                    n.line = 1;
                    n.literal = body.items;
                    n.build.open = false;
                    self.doc.appendChild(n);
                    self.fm_state = .done;
                    // The lines were counted so that line numbers stay right.
                    self.line_number = @intCast(self.fm_lines.items.len + 1);
                    self.fm_lines.clearRetainingCapacity();
                    return true;
                }
                try self.fm_lines.append(self.a, try self.a.dupe(u8, ln));
                return true;
            },
            .done => return false,
        }
    }

    /// True when the current line begins a block that would end a table.
    fn startsOtherBlock(self: *const Parser) bool {
        if (self.indent >= 4) return false;
        const rest = self.line[self.next_nonspace..];
        if (rest.len == 0) return false;
        if (rest[0] == '>') return true;
        if (rest[0] == '#') {
            var n: usize = 0;
            while (n < rest.len and rest[n] == '#') n += 1;
            if (n <= 6 and (n == rest.len or text.isSpaceOrTab(rest[n]))) return true;
        }
        if (openingFence(rest) != null) return true;
        return false;
    }

    /// `: definition` after a paragraph (whose lines become the terms) or after
    /// another definition of the same list.
    fn startDefinition(self: *Parser, container: *Node) Allocator.Error!u8 {
        if (!self.ext.definition_lists or self.indented) return 0;
        const rest = self.line[self.next_nonspace..];
        if (rest.len < 2 or rest[0] != ':' or !text.isSpaceOrTab(rest[1])) return 0;
        if (container.kind != .paragraph and container.kind != .deflist) return 0;
        // A paragraph that is only link reference definitions has no term.
        if (container.kind == .paragraph and isBlank(container.build.content.items)) return 0;

        const marker_offset = self.indent;
        try self.closeUnmatchedBlocks();
        var dl: *Node = container;
        if (container.kind == .paragraph) {
            const para = container;
            const parent = para.parent.?;
            const prev = para.prev;
            para.unlink();
            if (prev != null and prev.?.kind == .deflist) {
                // Terms after a blank line join the list above.
                dl = prev.?;
                dl.build.open = true;
                dl.build.last_line_checked = false;
            } else {
                dl = try self.newNode(.deflist);
                dl.line = para.line;
                dl.list.tight = true;
                parent.appendChild(dl);
            }
            var lines = std.mem.splitScalar(u8, para.build.content.items, '\n');
            var k: u32 = 0;
            while (lines.next()) |l| : (k += 1) {
                const term_text = std.mem.trim(u8, l, " \t");
                if (term_text.len == 0) continue;
                const t = try self.newNode(.deflist_term);
                t.line = para.line + k;
                t.literal = term_text;
                t.build.open = false;
                dl.appendChild(t);
            }
        }
        self.tip = dl;

        self.advanceNextNonspace();
        self.advanceOffset(1, true);
        const spaces_start_col = self.column;
        const spaces_start_offset = self.offset;
        while (true) {
            self.advanceOffset(1, true);
            if (!(self.column - spaces_start_col < 5 and text.isSpaceOrTab(self.at(self.offset)))) break;
        }
        const spaces_after = self.column - spaces_start_col;
        var padding: usize = 1 + spaces_after;
        if (spaces_after >= 5 or spaces_after < 1 or self.offset >= self.line.len) {
            padding = 2;
            self.column = spaces_start_col;
            self.offset = spaces_start_offset;
            if (text.isSpaceOrTab(self.at(self.offset))) self.advanceOffset(1, true);
        }
        const def = try self.addChild(.deflist_def);
        def.list.padding = padding;
        def.list.marker_offset = marker_offset;
        return 1;
    }

    fn startFootnoteDef(self: *Parser) Allocator.Error!u8 {
        if (!self.ext.footnotes or self.indented) return 0;
        const rest = self.line[self.next_nonspace..];
        if (rest.len < 5 or rest[0] != '[' or rest[1] != '^') return 0;
        var i: usize = 2;
        while (i < rest.len and rest[i] != ']' and rest[i] != '[' and !text.isWhitespace(rest[i])) i += 1;
        if (i == 2 or i + 1 >= rest.len or rest[i] != ']' or rest[i + 1] != ':') return 0;
        const label = rest[2..i];

        try self.closeUnmatchedBlocks();
        self.advanceNextNonspace();
        self.advanceOffset(i + 2, false);
        while (text.isSpaceOrTab(self.at(self.offset))) self.advanceOffset(1, true);
        const node = try self.addChild(.footnote_def);
        const key = try text.normalizeLabel(self.a, label);
        node.literal = key;
        const gop = try self.footnotes.getOrPut(self.a, key);
        if (!gop.found_existing) gop.value_ptr.* = node;
        return 1;
    }

    /// `[ ]` or `[x]` at the start of a list item's first paragraph: records
    /// the task on the item and returns the text after the marker.
    fn taskMarker(para: *Node, content: []const u8) []const u8 {
        const item = para.parent orelse return content;
        if (item.kind != .item or item.first_child != para) return content;
        if (content.len < 3 or content[0] != '[' or content[2] != ']') return content;
        const task: ast.Task = switch (content[1]) {
            ' ' => .unchecked,
            'x', 'X' => .checked,
            else => return content,
        };
        if (content.len > 3 and !text.isWhitespace(content[3])) return content;
        item.task = task;
        return std.mem.trimStart(u8, content[3..], " \t");
    }

    /// Splits one table row into cells. Leading and trailing pipes are
    /// optional; `\|` is a pipe inside a cell.
    fn splitRow(a: Allocator, line: []const u8) Allocator.Error![]const []const u8 {
        var s = std.mem.trim(u8, line, " \t");
        if (s.len > 0 and s[0] == '|') s = s[1..];
        if (s.len > 0 and s[s.len - 1] == '|' and !pipeEscaped(s, s.len - 1)) s = s[0 .. s.len - 1];
        var cells: std.ArrayList([]const u8) = .empty;
        var start: usize = 0;
        var i: usize = 0;
        while (i <= s.len) : (i += 1) {
            if (i < s.len and !(s[i] == '|' and !pipeEscaped(s, i))) continue;
            const raw = std.mem.trim(u8, s[start..i], " \t");
            try cells.append(a, if (std.mem.find(u8, raw, "\\|") != null) try replaceAll(a, raw, "\\|", "|") else raw);
            start = i + 1;
        }
        return cells.items;
    }

    fn pipeEscaped(s: []const u8, i: usize) bool {
        var n: usize = 0;
        while (n < i and s[i - 1 - n] == '\\') n += 1;
        return n % 2 == 1;
    }

    fn replaceAll(a: Allocator, s: []const u8, needle: []const u8, with: []const u8) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < s.len) {
            if (std.mem.startsWith(u8, s[i..], needle)) {
                try out.appendSlice(a, with);
                i += needle.len;
            } else {
                try out.append(a, s[i]);
                i += 1;
            }
        }
        return out.items;
    }

    /// The alignments of a delimiter row (`| :-- | --: |`), or null when the
    /// line is not one. It must contain a pipe, or `---` alone would be a table.
    fn delimiterRow(a: Allocator, line: []const u8) Allocator.Error!?[]const ast.Align {
        if (std.mem.findScalar(u8, line, '|') == null) return null;
        const cells = try splitRow(a, line);
        var aligns: std.ArrayList(ast.Align) = .empty;
        for (cells) |c| {
            if (c.len == 0) return null;
            const left = c[0] == ':';
            const right = c.len > 1 and c[c.len - 1] == ':';
            const dashes = c[@intFromBool(left) .. c.len - @intFromBool(right)];
            if (dashes.len == 0) return null;
            for (dashes) |d| if (d != '-') return null;
            try aligns.append(a, if (left and right) .center else if (left) .left else if (right) .right else .none);
        }
        return aligns.items;
    }

    fn startTable(self: *Parser, container: *Node) Allocator.Error!u8 {
        if (!self.ext.tables or self.indented or container.kind != .paragraph) return 0;
        const aligns = (try delimiterRow(self.a, self.line[self.next_nonspace..])) orelse return 0;

        // The header row is the paragraph's last line.
        const content = container.build.content.items;
        const body = content[0 .. content.len - 1];
        const cut = if (std.mem.findScalarLast(u8, body, '\n')) |nl| nl + 1 else 0;
        const header = body[cut..];
        if ((try splitRow(self.a, header)).len != aligns.len) return 0;

        try self.closeUnmatchedBlocks();
        if (cut > 0) {
            // The lines above the header stay a paragraph.
            container.build.content.items = container.build.content.items[0..cut];
        } else {
            self.tip = container.parent.?;
            container.unlink();
        }
        const table = try self.addChild(.table);
        table.build.aligns = aligns;
        try table.build.content.appendSlice(self.a, header);
        try table.build.content.append(self.a, '\n');
        self.advanceOffset(self.line.len - self.offset, false);
        return 2;
    }

    /// Turns the collected lines of a table into rows and cells.
    fn buildTable(self: *Parser, table: *Node) Allocator.Error!void {
        const aligns = table.build.aligns;
        var lines = std.mem.splitScalar(u8, table.build.content.items, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (line.len == 0 and lines.peek() == null) break;
            const cells = try splitRow(self.a, line);
            const row = try self.newNode(.table_row);
            row.header = first;
            for (aligns, 0..) |al, i| {
                const cell = try self.newNode(.table_cell);
                cell.align_ = al;
                cell.header = first;
                cell.literal = if (i < cells.len) cells[i] else "";
                row.appendChild(cell);
            }
            table.appendChild(row);
            first = false;
        }
    }

    // ---- one line --------------------------------------------------------------------

    pub fn feed(self: *Parser, ln: []const u8) Allocator.Error!void {
        if (self.ext.front_matter and self.fm_state != .done) {
            if (try self.frontMatterLine(ln)) return;
        }
        try self.feedLine(ln);
    }

    fn feedLine(self: *Parser, ln: []const u8) Allocator.Error!void {
        self.oldtip = self.tip;
        self.line = ln;
        self.offset = 0;
        self.column = 0;
        self.blank = false;
        self.partially_consumed_tab = false;
        self.line_number += 1;

        var all_matched = true;
        var container = self.doc;
        while (container.last_child) |last| {
            if (!last.build.open) break;
            container = last;
            self.findNextNonspace();
            switch (try self.continueBlock(container)) {
                .matched => {},
                .not_matched => all_matched = false,
                .line_done => return,
            }
            if (!all_matched) {
                container = container.parent.?;
                break;
            }
        }

        self.all_closed = container == self.oldtip;
        self.last_matched = container;

        var matched_leaf = container.kind != .paragraph and acceptsLines(container.kind);
        while (!matched_leaf) {
            self.findNextNonspace();
            // Quick exit: a line that cannot start a block.
            if (!self.indented and (self.next_nonspace >= self.line.len or !self.maybeSpecial(self.line[self.next_nonspace]))) {
                self.advanceNextNonspace();
                break;
            }
            var which: usize = 0;
            while (which < block_start_count) : (which += 1) {
                const res = try self.tryBlockStart(which, container);
                if (res == 1) {
                    container = self.tip;
                    break;
                } else if (res == 2) {
                    container = self.tip;
                    matched_leaf = true;
                    break;
                }
            }
            if (which == block_start_count) {
                self.advanceNextNonspace();
                break;
            }
        }

        if (!self.all_closed and !self.blank and self.tip.kind == .paragraph) {
            // Lazy paragraph continuation.
            try self.addLine();
        } else {
            try self.closeUnmatchedBlocks();
            if (self.blank) {
                if (container.last_child) |lc| lc.build.last_line_blank = true;
            }
            const t = container.kind;
            const last_line_blank = self.blank and !(t == .block_quote or (t == .code_block and container.build.fenced) or
                ((t == .item or t == .deflist_def) and container.first_child == null and container.line == self.line_number));
            var cont: ?*Node = container;
            while (cont) |c| : (cont = c.parent) c.build.last_line_blank = last_line_blank;

            if (acceptsLines(t)) {
                try self.addLine();
                if (t == .html_block and container.build.html_type >= 1 and container.build.html_type <= 5 and
                    htmlBlockEnds(container.build.html_type, self.line[@min(self.offset, self.line.len)..]))
                {
                    try self.finalize(container);
                }
            } else if (self.offset < self.line.len and !self.blank) {
                container = try self.addChild(.paragraph);
                self.advanceNextNonspace();
                try self.addLine();
            }
        }
    }

    /// Closes every open block and parses the inline content of the leaves.
    pub fn finish(self: *Parser) Allocator.Error!void {
        if (self.fm_state == .inside) {
            // No closing fence: it was not front matter after all.
            self.fm_state = .done;
            self.line_number = 0;
            for (self.fm_lines.items) |l| try self.feedLine(l);
        }
        var t: ?*Node = self.tip;
        while (t) |n| {
            const parent = n.parent;
            if (n.build.open) try self.finalize(n);
            t = parent;
        }
        try inl.processTree(self.a, self.doc, &self.refs, &self.footnotes, self.ext);
    }
};

fn isBlank(s: []const u8) bool {
    for (s) |c| if (!text.isWhitespace(c)) return false;
    return true;
}
