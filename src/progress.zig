//! Download/job progress, parsed from job logs and rendered as ASCII bars.
//! Sources:
//!   ollama pull   per-layer lines "pulling <digest>:  45% ▕███   ▏ 63 MB/270 MB ..."
//!   llama pulls   aimgr itself prints "aimgr-progress: done=N total=M" (llama prints nothing
//!                 when not on a terminal; aimgr watches the growing *.downloadInProgress file)
//!   abliterate    "== [i/n] stage" lines plus helper "[stage] k/m ..." counters
//! Log text is untrusted; everything here is bounds-checked and never panics on odd input.
const std = @import("std");
const backend = @import("backend.zig");

pub const Progress = struct {
    done: u64,
    /// 0 = unknown total (indeterminate).
    total: u64,
    unit: enum { bytes, steps } = .bytes,

    pub fn fraction(self: Progress) ?f64 {
        if (self.total == 0) return null;
        const f = @as(f64, @floatFromInt(@min(self.done, self.total))) / @as(f64, @floatFromInt(self.total));
        return f;
    }

    pub fn percent(self: Progress) ?u8 {
        const f = self.fraction() orelse return null;
        return @intFromFloat(@floor(f * 100.0));
    }
};

/// Drop ANSI CSI sequences and control characters (except \n and \r, which split segments).
pub fn clean(arena: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const b = text[i];
        if (b == 0x1b) {
            if (i + 1 < text.len and text[i + 1] == '[') {
                i += 2;
                while (i < text.len and !(text[i] >= 0x40 and text[i] <= 0x7e)) i += 1;
            }
            continue;
        }
        if (b == '\n' or b == '\r' or b >= 0x20) {
            if (b != 0x7f) try out.append(arena, b);
        }
    }
    return out.toOwnedSlice(arena);
}

const bar_close = "\xe2\x96\x8f"; // U+258F "▏"

/// Incremental tracker for `ollama pull` output: feed log bytes as they arrive; it keeps the
/// latest done/total of every layer, so a multi-GB pull never needs its whole log re-read.
pub const PullTracker = struct {
    layers: std.StringArrayHashMapUnmanaged([2]u64) = .empty,
    /// Unfinished trailing segment of the previous chunk.
    carry: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *PullTracker, gpa: std.mem.Allocator) void {
        for (self.layers.keys()) |k| gpa.free(k);
        self.layers.deinit(gpa);
        self.carry.deinit(gpa);
    }

    pub fn feed(self: *PullTracker, gpa: std.mem.Allocator, chunk: []const u8) !void {
        try self.carry.appendSlice(gpa, chunk);
        // Process every complete segment (ended by \r or \n); keep the tail.
        var start: usize = 0;
        var i: usize = 0;
        while (i < self.carry.items.len) : (i += 1) {
            const c = self.carry.items[i];
            if (c == '\r' or c == '\n') {
                try self.segment(gpa, self.carry.items[start..i]);
                start = i + 1;
            }
        }
        const rest = self.carry.items.len - start;
        std.mem.copyForwards(u8, self.carry.items[0..rest], self.carry.items[start..]);
        self.carry.shrinkRetainingCapacity(rest);
        if (self.carry.items.len > 64 * 1024) self.carry.clearRetainingCapacity(); // never grow without bound
    }

    fn segment(self: *PullTracker, gpa: std.mem.Allocator, raw: []const u8) !void {
        var tmp = std.heap.ArenaAllocator.init(gpa);
        defer tmp.deinit();
        const seg = std.mem.trimStart(u8, try clean(tmp.allocator(), raw), " ");
        // Spinner frames can be glued after the line; only the start matters.
        if (!std.mem.startsWith(u8, seg, "pulling ")) return;
        const rest = seg["pulling ".len..];
        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return;
        const digest = rest[0..colon];
        if (digest.len < 8 or digest.len > 80 or std.mem.indexOfScalar(u8, digest, ' ') != null) return;
        const close = std.mem.indexOf(u8, rest, bar_close) orelse return;
        const sizes = rest[close + bar_close.len ..];
        const slash = std.mem.indexOfScalar(u8, sizes, '/') orelse return;
        const left = std.mem.trim(u8, sizes[0..slash], " ");
        var rt = std.mem.tokenizeScalar(u8, sizes[slash + 1 ..], ' ');
        const num = rt.next() orelse return;
        const unit = rt.next() orelse return;
        var buf: [48]u8 = undefined;
        const right = std.fmt.bufPrint(&buf, "{s} {s}", .{ num, unit }) catch return;
        const d = backend.parseSizeText(left) orelse return;
        const t = backend.parseSizeText(right) orelse return;
        if (self.layers.getPtr(digest)) |v| {
            v.* = .{ d, t };
        } else {
            if (self.layers.count() >= 512) return; // a hostile log cannot grow this unboundedly
            try self.layers.put(gpa, try gpa.dupe(u8, digest), .{ d, t });
        }
    }

    pub fn progress(self: *const PullTracker) ?Progress {
        if (self.layers.count() == 0) return null;
        var done: u64 = 0;
        var total: u64 = 0;
        for (self.layers.values()) |v| {
            done += @min(v[0], v[1]);
            total += v[1];
        }
        return .{ .done = done, .total = total };
    }
};

/// One-shot parse of a whole `ollama pull` log.
pub fn parseOllamaPull(gpa: std.mem.Allocator, text: []const u8) !?Progress {
    var t: PullTracker = .{};
    defer t.deinit(gpa);
    try t.feed(gpa, text);
    try t.feed(gpa, "\n"); // flush the final segment
    return t.progress();
}

/// Last "aimgr-progress: done=N total=M" line (total may be 0 = unknown).
pub fn parseAimgrProgress(text: []const u8) ?Progress {
    const key = "aimgr-progress: ";
    var pos = std.mem.lastIndexOf(u8, text, key) orelse return null;
    pos += key.len;
    const end = std.mem.indexOfAnyPos(u8, text, pos, "\r\n") orelse text.len;
    var done: ?u64 = null;
    var total: u64 = 0;
    var it = std.mem.tokenizeScalar(u8, text[pos..end], ' ');
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv, "done=")) done = std.fmt.parseInt(u64, kv[5..], 10) catch null;
        if (std.mem.startsWith(u8, kv, "total=")) total = std.fmt.parseInt(u64, kv[6..], 10) catch 0;
    }
    return .{ .done = done orelse return null, .total = total };
}

/// Abliteration/setup jobs: "== [3/8] abliterate: ..." marks stage 3 of 8 (stage 1..2 done);
/// helper counters like "[direction-A] 16/32 prompts" refine the current stage.
pub fn parseStages(text: []const u8) ?Progress {
    const key = "== [";
    var pos = std.mem.lastIndexOf(u8, text, key) orelse return null;
    const after = text[pos + key.len ..];
    const slash = std.mem.indexOfScalar(u8, after, '/') orelse return null;
    const close = std.mem.indexOfScalar(u8, after, ']') orelse return null;
    if (close < slash) return null;
    const i = std.fmt.parseInt(u64, after[0..slash], 10) catch return null;
    const n = std.fmt.parseInt(u64, after[slash + 1 .. close], 10) catch return null;
    if (n == 0 or i == 0 or i > n) return null;
    pos += key.len + close;
    // sub-progress inside the current stage, scaled to 1000ths
    var sub: u64 = 0;
    var lines = std.mem.splitBackwardsScalar(u8, text[pos..], '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] != '[') continue;
        const rb = std.mem.indexOfScalar(u8, line, ']') orelse continue;
        var f = std.mem.tokenizeScalar(u8, line[rb + 1 ..], ' ');
        const frac = f.next() orelse continue;
        const sl = std.mem.indexOfScalar(u8, frac, '/') orelse continue;
        const a = std.fmt.parseInt(u64, frac[0..sl], 10) catch continue;
        const b = std.fmt.parseInt(u64, frac[sl + 1 ..], 10) catch continue;
        if (b == 0 or a > b) continue;
        sub = a * 1000 / b;
        break;
    }
    return .{ .done = (i - 1) * 1000 + sub, .total = n * 1000, .unit = .steps };
}

/// "[=====>     ]" style bar, `width` columns including brackets (min 8). ASCII only:
/// the percentage is always printed next to it by the caller, so it never depends on glyphs.
pub fn bar(buf: []u8, width: usize, frac: ?f64) []const u8 {
    const w = @min(@max(width, 8), buf.len);
    @memset(buf[0..w], ' ');
    buf[0] = '[';
    buf[w - 1] = ']';
    const inner = w - 2;
    if (frac) |f| {
        const filled: usize = @intFromFloat(@floor(@min(@max(f, 0.0), 1.0) * @as(f64, @floatFromInt(inner))));
        for (0..filled) |k| buf[1 + k] = '=';
        if (filled < inner) buf[1 + filled] = '>';
    } else {
        @memset(buf[1 .. 1 + inner], '.');
    }
    return buf[0..w];
}

/// Indeterminate "working" bar: a short block that slides with `tick`.
pub fn spinnerBar(buf: []u8, width: usize, tick: u64) []const u8 {
    const w = @min(@max(width, 8), buf.len);
    @memset(buf[0..w], ' ');
    buf[0] = '[';
    buf[w - 1] = ']';
    const inner = w - 2;
    const span: usize = @min(3, inner);
    const start: usize = @intCast(tick % (inner - span + 1));
    for (0..span) |k| buf[1 + start + k] = '=';
    return buf[0..w];
}

test "ollama pull: real captured output" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const p = (try parseOllamaPull(a.allocator(), @embedFile("fixtures/ollama-pull-progress.txt"))).?;
    try std.testing.expectEqual(@as(u64, 270_000_000), p.total);
    try std.testing.expect(p.done > 200_000_000 and p.done <= p.total);
    try std.testing.expectEqual(@as(?u8, 100), p.percent());
}

test "ollama pull: several layers add up; ignores noise" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const text = "pulling manifest \x1b[2K\r" ++
        "pulling aaaaaaaaaaaa:  50% \xe2\x96\x95\xe2\x96\x88   \xe2\x96\x8f 500 MB/1.0 GB   10 MB/s\r" ++
        "pulling aaaaaaaaaaaa:  80% \xe2\x96\x95\xe2\x96\x88   \xe2\x96\x8f 800 MB/1.0 GB   10 MB/s\r\n" ++
        "pulling bbbbbbbbbbbb: 100% \xe2\x96\x95\xe2\x96\x88   \xe2\x96\x8f  60 B/ 60 B\n" ++
        "pulling bbbbbbbbbbbb:  garbage\n" ++ "unrelated line\n";
    const p = (try parseOllamaPull(a.allocator(), text)).?;
    try std.testing.expectEqual(@as(u64, 1_000_000_060), p.total);
    try std.testing.expectEqual(@as(u64, 800_000_060), p.done);
    try std.testing.expectEqual(@as(?u8, 80), p.percent());
    try std.testing.expect((try parseOllamaPull(a.allocator(), "nothing here")) == null);
    try std.testing.expect((try parseOllamaPull(a.allocator(), "")) == null);
}

test "aimgr-progress lines" {
    const p = parseAimgrProgress("noise\naimgr-progress: done=100 total=400\naimgr-progress: done=200 total=400\n").?;
    try std.testing.expectEqual(@as(?u8, 50), p.percent());
    const u = parseAimgrProgress("aimgr-progress: done=7 total=0\n").?;
    try std.testing.expect(u.percent() == null and u.done == 7);
    try std.testing.expect(parseAimgrProgress("aimgr-progress: done=x\n") == null);
    try std.testing.expect(parseAimgrProgress("") == null);
}

test "stage progress with a sub counter" {
    const log = "== [1/8] workdir: x\n== [2/8] fetch: y\n== [3/8] abliterate: z\n[load] loading\n[direction-A] 16/32 prompts\n";
    const p = parseStages(log).?;
    try std.testing.expectEqual(@as(u64, 8000), p.total);
    try std.testing.expectEqual(@as(u64, 2500), p.done); // stages 1-2 done + half of stage 3
    try std.testing.expectEqual(@as(?u8, 31), p.percent());
    try std.testing.expect(parseStages("== [9/8] bad\n") == null);
    try std.testing.expect(parseStages("nothing") == null);
}

test "bars" {
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("[====>     ]", bar(&b, 12, 0.4));
    try std.testing.expectEqualStrings("[==========]", bar(&b, 12, 1.0));
    try std.testing.expectEqualStrings("[..........]", bar(&b, 12, null));
    try std.testing.expectEqual(@as(usize, 8), bar(&b, 3, 0.5).len);
    var b2: [64]u8 = undefined;
    const s1 = spinnerBar(&b, 12, 0);
    const s2 = spinnerBar(&b2, 12, 3);
    try std.testing.expect(!std.mem.eql(u8, s1, s2));
    try std.testing.expectEqualStrings("[===       ]", s1);
}

test "tracker: chunk boundaries inside a line and inside an escape sequence do not matter" {
    const text = @embedFile("fixtures/ollama-pull-progress.txt");
    var whole: PullTracker = .{};
    defer whole.deinit(std.testing.allocator);
    try whole.feed(std.testing.allocator, text);
    try whole.feed(std.testing.allocator, "\n");
    var chunked: PullTracker = .{};
    defer chunked.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < text.len) : (i += 7) try chunked.feed(std.testing.allocator, text[i..@min(i + 7, text.len)]);
    try chunked.feed(std.testing.allocator, "\n");
    try std.testing.expectEqualDeep(whole.progress(), chunked.progress());
    try std.testing.expect(whole.progress() != null);
}
