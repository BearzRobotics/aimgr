//! Hand-written matchers for the pieces of CommonMark that are regular
//! expressions in the specification: raw HTML, autolinks.
//!
//! Each returns the index just past the match, or null.

const std = @import("std");
const text = @import("text.zig");

fn ws(c: u8) bool {
    return text.isWhitespace(c);
}

fn skipWs(s: []const u8, i: usize) usize {
    var p = i;
    while (p < s.len and ws(s[p])) p += 1;
    return p;
}

fn tagName(s: []const u8, i: usize) ?usize {
    if (i >= s.len or !std.ascii.isAlphabetic(s[i])) return null;
    var p = i + 1;
    while (p < s.len and (std.ascii.isAlphanumeric(s[p]) or s[p] == '-')) p += 1;
    return p;
}

fn attributeName(s: []const u8, i: usize) ?usize {
    if (i >= s.len or !(std.ascii.isAlphabetic(s[i]) or s[i] == '_' or s[i] == ':')) return null;
    var p = i + 1;
    while (p < s.len and (std.ascii.isAlphanumeric(s[p]) or s[p] == '_' or s[p] == ':' or s[p] == '.' or s[p] == '-')) p += 1;
    return p;
}

fn attributeValue(s: []const u8, i: usize) ?usize {
    if (i >= s.len) return null;
    switch (s[i]) {
        '"', '\'' => {
            const end = std.mem.findScalarPos(u8, s, i + 1, s[i]) orelse return null;
            return end + 1;
        },
        else => {
            var p = i;
            while (p < s.len and s[p] > 0x20 and std.mem.findScalar(u8, "\"'=<>`", s[p]) == null) p += 1;
            return if (p > i) p else null;
        },
    }
}

/// `<tag attr="v" ...>` or `<tag/>`, starting at the `<` at `s[i]`.
pub fn openTag(s: []const u8, i: usize) ?usize {
    if (i >= s.len or s[i] != '<') return null;
    var p = tagName(s, i + 1) orelse return null;
    while (true) {
        const after_ws = skipWs(s, p);
        if (after_ws == p) break; // an attribute needs white space before it
        const name_end = attributeName(s, after_ws) orelse break;
        p = name_end;
        // Optional value: ws* = ws* value.
        var q = skipWs(s, p);
        if (q < s.len and s[q] == '=') {
            q = skipWs(s, q + 1);
            if (attributeValue(s, q)) |end| p = end;
        }
    }
    p = skipWs(s, p);
    if (p < s.len and s[p] == '/') p += 1;
    if (p < s.len and s[p] == '>') return p + 1;
    return null;
}

/// `</tag>`.
pub fn closeTag(s: []const u8, i: usize) ?usize {
    if (i + 1 >= s.len or s[i] != '<' or s[i + 1] != '/') return null;
    var p = tagName(s, i + 2) orelse return null;
    p = skipWs(s, p);
    if (p < s.len and s[p] == '>') return p + 1;
    return null;
}

fn comment(s: []const u8, i: usize) ?usize {
    if (!std.mem.startsWith(u8, s[i..], "<!--")) return null;
    const body = i + 4;
    if (std.mem.startsWith(u8, s[body..], ">")) return body + 1;
    if (std.mem.startsWith(u8, s[body..], "->")) return body + 2;
    const end = std.mem.find(u8, s[body..], "-->") orelse return null;
    return body + end + 3;
}

fn processingInstruction(s: []const u8, i: usize) ?usize {
    if (!std.mem.startsWith(u8, s[i..], "<?")) return null;
    const end = std.mem.find(u8, s[i + 2 ..], "?>") orelse return null;
    return i + 2 + end + 2;
}

fn declaration(s: []const u8, i: usize) ?usize {
    if (!std.mem.startsWith(u8, s[i..], "<!")) return null;
    if (i + 2 >= s.len or !std.ascii.isAlphabetic(s[i + 2])) return null;
    const end = std.mem.findScalarPos(u8, s, i + 3, '>') orelse return null;
    return end + 1;
}

fn cdata(s: []const u8, i: usize) ?usize {
    if (!std.mem.startsWith(u8, s[i..], "<![CDATA[")) return null;
    const end = std.mem.find(u8, s[i + 9 ..], "]]>") orelse return null;
    return i + 9 + end + 3;
}

/// Any raw inline HTML construct that starts at `s[i]`.
pub fn htmlInline(s: []const u8, i: usize) ?usize {
    return openTag(s, i) orelse closeTag(s, i) orelse comment(s, i) orelse
        processingInstruction(s, i) orelse declaration(s, i) orelse cdata(s, i);
}

/// `<scheme:rest>` where the scheme is 2 to 32 letters, digits, `+`, `.`, `-`
/// starting with a letter, and rest has no spaces, control characters, `<`, `>`.
pub fn uriAutolink(s: []const u8, i: usize) ?usize {
    if (i >= s.len or s[i] != '<') return null;
    var p = i + 1;
    if (p >= s.len or !std.ascii.isAlphabetic(s[p])) return null;
    const start = p;
    while (p < s.len and (std.ascii.isAlphanumeric(s[p]) or s[p] == '+' or s[p] == '.' or s[p] == '-')) p += 1;
    const n = p - start;
    if (n < 2 or n > 32) return null;
    if (p >= s.len or s[p] != ':') return null;
    p += 1;
    while (p < s.len and s[p] > 0x20 and s[p] != '<' and s[p] != '>') p += 1;
    if (p < s.len and s[p] == '>') return p + 1;
    return null;
}

fn emailLocal(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.findScalar(u8, ".!#$%&'*+/=?^_`{|}~-", c) != null;
}

/// A label of a domain name: letters, digits and hyphens, 1 to 63 long, not
/// starting or ending with a hyphen.
fn domainLabel(s: []const u8, i: usize) ?usize {
    var p = i;
    while (p < s.len and (std.ascii.isAlphanumeric(s[p]) or s[p] == '-')) p += 1;
    const n = p - i;
    if (n == 0 or n > 63 or s[i] == '-' or s[p - 1] == '-') return null;
    return p;
}

/// `<user@example.com>`.
pub fn emailAutolink(s: []const u8, i: usize) ?usize {
    if (i >= s.len or s[i] != '<') return null;
    var p = i + 1;
    const start = p;
    while (p < s.len and emailLocal(s[p])) p += 1;
    if (p == start or p >= s.len or s[p] != '@') return null;
    p = domainLabel(s, p + 1) orelse return null;
    while (p < s.len and s[p] == '.') p = domainLabel(s, p + 1) orelse return null;
    if (p < s.len and s[p] == '>') return p + 1;
    return null;
}

test "html tags" {
    try std.testing.expectEqual(@as(?usize, 12), openTag("<a href=\"x\">", 0));
    try std.testing.expectEqual(@as(?usize, null), openTag("<a href='x", 0));
    try std.testing.expectEqual(@as(?usize, 5), closeTag("</a >", 0));
    try std.testing.expectEqual(@as(?usize, 5), comment("<!-->", 0));
    try std.testing.expectEqual(@as(?usize, 16), uriAutolink("<http://foo.bar>", 0));
    try std.testing.expect(emailAutolink("<foo@bar.example.com>", 0) != null);
}
