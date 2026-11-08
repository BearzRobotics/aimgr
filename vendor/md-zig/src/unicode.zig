//! The Unicode classes CommonMark's emphasis rules need, and UTF-8 helpers.
//!
//! There is no Unicode database in the standard library, so "Unicode
//! punctuation" (general categories P and S) and "Unicode whitespace" (Zs, tab,
//! line feed, form feed, carriage return) are approximated by ASCII plus the
//! ranges of the common blocks. Characters outside those ranges are treated as
//! ordinary letters. This is a documented deviation (docs/decisions/0001).

const std = @import("std");

pub fn isAsciiPunct(c: u8) bool {
    return (c >= 0x21 and c <= 0x2f) or (c >= 0x3a and c <= 0x40) or (c >= 0x5b and c <= 0x60) or (c >= 0x7b and c <= 0x7e);
}

pub fn isUnicodeWhitespace(cp: u21) bool {
    return switch (cp) {
        ' ', '\t', '\n', '\r', 0x0c, 0x0b, 0xa0, 0x1680, 0x202f, 0x205f, 0x3000 => true,
        0x2000...0x200a => true,
        else => false,
    };
}

pub fn isUnicodePunct(cp: u21) bool {
    if (cp < 0x80) return isAsciiPunct(@intCast(cp));
    return switch (cp) {
        // Latin-1 punctuation and symbols.
        0xa1...0xa9, 0xab...0xb1, 0xb4, 0xb6...0xb8, 0xbb, 0xbf, 0xd7, 0xf7 => true,
        // Spacing modifier symbols, Greek/Cyrillic punctuation.
        0x2c2...0x2c5, 0x2d2...0x2df, 0x2e5...0x2eb, 0x2ed, 0x2ef...0x2ff, 0x37e, 0x387 => true,
        // General Punctuation, super/subscripts, currency, letterlike, arrows,
        // math operators, technical, shapes, dingbats, supplemental punctuation.
        0x2010...0x2027, 0x2030...0x205e => true,
        0x2070...0x209f => false,
        0x20a0...0x20cf => true,
        0x2100...0x214f => false,
        0x2190...0x2bff => true,
        0x2e00...0x2e7f => true,
        // CJK symbols and punctuation, fullwidth forms.
        0x3001...0x3003, 0x3008...0x3020, 0x3030, 0x30fb => true,
        0xff01...0xff0f, 0xff1a...0xff20, 0xff3b...0xff40, 0xff5b...0xff65 => true,
        else => false,
    };
}

/// Decodes the code point that starts at `s[i]`. Invalid bytes decode as U+FFFD
/// of length 1.
pub fn decodeAt(s: []const u8, i: usize) struct { cp: u21, len: u3 } {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .cp = 0xfffd, .len = 1 };
    if (i + n > s.len) return .{ .cp = 0xfffd, .len = 1 };
    const cp = std.unicode.utf8Decode(s[i .. i + n]) catch return .{ .cp = 0xfffd, .len = 1 };
    return .{ .cp = cp, .len = @intCast(n) };
}

/// The code point that ends just before `s[end]`.
pub fn decodeBefore(s: []const u8, end: usize) u21 {
    var start = end - 1;
    var back: usize = 0;
    while (start > 0 and back < 3 and (s[start] & 0xc0) == 0x80) : (back += 1) start -= 1;
    const d = decodeAt(s, start);
    if (start + d.len != end) return 0xfffd;
    return d.cp;
}

/// How many terminal columns a code point takes: 0 for combining marks and
/// zero-width characters, 2 for East Asian wide characters and emoji, else 1.
/// An approximation by ranges (there is no Unicode database in the standard
/// library).
pub fn displayWidth(cp: u21) usize {
    return switch (cp) {
        0x0300...0x036f, 0x200b...0x200f, 0x2060...0x2064, 0xfe00...0xfe0f, 0x20d0...0x20ff => 0,
        0x1100...0x115f, 0x2e80...0x303e, 0x3041...0x33ff, 0x3400...0x4dbf, 0x4e00...0x9fff => 2,
        0xa000...0xa4cf, 0xac00...0xd7a3, 0xf900...0xfaff, 0xfe30...0xfe6f, 0xff00...0xff60 => 2,
        0xffe0...0xffe6, 0x1f300...0x1f64f, 0x1f900...0x1f9ff, 0x20000...0x3fffd => 2,
        else => 1,
    };
}

/// The columns a UTF-8 string takes in a terminal.
pub fn stringWidth(s: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const d = decodeAt(s, i);
        w += displayWidth(d.cp);
        i += d.len;
    }
    return w;
}
