//! TOML 1.0.0 parser. Reference: https://toml.io/en/v1.0.0 (ABNF in the
//! toml-lang/toml repository, toml.abnf at tag v1.0.0).
//!
//! The parser pulls bytes from a `std.Io.Reader` through `Source`, which
//! offers a few bytes of lookahead and tracks line, column, input size and
//! UTF-8 validity as bytes are consumed. It never needs the whole input in
//! memory. Parsed values are allocated from the arena it is given; text being
//! assembled (strings, tokens) goes through one reused scratch buffer.
//! On any error it stops at the first problem and, if a `Diagnostic` was
//! supplied, records a 1-based line/column and a message.
//! See docs/decisions/0001-streaming-parser.md.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const value = @import("value.zig");
const Value = value.Value;
const Table = value.Table;
const Array = value.Array;
const Datetime = value.Datetime;

/// Errors that do not depend on where the bytes come from.
pub const Error = error{
    /// Malformed TOML, or a valid-looking construct TOML forbids (duplicate key, ...).
    Syntax,
    /// The input is not valid UTF-8.
    InvalidUtf8,
    /// Nesting or input size exceeded `Options` limits.
    LimitExceeded,
    OutOfMemory,
};

/// `Error` plus a failure of the underlying `Reader`.
pub const ReadError = Error || error{ReadFailed};

/// Which edition of the TOML specification to accept. 1.1.0 only adds syntax;
/// every 1.0.0 document is also valid 1.1.0 and means the same thing.
/// 1.1.0 (https://toml.io/en/v1.1.0, grammar at tag 1.1.0 of toml-lang/toml):
/// newlines, comments and a trailing comma inside inline tables; the `\xHH`
/// and `\e` string escapes; optional seconds in times.
pub const Version = enum { v1_0, v1_1 };

pub const Options = struct {
    version: Version = .v1_1,
    /// Maximum nesting of arrays plus inline tables. Bounds recursion depth.
    max_depth: u32 = 64,
    /// Maximum input size in bytes.
    max_bytes: usize = 16 * 1024 * 1024,
};

pub const Diagnostic = struct {
    line: usize = 0,
    column: usize = 0,
    /// Static string; valid for the program's lifetime.
    message: []const u8 = "",

    pub fn format(self: Diagnostic, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("{d}:{d}: {s}", .{ self.line, self.column, self.message });
    }
};

/// The most bytes the parser ever looks ahead (a BOM). A `Reader` buffer
/// smaller than this is wrapped in a larger one; see `parse`.
const max_lookahead = 4;

/// A 1-based position, remembered so an error can point at where a construct
/// began rather than where it was found to be wrong.
const Loc = struct { line: usize, col: usize };

/// Parses TOML from `r` into `root`. `gpa` is used only for the scratch
/// buffer; everything that outlives the call is allocated from `arena`.
pub fn parse(gpa: Allocator, arena: Allocator, root: *Table, r: *Io.Reader, options: Options, diag: ?*Diagnostic) ReadError!void {
    // Lookahead needs the reader to buffer a few bytes. If the caller's reader
    // cannot, put a small buffer in front of it.
    var wrap_buf: [2 * max_lookahead]u8 = undefined;
    var wrapped: Io.Reader.Limited = undefined;
    var reader = r;
    if (r.buffer.len < max_lookahead) {
        wrapped = .init(r, .unlimited, &wrap_buf);
        reader = &wrapped.interface;
    }

    var p: Parser = .{
        .s = .{ .r = reader, .max_bytes = options.max_bytes, .diag = diag },
        .gpa = gpa,
        .arena = arena,
        .root = root,
        .current = root,
        .options = options,
    };
    defer p.scratch.deinit(gpa);
    if (try p.s.peekAt(0) == 0xEF and try p.s.peekAt(1) == 0xBB and try p.s.peekAt(2) == 0xBF) {
        for (0..3) |_| try p.s.bump();
    }
    root.kind = .explicit;
    try p.document();
    try p.s.finish();
}

/// Byte source over a `Reader`: lookahead, consumption, and bookkeeping.
/// Every byte the parser accepts goes through `bump`, which is what makes the
/// line/column, size and UTF-8 checks complete.
const Source = struct {
    r: *Io.Reader,
    max_bytes: usize,
    diag: ?*Diagnostic,
    line: usize = 1,
    col: usize = 1,
    consumed: usize = 0,
    /// Continuation bytes still owed by the current multi-byte UTF-8 sequence,
    /// and the range the next one must fall in (narrowed after some lead bytes
    /// to reject overlong forms, surrogates and values above U+10FFFF).
    need: u2 = 0,
    lo: u8 = 0x80,
    hi: u8 = 0xBF,

    fn loc(self: *const Source) Loc {
        return .{ .line = self.line, .col = self.col };
    }

    fn fail(self: *Source, at: Loc, msg: []const u8, err: Error) Error {
        if (self.diag) |d| d.* = .{ .line = at.line, .column = at.col, .message = msg };
        return err;
    }

    /// The next byte, or null at end of input.
    fn peek(self: *Source) ReadError!?u8 {
        const r = self.r;
        if (r.seek < r.end) return r.buffer[r.seek];
        return self.peekAt(0);
    }

    /// The byte `i` places ahead (`i < max_lookahead`), or null if the input
    /// ends first.
    fn peekAt(self: *Source, i: usize) ReadError!?u8 {
        std.debug.assert(i < max_lookahead);
        const r = self.r;
        if (r.seek + i < r.end) return r.buffer[r.seek + i];
        const bytes = r.peek(i + 1) catch |e| switch (e) {
            error.EndOfStream => return null,
            error.ReadFailed => return error.ReadFailed,
        };
        return bytes[i];
    }

    /// Consumes the byte `peek` just returned.
    fn bump(self: *Source) ReadError!void {
        const r = self.r;
        const c = r.buffer[r.seek];
        const at = self.loc();
        r.toss(1);
        self.consumed += 1;
        if (self.consumed > self.max_bytes) return self.fail(at, "input too large", error.LimitExceeded);

        if (self.need > 0) {
            if (c < self.lo or c > self.hi) return self.fail(at, "invalid UTF-8", error.InvalidUtf8);
            self.need -= 1;
            self.lo = 0x80;
            self.hi = 0xBF;
            return; // continuation bytes do not advance the column
        }
        if (c < 0x80) {
            if (c == '\n') {
                self.line += 1;
                self.col = 1;
            } else self.col += 1;
            return;
        }
        switch (c) {
            0xC2...0xDF => self.need = 1,
            0xE0 => {
                self.need = 2;
                self.lo = 0xA0;
            },
            0xE1...0xEC, 0xEE, 0xEF => self.need = 2,
            0xED => {
                self.need = 2;
                self.hi = 0x9F;
            },
            0xF0 => {
                self.need = 3;
                self.lo = 0x90;
            },
            0xF1...0xF3 => self.need = 3,
            0xF4 => {
                self.need = 3;
                self.hi = 0x8F;
            },
            else => return self.fail(at, "invalid UTF-8", error.InvalidUtf8),
        }
        self.col += 1; // one column per code point
    }

    /// Call once the input is exhausted: a multi-byte sequence must not be cut short.
    fn finish(self: *Source) Error!void {
        if (self.need != 0) return self.fail(self.loc(), "invalid UTF-8", error.InvalidUtf8);
    }
};

const Parser = struct {
    s: Source,
    gpa: Allocator,
    arena: Allocator,
    root: *Table,
    current: *Table,
    options: Options,
    /// Text being assembled: bare keys, string bodies, scalar tokens.
    scratch: std.ArrayList(u8) = .empty,
    depth: u32 = 0,

    fn err(self: *Parser, msg: []const u8) Error {
        return self.s.fail(self.s.loc(), msg, error.Syntax);
    }

    fn errAt(self: *Parser, at: Loc, msg: []const u8) Error {
        return self.s.fail(at, msg, error.Syntax);
    }

    /// Copies the scratch buffer into the arena.
    fn takeScratch(self: *Parser) Error![]const u8 {
        return self.arena.dupe(u8, self.scratch.items);
    }

    /// Consumes the next byte only if it is `c`.
    fn eat(self: *Parser, c: u8) ReadError!bool {
        if ((try self.s.peek()) != c) return false;
        try self.s.bump();
        return true;
    }

    /// Are the next three bytes all `c`?
    fn peekTriple(self: *Parser, c: u8) ReadError!bool {
        return (try self.s.peek()) == c and (try self.s.peekAt(1)) == c and (try self.s.peekAt(2)) == c;
    }

    // ---- lexical helpers -------------------------------------------------

    fn skipWs(self: *Parser) ReadError!void {
        while (try self.s.peek()) |c| {
            if (c != ' ' and c != '\t') break;
            try self.s.bump();
        }
    }

    /// Consumes a newline (LF or CRLF) if present.
    fn eatNewline(self: *Parser) ReadError!bool {
        const c = (try self.s.peek()) orelse return false;
        if (c == '\n') {
            try self.s.bump();
            return true;
        }
        if (c == '\r' and (try self.s.peekAt(1)) == '\n') {
            try self.s.bump();
            try self.s.bump();
            return true;
        }
        return false;
    }

    /// Comment body: any char except control characters other than tab (ABNF `non-eol`).
    fn skipComment(self: *Parser) ReadError!void {
        if ((try self.s.peek()) != '#') return;
        while (try self.s.peek()) |c| {
            if (c == '\n') break;
            if (c == '\r') {
                if ((try self.s.peekAt(1)) == '\n') break;
                return self.err("bare carriage return in comment");
            }
            if (isForbiddenControl(c)) return self.err("control character in comment");
            try self.s.bump();
        }
    }

    /// Whitespace, comments and newlines, as between top-level expressions.
    fn skipBlank(self: *Parser) ReadError!void {
        while (true) {
            try self.skipWs();
            try self.skipComment();
            if (!try self.eatNewline()) break;
        }
    }

    fn expectEndOfLine(self: *Parser) ReadError!void {
        try self.skipWs();
        try self.skipComment();
        if ((try self.s.peek()) == null) return;
        if (!try self.eatNewline()) return self.err("expected end of line");
    }

    // ---- document structure ---------------------------------------------

    fn document(self: *Parser) ReadError!void {
        while (true) {
            try self.skipBlank();
            const c = (try self.s.peek()) orelse return;
            if (c == '[') {
                if ((try self.s.peekAt(1)) == '[') try self.arrayTableHeader() else try self.tableHeader();
            } else {
                try self.keyValue(self.current);
            }
            try self.expectEndOfLine();
        }
    }

    fn tableHeader(self: *Parser) ReadError!void {
        const start = self.s.loc();
        try self.s.bump(); // '['
        try self.skipWs();
        const keys = try self.key();
        try self.skipWs();
        if (!try self.eat(']')) return self.err("expected ']'");

        const parent = try self.walk(self.root, keys[0 .. keys.len - 1], start);
        const last = keys[keys.len - 1];
        if (parent.getPtr(last)) |existing| {
            switch (existing.*) {
                .table => |t| {
                    if (t.kind != .implicit) return self.errAt(start, "table defined more than once");
                    t.kind = .explicit;
                    self.current = t;
                },
                else => return self.errAt(start, "key already defined as a non-table value"),
            }
        } else {
            const t = try self.newTable(.explicit);
            try parent.put(self.arena, last, .{ .table = t });
            self.current = t;
        }
    }

    fn arrayTableHeader(self: *Parser) ReadError!void {
        const start = self.s.loc();
        try self.s.bump(); // '['
        try self.s.bump(); // '['
        try self.skipWs();
        const keys = try self.key();
        try self.skipWs();
        if (!try self.eat(']') or !try self.eat(']')) return self.err("expected ']]'");

        const parent = try self.walk(self.root, keys[0 .. keys.len - 1], start);
        const last = keys[keys.len - 1];
        const elem = try self.newTable(.explicit);
        if (parent.getPtr(last)) |existing| {
            switch (existing.*) {
                .array => |a| {
                    if (!a.is_table_array) return self.errAt(start, "cannot extend a static array with [[...]]");
                    try a.items.append(self.arena, .{ .table = elem });
                },
                else => return self.errAt(start, "key already defined as a non-array value"),
            }
        } else {
            const a = try self.arena.create(Array);
            a.* = .{ .is_table_array = true };
            try a.items.append(self.arena, .{ .table = elem });
            try parent.put(self.arena, last, .{ .array = a });
        }
        self.current = elem;
    }

    /// Follows header path segments, creating implicit tables. Through an array
    /// of tables it descends into the most recently added element.
    fn walk(self: *Parser, from: *Table, segs: []const []const u8, at: Loc) Error!*Table {
        var cur = from;
        for (segs) |seg| {
            if (cur.getPtr(seg)) |existing| {
                switch (existing.*) {
                    .table => |t| {
                        if (t.kind == .inline_table) return self.errAt(at, "cannot extend an inline table");
                        cur = t;
                    },
                    .array => |a| {
                        if (!a.is_table_array or a.items.items.len == 0)
                            return self.errAt(at, "cannot extend a static array");
                        cur = a.items.items[a.items.items.len - 1].table;
                    },
                    else => return self.errAt(at, "key already defined as a non-table value"),
                }
            } else {
                const t = try self.newTable(.implicit);
                try cur.put(self.arena, seg, .{ .table = t });
                cur = t;
            }
        }
        return cur;
    }

    fn newTable(self: *Parser, kind: value.TableKind) Error!*Table {
        const t = try self.arena.create(Table);
        t.* = .{ .kind = kind };
        return t;
    }

    // ---- keys and values -------------------------------------------------

    /// key = value, where key may be dotted. Inserts into `table`.
    fn keyValue(self: *Parser, table: *Table) ReadError!void {
        const start = self.s.loc();
        const keys = try self.key();
        try self.skipWs();
        if (!try self.eat('=')) return self.err("expected '=' after key");
        try self.skipWs();

        // Dotted keys create tables that only dotted keys may extend.
        var cur = table;
        for (keys[0 .. keys.len - 1]) |seg| {
            if (cur.getPtr(seg)) |existing| {
                switch (existing.*) {
                    .table => |t| {
                        if (t.kind != .dotted) return self.errAt(start, "key already defined as a table");
                        cur = t;
                    },
                    else => return self.errAt(start, "key already defined as a non-table value"),
                }
            } else {
                const t = try self.newTable(.dotted);
                try cur.put(self.arena, seg, .{ .table = t });
                cur = t;
            }
        }
        const last = keys[keys.len - 1];
        if (cur.get(last) != null) return self.errAt(start, "duplicate key");
        const v = try self.val();
        try cur.put(self.arena, last, v);
    }

    /// Parses `simple-key *( dot-sep simple-key )`.
    fn key(self: *Parser) ReadError![]const []const u8 {
        var segs: std.ArrayList([]const u8) = .empty;
        while (true) {
            try self.skipWs();
            try segs.append(self.arena, try self.simpleKey());
            try self.skipWs();
            if (!try self.eat('.')) break;
        }
        return segs.items;
    }

    fn simpleKey(self: *Parser) ReadError![]const u8 {
        const c = (try self.s.peek()) orelse return self.err("expected key");
        if (c == '"') return self.basicString();
        if (c == '\'') return self.literalString();
        self.scratch.clearRetainingCapacity();
        while (try self.s.peek()) |b| {
            if (!isBareKeyChar(b)) break;
            try self.scratch.append(self.gpa, b);
            try self.s.bump();
        }
        if (self.scratch.items.len == 0) return self.err("expected key");
        return self.takeScratch();
    }

    fn val(self: *Parser) ReadError!Value {
        const c = (try self.s.peek()) orelse return self.err("expected value");
        switch (c) {
            '"' => {
                if (try self.peekTriple('"')) return .{ .string = try self.multilineBasic() };
                return .{ .string = try self.basicString() };
            },
            '\'' => {
                if (try self.peekTriple('\'')) return .{ .string = try self.multilineLiteral() };
                return .{ .string = try self.literalString() };
            },
            '[' => return self.arrayValue(),
            '{' => return self.inlineTable(),
            else => return self.scalar(),
        }
    }

    fn enter(self: *Parser) Error!void {
        if (self.depth >= self.options.max_depth) {
            return self.s.fail(self.s.loc(), "nesting too deep", error.LimitExceeded);
        }
        self.depth += 1;
    }

    fn arrayValue(self: *Parser) ReadError!Value {
        try self.enter();
        defer self.depth -= 1;
        try self.s.bump(); // '['
        const a = try self.arena.create(Array);
        a.* = .{};
        while (true) {
            try self.skipBlank();
            if (try self.eat(']')) break;
            try a.items.append(self.arena, try self.val());
            try self.skipBlank();
            switch ((try self.s.peek()) orelse return self.err("unterminated array")) {
                ',' => try self.s.bump(),
                ']' => {},
                else => return self.err("expected ',' or ']' in array"),
            }
        }
        return .{ .array = a };
    }

    fn inlineTable(self: *Parser) ReadError!Value {
        try self.enter();
        defer self.depth -= 1;
        try self.s.bump(); // '{'
        const t = try self.newTable(.inline_table);
        if (self.options.version == .v1_1) {
            try self.inlineTableBody11(t);
            return .{ .table = t };
        }
        try self.skipWs();
        if (try self.eat('}')) return .{ .table = t };
        while (true) {
            try self.skipWs();
            try self.keyValue(t);
            try self.skipWs();
            switch ((try self.s.peek()) orelse return self.err("unterminated inline table")) {
                ',' => {
                    try self.s.bump();
                    try self.skipWs();
                    if ((try self.s.peek()) == '}') return self.err("trailing comma in inline table");
                },
                '}' => {
                    try self.s.bump();
                    break;
                },
                else => return self.err("expected ',' or '}' in inline table"),
            }
        }
        return .{ .table = t };
    }

    /// TOML 1.1: whitespace, comments and newlines may appear around every
    /// key/value pair and comma, and the last pair may be followed by a comma.
    fn inlineTableBody11(self: *Parser, t: *Table) ReadError!void {
        while (true) {
            try self.skipBlank();
            if (try self.eat('}')) return;
            try self.keyValue(t);
            try self.skipBlank();
            switch ((try self.s.peek()) orelse return self.err("unterminated inline table")) {
                ',' => try self.s.bump(),
                '}' => {},
                else => return self.err("expected ',' or '}' in inline table"),
            }
        }
    }

    // ---- strings ---------------------------------------------------------

    fn basicString(self: *Parser) ReadError![]const u8 {
        try self.s.bump(); // opening quote
        self.scratch.clearRetainingCapacity();
        while (true) {
            const c = (try self.s.peek()) orelse return self.err("unterminated string");
            switch (c) {
                '"' => {
                    try self.s.bump();
                    return self.takeScratch();
                },
                '\\' => {
                    const esc = self.s.loc();
                    try self.s.bump();
                    try self.escape(esc);
                },
                '\n', '\r' => return self.err("newline in single-line string"),
                else => {
                    if (isForbiddenControl(c)) return self.err("control character in string");
                    try self.scratch.append(self.gpa, c);
                    try self.s.bump();
                },
            }
        }
    }

    fn literalString(self: *Parser) ReadError![]const u8 {
        try self.s.bump(); // opening quote
        self.scratch.clearRetainingCapacity();
        while (true) {
            const c = (try self.s.peek()) orelse return self.err("unterminated string");
            if (c == '\'') break;
            if (c == '\n' or c == '\r') return self.err("newline in single-line string");
            if (isForbiddenControl(c)) return self.err("control character in string");
            try self.scratch.append(self.gpa, c);
            try self.s.bump();
        }
        try self.s.bump(); // closing quote
        return self.takeScratch();
    }

    fn multilineBasic(self: *Parser) ReadError![]const u8 {
        for (0..3) |_| try self.s.bump();
        _ = try self.eatNewline(); // a newline right after the opening delimiter is trimmed
        self.scratch.clearRetainingCapacity();
        while (true) {
            const c = (try self.s.peek()) orelse return self.err("unterminated multi-line string");
            switch (c) {
                '"' => if (try self.quoteRun('"')) |s| return s,
                '\\' => {
                    const esc = self.s.loc();
                    try self.s.bump();
                    const n = (try self.s.peek()) orelse return self.err("unterminated escape");
                    if (n == ' ' or n == '\t' or n == '\n' or n == '\r') {
                        // A backslash before optional whitespace and a newline
                        // removes the newline and all following whitespace.
                        // (No valid escape starts with these bytes, so this is
                        // either a line continuation or an error.)
                        try self.skipWs();
                        if (!try self.eatNewline()) return self.errAt(esc, "invalid escape sequence");
                        while (try self.s.peek()) |w| {
                            if (w == ' ' or w == '\t' or w == '\n') {
                                try self.s.bump();
                            } else if (w == '\r' and (try self.s.peekAt(1)) == '\n') {
                                try self.s.bump();
                                try self.s.bump();
                            } else break;
                        }
                    } else try self.escape(esc);
                },
                '\n' => {
                    try self.scratch.append(self.gpa, c);
                    try self.s.bump();
                },
                '\r' => {
                    if ((try self.s.peekAt(1)) != '\n') return self.err("bare carriage return in string");
                    try self.scratch.appendSlice(self.gpa, "\r\n");
                    try self.s.bump();
                    try self.s.bump();
                },
                else => {
                    if (isForbiddenControl(c)) return self.err("control character in string");
                    try self.scratch.append(self.gpa, c);
                    try self.s.bump();
                },
            }
        }
    }

    fn multilineLiteral(self: *Parser) ReadError![]const u8 {
        for (0..3) |_| try self.s.bump();
        _ = try self.eatNewline();
        self.scratch.clearRetainingCapacity();
        while (true) {
            const c = (try self.s.peek()) orelse return self.err("unterminated multi-line string");
            switch (c) {
                '\'' => if (try self.quoteRun('\'')) |s| return s,
                '\r' => {
                    if ((try self.s.peekAt(1)) != '\n') return self.err("bare carriage return in string");
                    try self.scratch.appendSlice(self.gpa, "\r\n");
                    try self.s.bump();
                    try self.s.bump();
                },
                else => {
                    if (c != '\n' and isForbiddenControl(c)) return self.err("control character in string");
                    try self.scratch.append(self.gpa, c);
                    try self.s.bump();
                },
            }
        }
    }

    /// At a run of `q` inside a multi-line string. Three or more quotes end the
    /// string (up to two of them may belong to its content); fewer are content.
    /// Returns the finished string, or null if the string continues.
    fn quoteRun(self: *Parser, q: u8) ReadError!?[]const u8 {
        const at = self.s.loc();
        var run: usize = 0;
        while ((try self.s.peek()) == q) : (run += 1) try self.s.bump();
        if (run < 3) {
            try self.scratch.appendNTimes(self.gpa, q, run);
            return null;
        }
        if (run > 5) return self.errAt(at, "too many quotes in multi-line string");
        try self.scratch.appendNTimes(self.gpa, q, run - 3);
        return try self.takeScratch();
    }

    /// Just past a backslash inside a basic string; `esc` is the backslash's
    /// position. Appends the decoded character to the scratch buffer.
    fn escape(self: *Parser, esc: Loc) ReadError!void {
        const c = (try self.s.peek()) orelse return self.err("unterminated escape");
        try self.s.bump();
        switch (c) {
            'b' => try self.scratch.append(self.gpa, 0x08),
            't' => try self.scratch.append(self.gpa, '\t'),
            'n' => try self.scratch.append(self.gpa, '\n'),
            'f' => try self.scratch.append(self.gpa, 0x0C),
            'r' => try self.scratch.append(self.gpa, '\r'),
            '"' => try self.scratch.append(self.gpa, '"'),
            '\\' => try self.scratch.append(self.gpa, '\\'),
            'e' => if (self.options.version == .v1_1) {
                try self.scratch.append(self.gpa, 0x1B);
            } else return self.errAt(esc, "invalid escape sequence"),
            'x' => if (self.options.version == .v1_1) {
                try self.unicodeEscape(esc, 2);
            } else return self.errAt(esc, "invalid escape sequence"),
            'u' => try self.unicodeEscape(esc, 4),
            'U' => try self.unicodeEscape(esc, 8),
            else => return self.errAt(esc, "invalid escape sequence"),
        }
    }

    /// Reads `ndig` hex digits and appends the code point as UTF-8.
    fn unicodeEscape(self: *Parser, esc: Loc, ndig: usize) ReadError!void {
        var cp32: u32 = 0;
        for (0..ndig) |_| {
            const h = (try self.s.peek()) orelse return self.errAt(esc, "truncated unicode escape");
            if (!std.ascii.isHex(h)) return self.errAt(esc, "invalid unicode escape");
            cp32 = cp32 * 16 + (std.fmt.charToDigit(h, 16) catch unreachable);
            try self.s.bump();
        }
        if (cp32 > 0x10FFFF or (cp32 >= 0xD800 and cp32 <= 0xDFFF))
            return self.errAt(esc, "unicode escape is not a scalar value");
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(cp32), &buf) catch unreachable;
        try self.scratch.appendSlice(self.gpa, buf[0..n]);
    }

    // ---- numbers, booleans, datetimes -----------------------------------

    /// Appends bare-token bytes (up to a delimiter) to the scratch buffer.
    fn token(self: *Parser) ReadError!void {
        while (try self.s.peek()) |c| {
            if (isTokenEnd(c)) break;
            try self.scratch.append(self.gpa, c);
            try self.s.bump();
        }
    }

    fn scalar(self: *Parser) ReadError!Value {
        const start = self.s.loc();
        self.scratch.clearRetainingCapacity();
        try self.token();
        // A space-separated datetime ("1979-05-27 07:32:00") is one token.
        if (looksLikeDate(self.scratch.items) and (try self.s.peek()) == ' ') {
            const d1 = try self.s.peekAt(1);
            const d2 = try self.s.peekAt(2);
            const colon = try self.s.peekAt(3);
            if (d1 != null and d2 != null and std.ascii.isDigit(d1.?) and std.ascii.isDigit(d2.?) and colon == ':') {
                try self.scratch.append(self.gpa, ' ');
                try self.s.bump();
                try self.token();
            }
        }
        const tok = self.scratch.items;
        if (tok.len == 0) return self.err("expected value");

        if (std.mem.eql(u8, tok, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, tok, "false")) return .{ .boolean = false };
        if (looksLikeDate(tok) or (tok.len >= 3 and tok[2] == ':')) {
            return .{ .datetime = parseDatetime(tok, self.options.version == .v1_1) orelse return self.errAt(start, "invalid date or time") };
        }
        return self.number(tok, start);
    }

    fn number(self: *Parser, tok: []const u8, start: Loc) Error!Value {
        var s = tok;
        var neg = false;
        var signed = false;
        if (s.len > 0 and (s[0] == '+' or s[0] == '-')) {
            neg = s[0] == '-';
            signed = true;
            s = s[1..];
        }
        if (std.mem.eql(u8, s, "inf")) return .{ .float = if (neg) -std.math.inf(f64) else std.math.inf(f64) };
        if (std.mem.eql(u8, s, "nan")) return .{ .float = std.math.nan(f64) };

        if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'o' or s[1] == 'b')) {
            if (signed) return self.errAt(start, "sign not allowed on prefixed integer");
            const base: u8 = switch (s[1]) {
                'x' => 16,
                'o' => 8,
                else => 2,
            };
            const body = self.stripUnderscores(s[2..], base, start) orelse return self.errAt(start, "invalid integer");
            const u = std.fmt.parseInt(u63, body, base) catch return self.errAt(start, "integer out of range");
            return .{ .integer = u };
        }

        var is_float = false;
        for (s) |c| {
            if (c == '.' or c == 'e' or c == 'E') is_float = true;
        }
        if (!is_float) {
            if (s.len == 0) return self.errAt(start, "invalid number");
            if (s.len > 1 and s[0] == '0') return self.errAt(start, "leading zeros are not allowed");
            const body = self.stripUnderscores(s, 10, start) orelse return self.errAt(start, "invalid integer");
            const buf = try self.arena.alloc(u8, body.len + 1);
            buf[0] = if (neg) '-' else '+';
            @memcpy(buf[1..], body);
            const i = std.fmt.parseInt(i64, buf, 10) catch return self.errAt(start, "integer out of range");
            return .{ .integer = i };
        }

        // Float: int-part [frac] [exp], validated before conversion because
        // std.fmt.parseFloat accepts forms TOML rejects ("1.", ".5", "0x1p3").
        var i: usize = 0;
        const int_end = scanDigits(s, 0, 10) orelse return self.errAt(start, "invalid float");
        if (int_end == 0) return self.errAt(start, "invalid float");
        if (int_end > 1 and s[0] == '0') return self.errAt(start, "leading zeros are not allowed");
        i = int_end;
        if (i < s.len and s[i] == '.') {
            const frac_end = scanDigits(s, i + 1, 10) orelse return self.errAt(start, "invalid float");
            if (frac_end == i + 1) return self.errAt(start, "digits required after decimal point");
            i = frac_end;
        }
        if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
            i += 1;
            if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
            const exp_end = scanDigits(s, i, 10) orelse return self.errAt(start, "invalid float");
            if (exp_end == i) return self.errAt(start, "digits required in exponent");
            i = exp_end;
        }
        if (i != s.len) return self.errAt(start, "invalid float");
        const clean = self.stripUnderscores(s, 0, start) orelse return self.errAt(start, "invalid float");
        const f = std.fmt.parseFloat(f64, clean) catch return self.errAt(start, "invalid float");
        return .{ .float = if (neg) -f else f };
    }

    /// Validates underscore placement (only between digits) and returns the
    /// digits without them. `base == 0` means "a float body": '.', 'e', 'E',
    /// '+' and '-' count as non-digit separators that underscores may not touch.
    fn stripUnderscores(self: *Parser, s: []const u8, base: u8, start: Loc) ?[]const u8 {
        _ = start;
        if (s.len == 0) return null;
        const out = self.arena.alloc(u8, s.len) catch return null;
        var n: usize = 0;
        for (s, 0..) |c, idx| {
            if (c == '_') {
                if (idx == 0 or idx + 1 == s.len) return null;
                if (!isDigitOf(s[idx - 1], base) or !isDigitOf(s[idx + 1], base)) return null;
                continue;
            }
            if (base != 0 and !isDigitOf(c, base)) return null;
            out[n] = c;
            n += 1;
        }
        return out[0..n];
    }
};

/// Index just past the run of digits/underscores starting at `from`, or null
/// if an underscore is not between two digits.
fn scanDigits(s: []const u8, from: usize, base: u8) ?usize {
    var i = from;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '_') {
            if (i == from or i + 1 >= s.len or !isDigitOf(s[i - 1], base) or !isDigitOf(s[i + 1], base)) return null;
        } else if (!isDigitOf(c, base)) break;
    }
    return i;
}

fn isDigitOf(c: u8, base: u8) bool {
    return switch (base) {
        0, 10 => std.ascii.isDigit(c),
        16 => std.ascii.isHex(c),
        8 => c >= '0' and c <= '7',
        2 => c == '0' or c == '1',
        else => false,
    };
}

fn isBareKeyChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

/// Characters that end a bare value token.
fn isTokenEnd(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\r', '\n', ',', ']', '}', '#' => true,
        else => false,
    };
}

/// Control characters TOML forbids in strings and comments: U+0000..U+0008,
/// U+000A..U+001F and U+007F. (Tab is allowed; callers handle LF/CR.)
fn isForbiddenControl(c: u8) bool {
    return (c < 0x20 and c != '\t') or c == 0x7F;
}

fn looksLikeDate(tok: []const u8) bool {
    return tok.len >= 10 and tok[4] == '-' and tok[7] == '-' and std.ascii.isDigit(tok[0]);
}

// ---- datetime parsing ----------------------------------------------------

fn digits(s: []const u8, comptime n: usize) ?u32 {
    if (s.len < n) return null;
    var v: u32 = 0;
    for (s[0..n]) |c| {
        if (!std.ascii.isDigit(c)) return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

fn daysInMonth(year: u32, month: u32) u32 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        else => if ((year % 4 == 0 and year % 100 != 0) or year % 400 == 0) 29 else 28,
    };
}

/// `HH:MM:SS[.frac]`; with `optional_seconds` (TOML 1.1) also `HH:MM`.
fn parseTime(s: []const u8, optional_seconds: bool, out_len: *usize) ?value.Time {
    const h = digits(s, 2) orelse return null;
    if (s.len < 5 or s[2] != ':') return null;
    const m = digits(s[3..], 2) orelse return null;
    if (h > 23 or m > 59) return null;
    if (s.len == 5 or s[5] != ':') {
        if (!optional_seconds) return null;
        out_len.* = 5;
        return .{ .hour = @intCast(h), .minute = @intCast(m), .second = 0, .nanosecond = 0 };
    }
    if (s.len < 8) return null;
    const sec = digits(s[6..], 2) orelse return null;
    if (sec > 60) return null; // 60: leap second
    var ns: u32 = 0;
    var i: usize = 8;
    if (i < s.len and s[i] == '.') {
        i += 1;
        const frac_start = i;
        var scale: u32 = 100_000_000;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
            ns += (s[i] - '0') * scale; // digits past nanoseconds are truncated
            scale /= 10;
        }
        if (i == frac_start) return null;
    }
    out_len.* = i;
    return .{ .hour = @intCast(h), .minute = @intCast(m), .second = @intCast(sec), .nanosecond = ns };
}

fn parseDatetime(tok: []const u8, optional_seconds: bool) ?Datetime {
    var dt: Datetime = .{};
    var rest = tok;
    if (looksLikeDate(tok)) {
        const y = digits(tok, 4) orelse return null;
        const mo = digits(tok[5..], 2) orelse return null;
        const d = digits(tok[8..], 2) orelse return null;
        if (mo < 1 or mo > 12 or d < 1 or d > daysInMonth(y, mo)) return null;
        dt.date = .{ .year = @intCast(y), .month = @intCast(mo), .day = @intCast(d) };
        rest = tok[10..];
        if (rest.len == 0) return dt;
        if (rest[0] != 'T' and rest[0] != 't' and rest[0] != ' ') return null;
        rest = rest[1..];
    }
    var tlen: usize = 0;
    dt.time = parseTime(rest, optional_seconds, &tlen) orelse return null;
    rest = rest[tlen..];
    if (rest.len == 0) return dt;
    if (dt.date == null) return null; // a bare time has no offset
    if (rest.len == 1 and (rest[0] == 'Z' or rest[0] == 'z')) {
        dt.offset_minutes = 0;
        return dt;
    }
    if (rest.len == 6 and (rest[0] == '+' or rest[0] == '-') and rest[3] == ':') {
        const oh = digits(rest[1..], 2) orelse return null;
        const om = digits(rest[4..], 2) orelse return null;
        if (oh > 23 or om > 59) return null;
        const mins: i16 = @intCast(oh * 60 + om);
        dt.offset_minutes = if (rest[0] == '-') -mins else mins;
        return dt;
    }
    return null;
}
