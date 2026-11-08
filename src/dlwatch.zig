//! Progress for llama downloads. This llama build prints nothing when its output is not a
//! terminal and stores files in the Hugging Face hub cache, so aimgr measures progress itself:
//! expected size from the HF API (`siblings[].size`), bytes so far from the growing
//! `*.downloadInProgress` / `*.incomplete` blob in <hub cache>/models--owner--repo/blobs/.
//! Read-only: nothing here modifies or deletes any cache file.
const std = @import("std");
const http = @import("http.zig");

/// $HF_HUB_CACHE, else $HF_HOME/hub, else $XDG_CACHE_HOME/huggingface/hub, else ~/.cache/huggingface/hub.
pub fn hubCacheDir(arena: std.mem.Allocator, env: *const std.process.Environ.Map) !?[]const u8 {
    if (env.get("HF_HUB_CACHE")) |d| if (d.len > 0 and d[0] == '/') return d;
    if (env.get("HF_HOME")) |d| if (d.len > 0 and d[0] == '/') return try std.fs.path.join(arena, &.{ d, "hub" });
    if (env.get("XDG_CACHE_HOME")) |d| if (d.len > 0 and d[0] == '/') return try std.fs.path.join(arena, &.{ d, "huggingface", "hub" });
    if (env.get("HOME")) |h| if (h.len > 0) return try std.fs.path.join(arena, &.{ h, ".cache", "huggingface", "hub" });
    return null;
}

/// "owner/name" -> "<hub>/models--owner--name/blobs"
pub fn blobsDir(arena: std.mem.Allocator, hub: []const u8, repo: []const u8) ![]u8 {
    const folder = try std.mem.replaceOwned(u8, arena, repo, "/", "--");
    return std.fmt.allocPrint(arena, "{s}/models--{s}/blobs", .{ hub, folder });
}

pub const Id = struct { repo: []const u8, quant: ?[]const u8 };

/// "owner/name:Q4_K_M" -> {owner/name, Q4_K_M}
pub fn splitId(id: []const u8) Id {
    if (std.mem.lastIndexOfScalar(u8, id, ':')) |c| return .{ .repo = id[0..c], .quant = id[c + 1 ..] };
    return .{ .repo = id, .quant = null };
}

fn hasFold(hay: []const u8, needle: []const u8) bool {
    return std.ascii.findIgnoreCase(hay, needle) != null;
}

/// Total bytes llama will fetch for the main model, from a Hugging Face model JSON (blobs=true).
/// Multi-part GGUFs ("-00001-of-00004") are summed; mmproj files are ignored.
pub fn pickTotal(arena: std.mem.Allocator, json: []const u8, quant: ?[]const u8) ?u64 {
    const Sib = struct { rfilename: []const u8, size: ?u64 = null };
    const Doc = struct { siblings: ?[]Sib = null };
    const parsed = std.json.parseFromSlice(Doc, arena, json, .{ .ignore_unknown_fields = true }) catch return null;
    const sibs = parsed.value.siblings orelse return null;
    const want = quant orelse "Q4_K_M";
    var sum: u64 = 0;
    var shards = false;
    var first: ?u64 = null;
    var any_gguf_first: ?u64 = null;
    for (sibs) |s| {
        if (!std.mem.endsWith(u8, s.rfilename, ".gguf") or hasFold(s.rfilename, "mmproj")) continue;
        const size = s.size orelse continue;
        if (any_gguf_first == null) any_gguf_first = size;
        if (!hasFold(s.rfilename, want)) continue;
        if (hasFold(s.rfilename, "-of-")) {
            shards = true;
            sum += size;
        } else if (first == null) first = size;
    }
    if (shards) return sum;
    if (first) |f| return f;
    // llama falls back to the first file when the requested quant does not exist (only when none given)
    return if (quant == null) any_gguf_first else null;
}

/// Best effort; null on any failure (the bar then shows bytes only).
pub fn expectedSize(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, endpoint: []const u8, id: Id) ?u64 {
    const url = std.fmt.allocPrint(arena, "{s}/api/models/{s}?blobs=true", .{ std.mem.trimEnd(u8, endpoint, "/"), id.repo }) catch return null;
    const body = http.get(gpa, io, url, 8 << 20) catch return null;
    defer gpa.free(body);
    return pickTotal(arena, body, id.quant);
}

/// Sum of the sizes of unfinished download blobs in `dir` (0 if the directory does not exist yet).
pub fn bytesInProgress(io: std.Io, dir_path: []const u8) u64 {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var it = dir.iterate();
    var sum: u64 = 0;
    var seen: usize = 0;
    while (it.next(io) catch null) |entry| {
        seen += 1;
        if (seen > 256) break;
        if (!(std.mem.endsWith(u8, entry.name, ".downloadInProgress") or std.mem.endsWith(u8, entry.name, ".incomplete"))) continue;
        var f = dir.openFile(io, entry.name, .{}) catch continue;
        defer f.close(io);
        sum += f.length(io) catch 0;
    }
    return sum;
}

test "split id and blobs dir" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const id = splitId("bartowski/SmolLM2-135M-Instruct-GGUF:Q4_K_M");
    try std.testing.expectEqualStrings("bartowski/SmolLM2-135M-Instruct-GGUF", id.repo);
    try std.testing.expectEqualStrings("Q4_K_M", id.quant.?);
    try std.testing.expect(splitId("a/b").quant == null);
    try std.testing.expectEqualStrings("/h/hub/models--a--b/blobs", try blobsDir(a.allocator(), "/h/hub", "a/b"));
}

test "pick the right file size" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const single =
        \\{"siblings":[{"rfilename":"README.md","size":10},
        \\ {"rfilename":"m-Q8_0.gguf","size":900},
        \\ {"rfilename":"m-Q4_K_M.gguf","size":500},
        \\ {"rfilename":"mmproj-m-Q4_K_M.gguf","size":77}]}
    ;
    try std.testing.expectEqual(@as(?u64, 500), pickTotal(a.allocator(), single, "Q4_K_M"));
    try std.testing.expectEqual(@as(?u64, 500), pickTotal(a.allocator(), single, null)); // default quant
    try std.testing.expectEqual(@as(?u64, 900), pickTotal(a.allocator(), single, "q8_0"));
    try std.testing.expectEqual(@as(?u64, null), pickTotal(a.allocator(), single, "Q2_K"));
    const shards =
        \\{"siblings":[{"rfilename":"big-Q4_K_M-00001-of-00002.gguf","size":300},
        \\ {"rfilename":"big-Q4_K_M-00002-of-00002.gguf","size":200}]}
    ;
    try std.testing.expectEqual(@as(?u64, 500), pickTotal(a.allocator(), shards, "Q4_K_M"));
    // llama falls back to the first file when no quant is given and Q4_K_M does not exist
    try std.testing.expectEqual(@as(?u64, 900), pickTotal(a.allocator(), "{\"siblings\":[{\"rfilename\":\"m-Q8_0.gguf\",\"size\":900}]}", null));
    try std.testing.expectEqual(@as(?u64, null), pickTotal(a.allocator(), "not json", null));
}
