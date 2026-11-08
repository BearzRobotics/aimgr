//! Text helpers shared by the block and inline parsers and the renderers:
//! backslash escapes, character references, URL encoding and link labels.

const std = @import("std");
const Allocator = std.mem.Allocator;
const entities = @import("entities.zig");
const unicode = @import("unicode.zig");

pub fn isSpaceOrTab(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// CommonMark "whitespace character" (space, tab, newline, line tabulation,
/// form feed, carriage return).
pub fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == 0x0b or c == 0x0c or c == '\r';
}

fn isHex(c: u8) bool {
    return std.ascii.isHex(c);
}

/// The length of a character reference (`&amp;`, `&#35;`, `&#x23;`) that starts
/// at `s[i]`, or null. Only the syntax is checked; whether a named reference
/// exists is decided when it is decoded.
pub fn matchEntity(s: []const u8, i: usize) ?usize {
    if (i >= s.len or s[i] != '&') return null;
    var p = i + 1;
    if (p >= s.len) return null;
    if (s[p] == '#') {
        p += 1;
        const hex = p < s.len and (s[p] == 'x' or s[p] == 'X');
        if (hex) p += 1;
        const start = p;
        const max: usize = if (hex) 6 else 7;
        while (p < s.len and p - start < max and (if (hex) isHex(s[p]) else std.ascii.isDigit(s[p]))) p += 1;
        if (p == start) return null;
        if (p < s.len and s[p] == ';') return p + 1 - i;
        return null;
    }
    if (!std.ascii.isAlphabetic(s[p])) return null;
    const start = p;
    while (p < s.len and p - start < 32 and std.ascii.isAlphanumeric(s[p])) p += 1;
    if (p - start < 2) return null;
    if (p < s.len and s[p] == ';') return p + 1 - i;
    return null;
}

fn appendCodePoint(out: *std.ArrayList(u8), a: Allocator, cp: u32) Allocator.Error!void {
    const ok = cp != 0 and cp <= 0x10ffff and !(cp >= 0xd800 and cp <= 0xdfff);
    const real: u21 = if (ok) @intCast(cp) else 0xfffd;
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(real, &buf) catch unreachable;
    try out.appendSlice(a, buf[0..n]);
}

/// Appends the text that the reference `ref` (`&...;`, as matched by
/// `matchEntity`) stands for; an unknown name is appended unchanged.
pub fn appendEntity(out: *std.ArrayList(u8), a: Allocator, ref: []const u8) Allocator.Error!void {
    const body = ref[1 .. ref.len - 1];
    if (body[0] == '#') {
        const hex = body.len > 1 and (body[1] == 'x' or body[1] == 'X');
        const digits = if (hex) body[2..] else body[1..];
        const cp = std.fmt.parseInt(u32, digits, if (hex) 16 else 10) catch 0xfffd;
        return appendCodePoint(out, a, cp);
    }
    if (entities.lookup(body)) |value| return out.appendSlice(a, value);
    try out.appendSlice(a, ref);
}

/// Replaces backslash escapes and character references in `s`. The result is
/// owned by `a` (or is `s` itself when nothing needed replacing).
pub fn unescape(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.findAny(u8, s, "\\&") == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '\\' and i + 1 < s.len and unicode.isAsciiPunct(s[i + 1])) {
            try out.append(a, s[i + 1]);
            i += 2;
        } else if (c == '&') {
            if (matchEntity(s, i)) |n| {
                try appendEntity(&out, a, s[i .. i + n]);
                i += n;
            } else {
                try out.append(a, c);
                i += 1;
            }
        } else {
            try out.append(a, c);
            i += 1;
        }
    }
    return out.items;
}

fn urlSafe(c: u8) bool {
    if (std.ascii.isAlphanumeric(c)) return true;
    return std.mem.findScalar(u8, ";/?:@&=+$,-_.!~*'()#", c) != null;
}

/// Percent-encodes what a URL cannot hold, keeping valid `%XX` escapes (the
/// same set as the `mdurl` package that commonmark.js uses).
pub fn encodeUrl(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '%' and i + 2 < s.len and isHex(s[i + 1]) and isHex(s[i + 2])) {
            try out.appendSlice(a, s[i .. i + 3]);
            i += 2;
        } else if (urlSafe(c)) {
            try out.append(a, c);
        } else {
            try out.print(a, "%{X:0>2}", .{c});
        }
    }
    return out.items;
}

/// The key under which a link reference is stored: the label without its
/// brackets, outer whitespace trimmed, inner whitespace runs collapsed to one
/// space, and case folded (ASCII, Latin-1, Greek, Cyrillic and sharp s).
pub fn normalizeLabel(a: Allocator, label: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const inner = std.mem.trim(u8, label, " \t\r\n\x0b\x0c");
    var i: usize = 0;
    var pending_space = false;
    while (i < inner.len) {
        const c = inner[i];
        if (isWhitespace(c)) {
            pending_space = out.items.len > 0;
            i += 1;
            continue;
        }
        if (pending_space) {
            try out.append(a, ' ');
            pending_space = false;
        }
        if (c < 0x80) {
            try out.append(a, std.ascii.toLower(c));
            i += 1;
            continue;
        }
        const d = unicode.decodeAt(inner, i);
        i += d.len;
        const folded: u21 = switch (d.cp) {
            0xdf, 0x1e9e => {
                try out.appendSlice(a, "ss");
                continue;
            },
            0xc0...0xd6, 0xd8...0xde => d.cp + 0x20,
            0x391...0x3a1, 0x3a3...0x3a9 => d.cp + 0x20,
            0x410...0x42f => d.cp + 0x20,
            0x400...0x40f => d.cp + 0x50,
            else => d.cp,
        };
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(folded, &buf) catch {
            try out.appendSlice(a, inner[i - d.len .. i]);
            continue;
        };
        try out.appendSlice(a, buf[0..n]);
    }
    return out.items;
}

test "references decode" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try appendEntity(&out, a, "&copy;");
    try appendEntity(&out, a, "&#35;");
    try appendEntity(&out, a, "&#x22;");
    try appendEntity(&out, a, "&#0;");
    try appendEntity(&out, a, "&nosuch;");
    try std.testing.expectEqualStrings("\u{a9}#\"\u{fffd}&nosuch;", out.items);
}

test "labels fold case and whitespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("foo bar", try normalizeLabel(a, "  Foo \n BAR "));
    try std.testing.expectEqualStrings("ss", try normalizeLabel(a, "\u{1e9e}"));
}

test "urls are encoded like mdurl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("foo%20b%C3%A4", try encodeUrl(a, "foo b\u{e4}"));
    try std.testing.expectEqualStrings("a%25b%2041", try encodeUrl(a, "a%b%2041"));
}
