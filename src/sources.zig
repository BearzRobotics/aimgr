//! Model sources: where aimgr looks for models to show in Discover. Each source
//! can be enabled or disabled, and users can add their own.
//!
//! Kinds
//!   bundled       the catalog snapshot shipped inside aimgr (offline)
//!   overlay       the user's models.toml in the config directory (offline)
//!   catalog-file  another catalog TOML file on disk (offline)
//!   catalog-url   an https URL to a catalog TOML; downloaded only by an explicit
//!                 `aimgr sources refresh`, then read from a local cache (offline)
//!   huggingface   online search/browse of GGUF repos through a Hugging Face compatible
//!                 API endpoint (network, only when the user searches/browses)
//!
//! Stored in $XDG_CONFIG_HOME/aimgr/config.toml as [[source]] tables. The order of
//! catalog sources is their precedence (earlier wins for the same backend+id).
const std = @import("std");
const toml = @import("toml");

pub const Kind = enum {
    bundled,
    overlay,
    catalog_file,
    catalog_url,
    huggingface,

    pub fn text(self: Kind) []const u8 {
        return switch (self) {
            .bundled => "bundled",
            .overlay => "overlay",
            .catalog_file => "catalog-file",
            .catalog_url => "catalog-url",
            .huggingface => "huggingface",
        };
    }

    pub fn parse(s: []const u8) ?Kind {
        inline for (.{ Kind.bundled, Kind.overlay, Kind.catalog_file, Kind.catalog_url, Kind.huggingface }) |k| {
            if (std.mem.eql(u8, s, k.text())) return k;
        }
        return null;
    }

    pub fn isCatalog(self: Kind) bool {
        return self != .huggingface;
    }

    pub fn isOnline(self: Kind) bool {
        return self == .huggingface;
    }
};

pub const default_hf_endpoint = "https://huggingface.co";

pub const Source = struct {
    id: []const u8,
    kind: Kind,
    enabled: bool = true,
    /// overlay: optional path; catalog-file: path; catalog-url: https URL; huggingface: endpoint.
    location: ?[]const u8 = null,

    /// Built-in sources can be disabled but not removed.
    pub fn builtin(self: Source) bool {
        return std.mem.eql(u8, self.id, "bundled") or std.mem.eql(u8, self.id, "user-overlay") or std.mem.eql(u8, self.id, "huggingface");
    }

    pub fn endpoint(self: Source) []const u8 {
        return self.location orelse default_hf_endpoint;
    }
};

pub const Error = error{
    InvalidId,
    DuplicateId,
    UnknownKind,
    MissingLocation,
    InsecureUrl,
    InvalidLocation,
    NoSuchSource,
    BuiltinSource,
    InvalidConfig,
    OutOfMemory,
};

pub fn errorText(e: Error) []const u8 {
    return switch (e) {
        error.InvalidId => "source id must be 1-48 chars of a-z 0-9 . _ - and start with a letter or digit",
        error.DuplicateId => "a source with that id already exists",
        error.UnknownKind => "unknown source kind (bundled, overlay, catalog-file, catalog-url, huggingface)",
        error.MissingLocation => "this kind of source needs a location (file path or https URL)",
        error.InsecureUrl => "URLs must use https://",
        error.InvalidLocation => "location is empty, too long, or contains control characters",
        error.NoSuchSource => "no source with that id",
        error.BuiltinSource => "built-in sources can be disabled but not removed",
        error.InvalidConfig => "config.toml has an invalid [[source]] entry",
        error.OutOfMemory => "out of memory",
    };
}

pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 48) return false;
    if (!std.ascii.isAlphanumeric(id[0]) or std.ascii.isUpper(id[0])) return false;
    for (id) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '.' or c == '_' or c == '-')) return false;
    return true;
}

fn validLocationText(l: []const u8) bool {
    if (l.len == 0 or l.len > 1024) return false;
    for (l) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

pub fn validate(s: Source) Error!void {
    if (!validId(s.id)) return error.InvalidId;
    switch (s.kind) {
        .bundled => {},
        .overlay => if (s.location) |l| if (!validLocationText(l)) return error.InvalidLocation,
        .catalog_file => {
            const l = s.location orelse return error.MissingLocation;
            if (!validLocationText(l) or l[0] == '-') return error.InvalidLocation;
        },
        .catalog_url, .huggingface => {
            const l = s.location orelse {
                if (s.kind == .huggingface) return;
                return error.MissingLocation;
            };
            if (!validLocationText(l)) return error.InvalidLocation;
            if (!std.mem.startsWith(u8, l, "https://") or l.len <= 8) return error.InsecureUrl;
            if (std.mem.indexOfAny(u8, l, " \t") != null) return error.InvalidLocation;
        },
    }
}

/// Used when config.toml has no [[source]] tables. Order = precedence.
pub fn defaults(arena: std.mem.Allocator) ![]Source {
    const list = try arena.alloc(Source, 3);
    list[0] = .{ .id = "user-overlay", .kind = .overlay };
    list[1] = .{ .id = "bundled", .kind = .bundled };
    list[2] = .{ .id = "huggingface", .kind = .huggingface };
    return list;
}

/// Parse [[source]] tables out of config.toml text. No tables => defaults.
pub fn parse(arena: std.mem.Allocator, gpa: std.mem.Allocator, text: []const u8) Error![]Source {
    var doc = toml.Document.parse(gpa, text, .{}, null) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidConfig,
    };
    defer doc.deinit();
    const v = doc.root.get("source") orelse return defaults(arena);
    if (v != .array) return error.InvalidConfig;
    var out: std.ArrayList(Source) = .empty;
    for (v.array.items.items) |item| {
        if (item != .table) return error.InvalidConfig;
        const t = item.table;
        const id = t.getString("id") orelse return error.InvalidConfig;
        const kind_s = t.getString("kind") orelse return error.InvalidConfig;
        const kind = Kind.parse(kind_s) orelse return error.UnknownKind;
        const src: Source = .{
            .id = try arena.dupe(u8, id),
            .kind = kind,
            .enabled = t.getBool("enabled") orelse true,
            .location = if (t.getString("location")) |l| try arena.dupe(u8, l) else null,
        };
        try validate(src);
        for (out.items) |o| if (std.mem.eql(u8, o.id, src.id)) return error.DuplicateId;
        try out.append(arena, src);
    }
    if (out.items.len == 0) return defaults(arena);
    return out.toOwnedSlice(arena);
}

fn tomlQuote(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        0...8, 11...31, 127 => try w.print("\\u{X:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

pub fn serialize(arena: std.mem.Allocator, sources: []const Source) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("# aimgr configuration (managed by `aimgr sources`; comments are not preserved when it rewrites this file)\n");
    for (sources) |s| {
        try w.writeAll("\n[[source]]\nid = ");
        try tomlQuote(w, s.id);
        try w.print("\nkind = \"{s}\"\nenabled = {s}\n", .{ s.kind.text(), if (s.enabled) "true" else "false" });
        if (s.location) |l| {
            try w.writeAll("location = ");
            try tomlQuote(w, l);
            try w.writeByte('\n');
        }
    }
    return aw.toOwnedSlice();
}

pub fn find(sources: []const Source, id: []const u8) ?usize {
    for (sources, 0..) |s, i| if (std.mem.eql(u8, s.id, id)) return i;
    return null;
}

pub fn add(arena: std.mem.Allocator, list: *std.ArrayList(Source), s: Source) Error!void {
    try validate(s);
    if (find(list.items, s.id) != null) return error.DuplicateId;
    try list.append(arena, .{ .id = try arena.dupe(u8, s.id), .kind = s.kind, .enabled = s.enabled, .location = if (s.location) |l| try arena.dupe(u8, l) else null });
}

pub fn setEnabled(list: []Source, id: []const u8, enabled: bool) Error!void {
    const i = find(list, id) orelse return error.NoSuchSource;
    list[i].enabled = enabled;
}

pub fn remove(list: *std.ArrayList(Source), id: []const u8) Error!void {
    const i = find(list.items, id) orelse return error.NoSuchSource;
    if (list.items[i].builtin()) return error.BuiltinSource;
    _ = list.orderedRemove(i);
}

/// Cache file name for a catalog-url source (the id is already restricted to safe characters).
pub fn cacheFileName(arena: std.mem.Allocator, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}.toml", .{id});
}

test "id and location validation" {
    try std.testing.expect(validId("team-catalog_2"));
    try std.testing.expect(!validId("Team"));
    try std.testing.expect(!validId("-x"));
    try std.testing.expect(!validId("a b"));
    try std.testing.expect(!validId(""));
    try std.testing.expectError(error.MissingLocation, validate(.{ .id = "x", .kind = .catalog_url }));
    try std.testing.expectError(error.InsecureUrl, validate(.{ .id = "x", .kind = .catalog_url, .location = "http://example.org/c.toml" }));
    try std.testing.expectError(error.InsecureUrl, validate(.{ .id = "x", .kind = .huggingface, .location = "ftp://mirror" }));
    try validate(.{ .id = "x", .kind = .catalog_url, .location = "https://example.org/c.toml" });
    try validate(.{ .id = "mirror", .kind = .huggingface, .location = "https://hf-mirror.example" });
    try validate(.{ .id = "hf", .kind = .huggingface });
    try std.testing.expectError(error.InvalidLocation, validate(.{ .id = "f", .kind = .catalog_file, .location = "a\nb" }));
    try std.testing.expectError(error.InvalidLocation, validate(.{ .id = "f", .kind = .catalog_file, .location = "-rf" }));
}

test "defaults when the file has no sources" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const s = try parse(a.allocator(), std.testing.allocator, "# nothing here\n");
    try std.testing.expectEqual(@as(usize, 3), s.len);
    try std.testing.expectEqualStrings("user-overlay", s[0].id);
    try std.testing.expect(s[2].kind == .huggingface and s[2].enabled);
}

test "serialize/parse round trip, including awkward strings" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    var list: std.ArrayList(Source) = .empty;
    for (try defaults(a.allocator())) |d| try list.append(a.allocator(), d);
    try add(a.allocator(), &list, .{ .id = "team", .kind = .catalog_url, .location = "https://example.org/a b".*[0..19] });
    try add(a.allocator(), &list, .{ .id = "mine", .kind = .catalog_file, .location = "/tmp/my \"models\"\\x.toml", .enabled = false });
    const text = try serialize(a.allocator(), list.items);
    const back = try parse(a.allocator(), std.testing.allocator, text);
    try std.testing.expectEqual(list.items.len, back.len);
    for (list.items, back) |x, y| {
        try std.testing.expectEqualStrings(x.id, y.id);
        try std.testing.expectEqual(x.kind, y.kind);
        try std.testing.expectEqual(x.enabled, y.enabled);
        try std.testing.expectEqualDeep(x.location, y.location);
    }
}

test "operations" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    var list: std.ArrayList(Source) = .empty;
    for (try defaults(a.allocator())) |d| try list.append(a.allocator(), d);
    try add(a.allocator(), &list, .{ .id = "team", .kind = .catalog_url, .location = "https://example.org/c.toml" });
    try std.testing.expectError(error.DuplicateId, add(a.allocator(), &list, .{ .id = "team", .kind = .catalog_file, .location = "x" }));
    try setEnabled(list.items, "team", false);
    try std.testing.expect(!list.items[find(list.items, "team").?].enabled);
    try std.testing.expectError(error.NoSuchSource, setEnabled(list.items, "nope", true));
    try std.testing.expectError(error.BuiltinSource, remove(&list, "bundled"));
    try remove(&list, "team");
    try std.testing.expect(find(list.items, "team") == null);
}

test "bad config entries are rejected" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const g = std.testing.allocator;
    try std.testing.expectError(error.UnknownKind, parse(a.allocator(), g, "[[source]]\nid=\"x\"\nkind=\"ftp\"\n"));
    try std.testing.expectError(error.DuplicateId, parse(a.allocator(), g, "[[source]]\nid=\"x\"\nkind=\"bundled\"\n[[source]]\nid=\"x\"\nkind=\"bundled\"\n"));
    try std.testing.expectError(error.InsecureUrl, parse(a.allocator(), g, "[[source]]\nid=\"x\"\nkind=\"catalog-url\"\nlocation=\"http://e.org/c\"\n"));
    try std.testing.expectError(error.InvalidConfig, parse(a.allocator(), g, "this is = = bad"));
}
