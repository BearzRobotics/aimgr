//! GFM extended autolinks: bare `https://...`, `www....` and e-mail addresses
//! in text become links. Runs over the text nodes of a finished paragraph.
//!
//! Rules follow GitHub's cmark-gfm (`autolink.c`); the examples in
//! test/fixtures/gfm-extensions.json pin the behaviour down.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const text = @import("text.zig");
const Node = ast.Node;

const Match = struct {
    /// Byte range of the link text within the scanned string.
    start: usize,
    end: usize,
    /// Text put in front of the text to make the destination.
    prefix: []const u8,
};

fn isDomainChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c >= 0x80;
}

/// The end of a valid host name starting at `s[i]`, or null. Underscores are
/// not allowed in either of the last two labels.
fn domainEnd(s: []const u8, i: usize) ?usize {
    var p = i;
    while (p < s.len and isDomainChar(s[p])) p += 1;
    if (p == i) return null;
    const host = s[i..p];
    var labels = std.mem.splitBackwardsScalar(u8, host, '.');
    var seen: usize = 0;
    while (labels.next()) |l| : (seen += 1) {
        if (seen < 2 and std.mem.findScalar(u8, l, '_') != null) return null;
    }
    return p;
}

/// Cuts trailing punctuation and unbalanced `)` off a link, as GFM requires.
fn trimEnd(s: []const u8, start: usize, end_in: usize) usize {
    var end = end_in;
    while (end > start) {
        const c = s[end - 1];
        if (c == ')') {
            var open: usize = 0;
            var close: usize = 0;
            for (s[start..end]) |ch| {
                if (ch == '(') open += 1;
                if (ch == ')') close += 1;
            }
            if (close <= open) break;
            end -= 1;
        } else if (std.mem.findScalar(u8, "?!.,:*_~'\"", c) != null) {
            end -= 1;
        } else if (c == ';') {
            // An entity-like `&name;` is cut whole.
            var n = end - 1;
            while (n > start and std.ascii.isAlphabetic(s[n - 1])) n -= 1;
            if (n > start and n < end - 1 and s[n - 1] == '&') {
                end = n - 1;
            } else end -= 1;
        } else break;
    }
    return end;
}

fn startsWithNoCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

fn isLocalChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '.' or c == '+' or c == '-' or c == '_';
}

/// The end of an e-mail domain starting at `s[i]` (labels of letters, digits,
/// `-` and `_`, at least one dot, not ending in `-` or `_`), or null.
fn emailDomainEnd(s: []const u8, i: usize) ?usize {
    var p = i;
    var dots: usize = 0;
    var label_len: usize = 0;
    while (p < s.len) {
        const c = s[p];
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') {
            label_len += 1;
        } else if (c == '.' and label_len > 0 and p + 1 < s.len and (std.ascii.isAlphanumeric(s[p + 1]) or s[p + 1] == '-' or s[p + 1] == '_')) {
            dots += 1;
            label_len = 0;
        } else break;
        p += 1;
    }
    if (dots == 0 or label_len == 0) return null;
    if (s[p - 1] == '-' or s[p - 1] == '_') return null;
    return p;
}

/// Finds the first autolink in `s` at or after `from`.
fn find(s: []const u8, from: usize) ?Match {
    var i = from;
    while (i < s.len) : (i += 1) {
        const prev: u8 = if (i == 0) ' ' else s[i - 1];
        const c = s[i];

        // www.example.com
        if ((c == 'w' or c == 'W') and startsWithNoCase(s[i..], "www.") and
            (text.isWhitespace(prev) or std.mem.findScalar(u8, "*_~(", prev) != null))
        {
            if (domainEnd(s, i + 4)) |d| {
                var end = d;
                while (end < s.len and !text.isWhitespace(s[end]) and s[end] != '<') end += 1;
                end = trimEnd(s, i, end);
                if (end > i + 4) return .{ .start = i, .end = end, .prefix = "http://" };
            }
        }

        // http://, https://, ftp://
        if (!std.ascii.isAlphanumeric(prev)) {
            inline for (.{ "https://", "http://", "ftp://" }) |scheme| {
                if (startsWithNoCase(s[i..], scheme)) {
                    if (domainEnd(s, i + scheme.len)) |d| {
                        var end = d;
                        while (end < s.len and !text.isWhitespace(s[end]) and s[end] != '<') end += 1;
                        end = trimEnd(s, i, end);
                        if (end > i + scheme.len) return .{ .start = i, .end = end, .prefix = "" };
                    }
                }
            }
        }

        // mailto:user@example.com and xmpp:user@example.com/resource
        if (!std.ascii.isAlphanumeric(prev)) {
            inline for (.{ "mailto:", "xmpp:" }) |scheme| {
                if (startsWithNoCase(s[i..], scheme)) {
                    var p = i + scheme.len;
                    const local_start = p;
                    while (p < s.len and isLocalChar(s[p])) p += 1;
                    if (p > local_start and p < s.len and s[p] == '@') {
                        if (emailDomainEnd(s, p + 1)) |d| {
                            var end = d;
                            if (scheme.len == 5) { // xmpp: may carry a /resource
                                if (end < s.len and s[end] == '/') {
                                    end += 1;
                                    while (end < s.len and (std.ascii.isAlphanumeric(s[end]) or s[end] == '@' or s[end] == '.')) end += 1;
                                }
                                end = trimEnd(s, i, end);
                            }
                            return .{ .start = i, .end = end, .prefix = "" };
                        }
                    }
                }
            }
        }

        // user@example.com
        if (c == '@' and i > from) {
            var start = i;
            while (start > from and isLocalChar(s[start - 1])) start -= 1;
            if (start < i) {
                if (emailDomainEnd(s, i + 1)) |d| return .{ .start = start, .end = d, .prefix = "mailto:" };
            }
        }
    }
    return null;
}

/// Replaces autolink candidates in the text nodes below `block` (outside
/// links and images) with link nodes.
pub fn process(a: Allocator, block: *Node) Allocator.Error!void {
    try mergeText(a, block);
    var walker = ast.Walker.init(block);
    var in_link: usize = 0;
    while (walker.next()) |ev| {
        switch (ev.node.kind) {
            .link, .image => {
                if (ev.entering) in_link += 1 else in_link -= 1;
            },
            .text => if (ev.entering and in_link == 0) try splitText(a, ev.node),
            else => {},
        }
    }
}

/// Joins runs of adjacent text nodes (an unmatched `_` or `&` is a node of
/// its own), so that a link is found even when its text was split.
fn mergeText(a: Allocator, root: *Node) Allocator.Error!void {
    var walker = ast.Walker.init(root);
    while (walker.next()) |ev| {
        if (!ev.entering or !ev.node.isContainer()) continue;
        var child = ev.node.first_child;
        while (child) |c| {
            if (c.kind != .text or c.next == null or c.next.?.kind != .text) {
                child = c.next;
                continue;
            }
            var joined: std.ArrayList(u8) = .empty;
            try joined.appendSlice(a, c.literal);
            var n = c.next;
            while (n) |t| {
                if (t.kind != .text) break;
                try joined.appendSlice(a, t.literal);
                const after = t.next;
                t.unlink();
                n = after;
            }
            c.literal = joined.items;
            child = c.next;
        }
    }
}

fn splitText(a: Allocator, first: *Node) Allocator.Error!void {
    var node = first;
    var from: usize = 0;
    while (find(node.literal, from)) |m| {
        const s = node.literal;
        const shown = s[m.start..m.end];
        const link = try a.create(Node);
        link.* = .{ .kind = .link };
        link.literal = try text.encodeUrl(a, try std.mem.concat(a, u8, &.{ m.prefix, shown }));
        const label = try a.create(Node);
        label.* = .{ .kind = .text, .literal = shown };
        link.appendChild(label);

        const rest = try a.create(Node);
        rest.* = .{ .kind = .text, .literal = s[m.end..] };
        node.literal = s[0..m.start];
        node.insertAfter(link);
        link.insertAfter(rest);
        if (node.literal.len == 0) {
            // Nothing before the link: drop the empty text node, keeping the order.
            node.unlink();
        }
        if (rest.literal.len == 0) {
            rest.unlink();
            return;
        }
        node = rest;
        from = 0;
    }
}
