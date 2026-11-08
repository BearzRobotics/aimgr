//! The syntax tree. Nodes are plain structs linked by pointers and allocated
//! from the owning `Document`'s arena, so freeing the document frees them all.

const std = @import("std");

pub const Kind = enum {
    // Blocks.
    document,
    block_quote,
    list,
    item,
    code_block,
    html_block,
    paragraph,
    heading,
    thematic_break,
    // Inlines.
    text,
    softbreak,
    linebreak,
    code,
    html_inline,
    emph,
    strong,
    link,
    image,
    // Extensions.
    strikethrough,
    table,
    table_row,
    table_cell,
    footnote_def,
    footnote_ref,
    front_matter,
    /// Children are alternating `deflist_term` and `deflist_def` nodes.
    /// `list.tight` tells whether definitions are written without paragraphs.
    deflist,
    /// One term (a line of text); its children are inlines.
    deflist_term,
    /// One definition; holds blocks, like an `item`.
    deflist_def,
};

pub const Align = enum { none, left, center, right };

pub const Task = enum { none, unchecked, checked };

pub const ListKind = enum { bullet, ordered };

/// Marker data of a list and of each of its items.
pub const ListData = struct {
    kind: ListKind = .bullet,
    /// No blank lines between items or between blocks inside an item.
    tight: bool = true,
    /// `*`, `+` or `-` for bullet lists.
    bullet_char: u8 = 0,
    /// First number of an ordered list.
    start: u32 = 1,
    /// `.` or `)` for ordered lists.
    delimiter: u8 = 0,
    /// Columns an item's content is indented past the marker's start.
    padding: usize = 0,
    /// Column of the marker.
    marker_offset: usize = 0,
};

pub const Node = struct {
    kind: Kind,
    parent: ?*Node = null,
    first_child: ?*Node = null,
    last_child: ?*Node = null,
    prev: ?*Node = null,
    next: ?*Node = null,

    /// Text of `text`, `code`, `html_inline`, `html_block` and `code_block`
    /// nodes; the destination of `link` and `image` nodes.
    literal: []const u8 = "",
    /// Title of `link` and `image`; info string of `code_block`.
    title: []const u8 = "",
    /// Level (1 to 6) of a heading.
    level: u8 = 0,
    list: ListData = .{},
    /// Column alignment of a `table_cell`.
    align_: Align = .none,
    /// True for the header `table_row`.
    header: bool = false,
    /// Task list marker of an `item`.
    task: Task = .none,
    /// Display indent hint in columns for `block_quote`, `deflist_def` and
    /// `code_block`. The Markdown parser never sets it (0). Readers of other
    /// formats (man pages) do: the terminal renderer then indents a quote by
    /// this amount without a bar, puts a short definition term on the same line
    /// as its text, and indents a code block by this amount instead of the
    /// default 4 (`flush` means not at all).
    indent: u16 = 0,

    /// 1-based line on which the block starts (0 for inlines).
    line: u32 = 0,

    /// Parser state; meaningless once parsing is done.
    build: Build = .{},

    pub const Build = struct {
        open: bool = true,
        last_line_blank: bool = false,
        last_line_checked: bool = false,
        fenced: bool = false,
        fence_char: u8 = 0,
        fence_length: usize = 0,
        fence_offset: usize = 0,
        html_type: u8 = 0,
        /// Raw text of an open leaf block, one line per `\n`.
        content: std.ArrayList(u8) = .empty,
        /// Column alignments of a table being built.
        aligns: []const Align = &.{},
    };

    /// `indent` value of a `code_block` that is written without any indent.
    pub const flush: u16 = std.math.maxInt(u16);

    pub fn appendChild(self: *Node, child: *Node) void {
        child.unlink();
        child.parent = self;
        if (self.last_child) |last| {
            last.next = child;
            child.prev = last;
        } else {
            self.first_child = child;
        }
        self.last_child = child;
    }

    pub fn insertAfter(self: *Node, sibling: *Node) void {
        sibling.unlink();
        sibling.next = self.next;
        if (sibling.next) |n| n.prev = sibling;
        sibling.prev = self;
        self.next = sibling;
        sibling.parent = self.parent;
        if (sibling.next == null) {
            if (sibling.parent) |p| p.last_child = sibling;
        }
    }

    pub fn unlink(self: *Node) void {
        if (self.prev) |p| {
            p.next = self.next;
        } else if (self.parent) |par| {
            par.first_child = self.next;
        }
        if (self.next) |n| {
            n.prev = self.prev;
        } else if (self.parent) |par| {
            par.last_child = self.prev;
        }
        self.parent = null;
        self.next = null;
        self.prev = null;
    }

    pub fn isContainer(self: *const Node) bool {
        return switch (self.kind) {
            .document, .block_quote, .list, .item, .paragraph, .heading, .emph, .strong, .link, .image => true,
            .strikethrough, .table, .table_row, .table_cell, .footnote_def => true,
            .deflist, .deflist_term, .deflist_def => true,
            else => false,
        };
    }
};

/// A step of a depth-first walk.
pub const Event = struct { node: *Node, entering: bool };

/// Walks the tree below `root` without recursion, so deeply nested input
/// cannot overflow the stack. Leaf nodes are reported once, as entering.
pub const Walker = struct {
    root: *Node,
    current: ?*Node,
    entering: bool = true,

    pub fn init(root: *Node) Walker {
        return .{ .root = root, .current = root };
    }

    pub fn next(self: *Walker) ?Event {
        const cur = self.current orelse return null;
        const entering = self.entering;
        const event: Event = .{ .node = cur, .entering = entering };

        if (entering and cur.isContainer()) {
            if (cur.first_child) |child| {
                self.current = child;
            } else {
                // An empty container is left at once.
                self.entering = false;
            }
        } else if (cur == self.root) {
            self.current = null;
        } else if (cur.next) |sib| {
            self.current = sib;
            self.entering = true;
        } else {
            self.current = cur.parent;
            self.entering = false;
        }
        return event;
    }
};
