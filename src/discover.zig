//! Explicit online discovery of GGUF repositories on Hugging Face
//! (https://huggingface.co/api/models). Only runs when the user asks
//! (`aimgr search`, TUI `n`). Results are untrusted data: ids are validated
//! and every printed string is sanitized by the caller.
//! Ollama has no documented public search API, so Ollama discovery is not offered.
const std = @import("std");
const abl = @import("abliterate.zig");
const http = @import("http.zig");

pub const Result = struct {
    id: []const u8,
    downloads: u64 = 0,
    likes: u64 = 0,
    /// Gated repo: downloading needs a Hugging Face account, accepted license and token.
    gated: bool = false,
};

pub const Error = error{ NetworkFailed, BadResponse, EmptyQuery, OutOfMemory };

pub fn errorText(e: Error) []const u8 {
    return switch (e) {
        error.NetworkFailed => "network request failed (offline, DNS/TLS error, or timeout)",
        error.BadResponse => "unexpected response from huggingface.co",
        error.EmptyQuery => "search text is empty or has no usable characters",
        error.OutOfMemory => "out of memory",
    };
}

/// Percent-encode everything except unreserved characters; control bytes dropped.
pub fn encodeQuery(arena: std.mem.Allocator, q: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (std.mem.trim(u8, q, " \t")) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(arena, c);
        } else if (c == ' ') {
            try out.appendSlice(arena, "%20");
        } else if (c >= 0x21 and c != 0x7f) {
            try out.print(arena, "%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice(arena);
}

pub const Sort = enum {
    trending,
    downloads,
    recent,

    fn apiName(self: Sort) []const u8 {
        return switch (self) {
            .trending => "trendingScore",
            .downloads => "downloads",
            .recent => "lastModified",
        };
    }

    pub fn next(self: Sort) Sort {
        return switch (self) {
            .trending => .downloads,
            .downloads => .recent,
            .recent => .trending,
        };
    }
};

pub fn buildBrowseUrl(arena: std.mem.Allocator, endpoint: []const u8, sort: Sort, limit: u32) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}/api/models?filter=gguf&pipeline_tag=text-generation&sort={s}&direction=-1&limit={d}", .{ std.mem.trimEnd(u8, endpoint, "/"), sort.apiName(), limit });
}

pub fn buildUrl(arena: std.mem.Allocator, endpoint: []const u8, query: []const u8, limit: u32) ![]u8 {
    const enc = try encodeQuery(arena, query);
    if (enc.len == 0) return error.EmptyQuery;
    return std.fmt.allocPrint(arena, "{s}/api/models?search={s}&filter=gguf&sort=downloads&direction=-1&limit={d}", .{ std.mem.trimEnd(u8, endpoint, "/"), enc, limit });
}

fn isGated(v: ?std.json.Value) bool {
    const val = v orelse return false;
    return switch (val) {
        .bool => |b| b,
        .string => true, // "auto" / "manual"
        else => false,
    };
}

/// Parse the JSON array; entries whose id is not a plausible repo id are dropped.
pub fn parseResults(arena: std.mem.Allocator, body: []const u8) Error![]Result {
    const Item = struct { id: []const u8, downloads: ?u64 = null, likes: ?u64 = null, gated: ?std.json.Value = null };
    const parsed = std.json.parseFromSlice([]Item, arena, body, .{ .ignore_unknown_fields = true }) catch return error.BadResponse;
    var out: std.ArrayList(Result) = .empty;
    for (parsed.value) |it| {
        if (!abl.validRepo(it.id)) continue;
        try out.append(arena, .{ .id = try arena.dupe(u8, it.id), .downloads = it.downloads orelse 0, .likes = it.likes orelse 0, .gated = isGated(it.gated) });
    }
    return out.toOwnedSlice(arena);
}

pub fn search(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, endpoint: []const u8, query: []const u8, limit: u32) Error![]Result {
    const url = buildUrl(arena, endpoint, query, limit) catch |e| return e;
    return fetchUrl(arena, gpa, io, url);
}

/// List GGUF text-generation repos without a query (explicit network call).
pub fn browse(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, endpoint: []const u8, sort: Sort, limit: u32) Error![]Result {
    const url = try buildBrowseUrl(arena, endpoint, sort, limit);
    return fetchUrl(arena, gpa, io, url);
}

fn fetchUrl(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, url: []const u8) Error![]Result {
    const body = http.get(gpa, io, url, 4 << 20) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.NetworkFailed => error.NetworkFailed,
        error.BadStatus, error.TooLarge => error.BadResponse,
    };
    defer gpa.free(body);
    return parseResults(arena, body);
}

test "query encoding" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectEqualStrings("qwen2.5-coder%2014b", try encodeQuery(a.allocator(), "  qwen2.5-coder 14b "));
    try std.testing.expectEqualStrings("a%26b%3Dc%23", try encodeQuery(a.allocator(), "a&b=c#"));
    try std.testing.expectEqualStrings("ab", try encodeQuery(a.allocator(), "a\x01b\n"));
    try std.testing.expectError(error.EmptyQuery, buildUrl(a.allocator(), "https://huggingface.co", "  ", 5));
}

test "parse results, dropping hostile ids" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const body =
        \\[{"_id":"1","id":"Qwen/Qwen2.5-Coder-7B-Instruct-GGUF","likes":635,"downloads":357495,"tags":["gguf"]},
        \\ {"id":"evil/$(rm -rf ~)","downloads":1},
        \\ {"id":"-x/y"},
        \\ {"id":"noslash"},
        \\ {"id":"u/model-abliterated-GGUF","downloads":5}]
    ;
    const r = try parseResults(a.allocator(), body);
    try std.testing.expectEqual(@as(usize, 2), r.len);
    try std.testing.expectEqual(@as(u64, 357495), r[0].downloads);
    try std.testing.expectEqualStrings("u/model-abliterated-GGUF", r[1].id);
    try std.testing.expectError(error.BadResponse, parseResults(a.allocator(), "{not json"));
}

test "results do not alias the response buffer" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const buf = try std.testing.allocator.dupe(u8, "[{\"id\":\"owner/model-GGUF\",\"downloads\":3}]");
    const r = try parseResults(a.allocator(), buf);
    @memset(buf, 'X'); // simulate the HTTP body being freed/reused
    std.testing.allocator.free(buf);
    try std.testing.expectEqualStrings("owner/model-GGUF", r[0].id);
}

test "browse url" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const u = try buildBrowseUrl(a.allocator(), "https://mirror.example/", .trending, 40);
    try std.testing.expect(std.mem.indexOf(u8, u, "sort=trendingScore") != null);
    try std.testing.expect(std.mem.indexOf(u8, u, "limit=40") != null);
    try std.testing.expect(std.mem.startsWith(u8, u, "https://mirror.example/api/models?"));
    try std.testing.expectEqual(Sort.downloads, Sort.trending.next());
    try std.testing.expectEqual(Sort.trending, Sort.recent.next());
}
