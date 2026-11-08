//! TOML metadata catalog: friendly names, use cases, notes, aliases.
//! Matching is exact backend+id first, then explicit aliases. Nothing is
//! invented for unmatched models. Catalog text is untrusted data.
const std = @import("std");
const toml = @import("toml");
const backend = @import("backend.zig");

pub const Source = enum { bundled, user };

/// What it takes to get and run a model.
///   open   - no account needed to download; runs fully offline afterwards
///   signin - download needs an account (gated Hugging Face repo: accepted license + HF_TOKEN);
///            runs fully offline afterwards
///   cloud  - runs on a remote service (e.g. Ollama cloud): sign-in + API usage, never offline
pub const Access = enum {
    open,
    signin,
    cloud,

    pub fn label(self: Access) []const u8 {
        return switch (self) {
            .open => "open",
            .signin => "sign-in",
            .cloud => "cloud",
        };
    }

    pub fn explain(self: Access) []const u8 {
        return switch (self) {
            .open => "no account needed to download; runs fully offline once downloaded",
            .signin => "needs a sign-in to download (Hugging Face account, accepted license, HF_TOKEN); runs fully offline once downloaded",
            .cloud => "runs on a remote service: needs sign-in and uses API quota; NOT available offline",
        };
    }

    /// True when the model runs without any network once it is installed.
    pub fn runsOffline(self: Access) bool {
        return self != .cloud;
    }
};

pub const Entry = struct {
    backend: backend.Kind,
    id: []const u8,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    notes: ?[]const u8 = null,
    use_cases: []const []const u8 = &.{},
    aliases: []const []const u8 = &.{},
    /// Free-form labels, e.g. "abliterated". Matched case-insensitively.
    tags: []const []const u8 = &.{},
    /// null = not stated in the catalog.
    access: ?Access = null,
    source: Source = .bundled,
};

pub const LoadError = error{ InvalidCatalog, OutOfMemory };

pub const Problem = struct {
    line: usize = 0,
    column: usize = 0,
    message: []const u8 = "",
};

pub const Catalog = struct {
    /// Lookup order: earlier entries win. Overlay entries go first.
    entries: std.ArrayList(Entry) = .empty,

    /// Parse `text` and add its entries. `prepend` puts them ahead of existing
    /// ones (used for the user overlay). On failure nothing is added.
    pub fn load(self: *Catalog, arena: std.mem.Allocator, gpa: std.mem.Allocator, text: []const u8, source: Source, problem: *Problem) LoadError!void {
        var diag: toml.Diagnostic = .{};
        var doc = toml.Document.parse(gpa, text, .{}, &diag) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                problem.* = .{ .line = diag.line, .column = diag.column, .message = @errorName(e) };
                return error.InvalidCatalog;
            },
        };
        defer doc.deinit();

        var parsed: std.ArrayList(Entry) = .empty;
        defer parsed.deinit(gpa);
        if (doc.root.get("model")) |mv| {
            if (mv != .array) return fail(problem, "'model' must be an array of tables ([[model]])");
            for (mv.array.items.items) |item| {
                if (item != .table) return fail(problem, "each [[model]] must be a table");
                const e = try parseEntry(arena, item.table, source, problem);
                try parsed.append(gpa, e);
            }
        }
        // Overlay (user) entries take priority over what is already loaded.
        if (source == .user) {
            try self.entries.insertSlice(arena, 0, parsed.items);
        } else {
            try self.entries.appendSlice(arena, parsed.items);
        }
    }

    /// Exact backend+id first, then aliases. Null when unknown.
    pub fn find(self: *const Catalog, kind: backend.Kind, id: []const u8) ?*const Entry {
        for (self.entries.items) |*e| {
            if (e.backend == kind and std.mem.eql(u8, e.id, id)) return e;
        }
        for (self.entries.items) |*e| {
            if (e.backend != kind) continue;
            for (e.aliases) |a| if (std.mem.eql(u8, a, id)) return e;
        }
        return null;
    }
};

fn fail(problem: *Problem, msg: []const u8) LoadError {
    problem.* = .{ .message = msg };
    return error.InvalidCatalog;
}

fn parseEntry(arena: std.mem.Allocator, t: *const toml.Table, source: Source, problem: *Problem) LoadError!Entry {
    const be = t.getString("backend") orelse return fail(problem, "model entry missing string 'backend'");
    const kind = std.meta.stringToEnum(backend.Kind, be) orelse return fail(problem, "unknown backend (expected \"ollama\" or \"llama\")");
    const id = t.getString("id") orelse return fail(problem, "model entry missing string 'id'");
    if (id.len == 0) return fail(problem, "model 'id' is empty");
    return .{
        .backend = kind,
        .id = try arena.dupe(u8, id),
        .name = try dupeOpt(arena, t.getString("name")),
        .description = try dupeOpt(arena, t.getString("description")),
        .notes = try dupeOpt(arena, t.getString("notes")),
        .use_cases = try strings(arena, t, "use_cases", problem),
        .aliases = try strings(arena, t, "aliases", problem),
        .tags = try strings(arena, t, "tags", problem),
        .access = if (t.getString("access")) |a| (std.meta.stringToEnum(Access, a) orelse return fail(problem, "unknown access (expected \"open\", \"signin\" or \"cloud\")")) else null,
        .source = source,
    };
}

fn dupeOpt(arena: std.mem.Allocator, s: ?[]const u8) !?[]const u8 {
    return if (s) |v| try arena.dupe(u8, v) else null;
}

fn strings(arena: std.mem.Allocator, t: *const toml.Table, key: []const u8, problem: *Problem) LoadError![]const []const u8 {
    const v = t.get(key) orelse return &.{};
    if (v != .array) return fail(problem, "expected an array of strings");
    var out: std.ArrayList([]const u8) = .empty;
    for (v.array.items.items) |item| {
        if (item != .string) return fail(problem, "expected an array of strings");
        try out.append(arena, try arena.dupe(u8, item.string));
    }
    return out.toOwnedSlice(arena);
}

pub const abliterated_tag = "abliterated";

fn containsFold(hay: []const u8, needle: []const u8) bool {
    return std.ascii.findIgnoreCase(hay, needle) != null;
}

pub fn hasTag(entry: ?*const Entry, tag: []const u8) bool {
    const e = entry orelse return false;
    for (e.tags) |t| if (std.ascii.eqlIgnoreCase(t, tag)) return true;
    return false;
}

/// "Abliterated" = refusal direction removed by weight editing (Arditi et al.
/// 2024). Detected from an explicit catalog tag, or heuristically from the
/// identifier / catalog name containing "abliterat". The heuristic can be
/// wrong in both directions; the catalog tag is authoritative when present.
pub fn isAbliterated(id: []const u8, entry: ?*const Entry) bool {
    if (hasTag(entry, abliterated_tag)) return true;
    if (containsFold(id, "abliterat")) return true;
    if (entry) |e| if (e.name) |n| if (containsFold(n, "abliterat")) return true;
    return false;
}

pub const abliterated_note = "Abliterated: refusal behavior was removed by editing weights. Outputs are not filtered by the model; detection here is by tag or name and is not verified.";

const bundled_text = @embedFile("models_toml");

pub fn loadBundled(arena: std.mem.Allocator, gpa: std.mem.Allocator, cat: *Catalog, problem: *Problem) LoadError!void {
    return cat.load(arena, gpa, bundled_text, .bundled, problem);
}

test "bundled catalog parses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cat: Catalog = .{};
    var p: Problem = .{};
    try loadBundled(arena.allocator(), std.testing.allocator, &cat, &p);
    try std.testing.expect(cat.entries.items.len >= 50);
    const e = cat.find(.llama, "ggml-org/Qwen3.5-0.8B-GGUF:Q8_0").?;
    try std.testing.expectEqualStrings("Qwen3.5 0.8B", e.name.?);
}

test "exact id beats alias; backend is part of identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cat: Catalog = .{};
    var p: Problem = .{};
    try cat.load(arena.allocator(), std.testing.allocator,
        \\[[model]]
        \\backend = "ollama"
        \\id = "a:1"
        \\name = "A"
        \\aliases = ["b:1"]
        \\[[model]]
        \\backend = "ollama"
        \\id = "b:1"
        \\name = "B"
    , .bundled, &p);
    try std.testing.expectEqualStrings("B", cat.find(.ollama, "b:1").?.name.?);
    try std.testing.expect(cat.find(.llama, "b:1") == null);
    try std.testing.expect(cat.find(.ollama, "zzz") == null);
}

test "user overlay overrides bundled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cat: Catalog = .{};
    var p: Problem = .{};
    const base = "[[model]]\nbackend = \"llama\"\nid = \"x\"\nname = \"Old\"\n";
    try cat.load(arena.allocator(), std.testing.allocator, base, .bundled, &p);
    try cat.load(arena.allocator(), std.testing.allocator, base ++ "", .user, &p);
    try std.testing.expectEqual(Source.user, cat.find(.llama, "x").?.source);
}

test "invalid catalogs are rejected visibly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cat: Catalog = .{};
    var p: Problem = .{};
    try std.testing.expectError(error.InvalidCatalog, cat.load(arena.allocator(), std.testing.allocator, "[[model]]\nbackend = \"nope\"\nid = \"x\"\n", .user, &p));
    try std.testing.expectError(error.InvalidCatalog, cat.load(arena.allocator(), std.testing.allocator, "this is = = not toml", .user, &p));
    try std.testing.expectEqual(@as(usize, 0), cat.entries.items.len);
}

test "abliteration detection" {
    try std.testing.expect(isAbliterated("huihui-ai/Qwen3-Abliterated-GGUF:Q4_K_M", null));
    try std.testing.expect(isAbliterated("llama3:8b-abliterated", null));
    try std.testing.expect(!isAbliterated("qwen3:8b", null));
    const tagged: Entry = .{ .backend = .ollama, .id = "x", .tags = &.{"Abliterated"} };
    try std.testing.expect(isAbliterated("x", &tagged));
    const named: Entry = .{ .backend = .ollama, .id = "y", .name = "Foo (abliterated)" };
    try std.testing.expect(isAbliterated("y", &named));
}

test "tags parse from toml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cat: Catalog = .{};
    var p: Problem = .{};
    try cat.load(arena.allocator(), std.testing.allocator, "[[model]]\nbackend=\"ollama\"\nid=\"m\"\ntags=[\"abliterated\"]\n", .user, &p);
    try std.testing.expect(isAbliterated("m", cat.find(.ollama, "m")));
}

test "access field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cat: Catalog = .{};
    var p: Problem = .{};
    try cat.load(arena.allocator(), std.testing.allocator, "[[model]]\nbackend=\"ollama\"\nid=\"a\"\naccess=\"cloud\"\n[[model]]\nbackend=\"llama\"\nid=\"b/c\"\naccess=\"signin\"\n[[model]]\nbackend=\"llama\"\nid=\"d/e\"\n", .user, &p);
    try std.testing.expectEqual(Access.cloud, cat.find(.ollama, "a").?.access.?);
    try std.testing.expect(!cat.find(.ollama, "a").?.access.?.runsOffline());
    try std.testing.expect(cat.find(.llama, "b/c").?.access.?.runsOffline());
    try std.testing.expect(cat.find(.llama, "d/e").?.access == null);
    try std.testing.expectError(error.InvalidCatalog, cat.load(arena.allocator(), std.testing.allocator, "[[model]]\nbackend=\"llama\"\nid=\"x/y\"\naccess=\"free\"\n", .user, &p));
}
