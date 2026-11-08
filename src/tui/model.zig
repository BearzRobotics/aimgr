//! Pure TUI data model: tabs, rows, filtering, sorting. No curses here, so it
//! is unit-tested. Installed rows come from the backends (authoritative);
//! Discover rows are catalog entries that are not installed (offline).
const std = @import("std");
const backend = @import("../backend.zig");
const catalog = @import("../catalog.zig");
const inventory = @import("../inventory.zig");

pub const Tab = enum {
    installed,
    discover,
    transfers,
    servers,
    settings,

    pub fn title(self: Tab) []const u8 {
        return switch (self) {
            .installed => "Installed",
            .discover => "Discover",
            .transfers => "Transfers",
            .servers => "Servers",
            .settings => "Settings",
        };
    }
};

pub const Sort = enum {
    name,
    backend,
    size,

    pub fn next(self: Sort) Sort {
        return switch (self) {
            .name => .backend,
            .backend => .size,
            .size => .name,
        };
    }
};

/// Controlled vocabulary of use-case tags (see tools/catalog-gen/gen.py). The `t` key cycles through it.
pub const use_tags = [_][]const u8{ "coding", "reasoning", "vision", "tools", "chat", "long-context", "small", "math", "multilingual", "creative-writing" };

pub const OnlineHit = struct { id: []const u8, downloads: u64, likes: u64, signin: bool = false };

pub const Row = struct {
    /// Short extra text shown after the title (e.g. online download counts).
    note: ?[]const u8 = null,
    model: backend.Model,
    entry: ?*const catalog.Entry,
    installed: bool,
    abliterated: bool,
    /// What it takes to get/run it (from the catalog, or "sign-in" for gated online hits).
    access: ?catalog.Access = null,

    pub fn title(self: Row) []const u8 {
        if (self.entry) |e| if (e.name) |n| return n;
        return self.model.id;
    }
};

pub const parseSize = backend.parseSizeText;

fn has(hay: []const u8, needle: []const u8) bool {
    return std.ascii.findIgnoreCase(hay, needle) != null;
}

pub fn matchesFilter(r: Row, f: []const u8) bool {
    if (f.len == 0) return true;
    if (has(r.model.id, f) or has(r.model.backend.name(), f)) return true;
    if (r.abliterated and has(catalog.abliterated_tag, f)) return true;
    if (r.access) |a| if (has(a.label(), f)) return true;
    const e = r.entry orelse return false;
    if (e.name) |n| if (has(n, f)) return true;
    if (e.description) |d| if (has(d, f)) return true;
    for (e.use_cases) |u| if (has(u, f)) return true;
    for (e.tags) |t| if (has(t, f)) return true;
    return false;
}

fn lessThan(sort: Sort, a: Row, b: Row) bool {
    switch (sort) {
        .name => {},
        .backend => if (a.model.backend != b.model.backend) return @backingInt(a.model.backend) < @backingInt(b.model.backend),
        .size => {
            const sa = parseSize(a.model.size_text);
            const sb = parseSize(b.model.size_text);
            // Largest first; unknown sizes last.
            if (sa != null and sb != null and sa.? != sb.?) return sa.? > sb.?;
            if ((sa == null) != (sb == null)) return sa != null;
        },
    }
    return std.ascii.lessThanIgnoreCase(a.title(), b.title());
}

/// Extra row filters (null = no restriction).
pub const Extra = struct {
    /// Keep only entries whose use_cases contain this tag (exact, case-insensitive).
    use: ?[]const u8 = null,
    access: ?catalog.Access = null,
};

pub fn buildRows(
    arena: std.mem.Allocator,
    tab: Tab,
    report: inventory.Inventory,
    cat: *const catalog.Catalog,
    filter: []const u8,
    sort: Sort,
    only_abliterated: bool,
    online: []const OnlineHit,
) ![]Row {
    return buildRowsEx(arena, tab, report, cat, filter, sort, only_abliterated, online, .{});
}

fn hasUse(r: Row, use: []const u8) bool {
    const e = r.entry orelse return false;
    for (e.use_cases) |u| if (std.ascii.eqlIgnoreCase(u, use)) return true;
    return false;
}

/// Build visible rows for the Installed or Discover tab.
pub fn buildRowsEx(
    arena: std.mem.Allocator,
    tab: Tab,
    report: inventory.Inventory,
    cat: *const catalog.Catalog,
    filter: []const u8,
    sort: Sort,
    only_abliterated: bool,
    online: []const OnlineHit,
    extra: Extra,
) ![]Row {
    var rows: std.ArrayList(Row) = .empty;
    switch (tab) {
        .installed => for (report.reports) |r| for (r.models orelse &.{}) |m| {
            try rows.append(arena, makeRow(m, cat.find(m.backend, m.id), true));
        },
        .discover => for (cat.entries.items) |*e| {
            if (isInstalled(report, e.backend, e.id)) continue;
            try rows.append(arena, makeRow(.{ .backend = e.backend, .id = e.id }, e, false));
        },
        else => {},
    }
    if (tab == .discover) for (online) |h| {
        var r = makeRow(.{ .backend = .llama, .id = h.id }, cat.find(.llama, h.id), false);
        if (r.access == null and h.signin) r.access = .signin;
        r.note = try std.fmt.allocPrint(arena, "online, {d} downloads", .{h.downloads});
        try rows.append(arena, r);
    };
    var out: std.ArrayList(Row) = .empty;
    for (rows.items) |r| {
        if (only_abliterated and !r.abliterated) continue;
        if (extra.use) |u| if (!hasUse(r, u)) continue;
        if (extra.access) |a| if (r.access == null or r.access.? != a) continue;
        if (matchesFilter(r, filter)) try out.append(arena, r);
    }
    std.mem.sort(Row, out.items, sort, struct {
        fn lt(s: Sort, a: Row, b: Row) bool {
            return lessThan(s, a, b);
        }
    }.lt);
    return out.toOwnedSlice(arena);
}

fn makeRow(m: backend.Model, e: ?*const catalog.Entry, installed: bool) Row {
    return .{ .model = m, .entry = e, .installed = installed, .abliterated = catalog.isAbliterated(m.id, e), .access = if (e) |x| x.access else null };
}

pub fn isInstalled(report: inventory.Inventory, kind: backend.Kind, id: []const u8) bool {
    for (report.reports) |r| {
        if (r.kind != kind) continue;
        for (r.models orelse &.{}) |m| if (std.mem.eql(u8, m.id, id)) return true;
    }
    return false;
}

test "parseSize" {
    try std.testing.expectEqual(@as(?u64, 17_000_000_000), parseSize("17 GB"));
    try std.testing.expectEqual(@as(?u64, 4_700_000_000), parseSize("4.7 GB"));
    try std.testing.expectEqual(@as(?u64, 512_000_000), parseSize("512 MB"));
    try std.testing.expect(parseSize("big") == null);
    try std.testing.expect(parseSize(null) == null);
}

fn fixture(arena: std.mem.Allocator) !struct { inventory.Inventory, catalog.Catalog } {
    const models = try arena.dupe(backend.Model, &.{
        .{ .backend = .ollama, .id = "zeta:1b", .size_text = "1.0 GB" },
        .{ .backend = .ollama, .id = "alpha:7b", .size_text = "4.7 GB" },
        .{ .backend = .llama, .id = "x/Foo-Abliterated-GGUF:Q4", .quant = "Q4" },
    });
    const inv: inventory.Inventory = .{ .reports = .{
        .{ .kind = .ollama, .probe = .{ .available = "1" }, .models = models[0..2] },
        .{ .kind = .llama, .probe = .{ .available = "1" }, .models = models[2..3] },
    } };
    var cat: catalog.Catalog = .{};
    var p: catalog.Problem = .{};
    try cat.load(arena, std.testing.allocator,
        \\[[model]]
        \\backend = "ollama"
        \\id = "alpha:7b"
        \\name = "Alpha"
        \\use_cases = ["coding"]
        \\[[model]]
        \\backend = "ollama"
        \\id = "notinstalled:3b"
        \\name = "Not Installed"
    , .bundled, &p);
    return .{ inv, cat };
}

test "installed rows, sort, filter, abliterated" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const inv, const cat = try fixture(a.allocator());
    const all = try buildRows(a.allocator(), .installed, inv, &cat, "", .name, false, &.{});
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expectEqualStrings("Alpha", all[0].title());
    const by_size = try buildRows(a.allocator(), .installed, inv, &cat, "", .size, false, &.{});
    try std.testing.expectEqualStrings("alpha:7b", by_size[0].model.id); // 4.7 GB first
    const coding = try buildRows(a.allocator(), .installed, inv, &cat, "coding", .name, false, &.{});
    try std.testing.expectEqual(@as(usize, 1), coding.len);
    const ab = try buildRows(a.allocator(), .installed, inv, &cat, "", .name, true, &.{});
    try std.testing.expectEqual(@as(usize, 1), ab.len);
    try std.testing.expect(ab[0].abliterated);
}

test "discover lists only uninstalled catalog entries" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const inv, const cat = try fixture(a.allocator());
    const rows = try buildRows(a.allocator(), .discover, inv, &cat, "", .name, false, &.{});
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("notinstalled:3b", rows[0].model.id);
    try std.testing.expect(!rows[0].installed);
}

test "online hits appear on Discover only, as uninstalled rows with a note" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const inv, const cat = try fixture(a.allocator());
    const hits = [_]OnlineHit{.{ .id = "owner/Some-Abliterated-GGUF", .downloads = 42, .likes = 1 }};
    const d = try buildRows(a.allocator(), .discover, inv, &cat, "", .name, false, &hits);
    try std.testing.expectEqual(@as(usize, 2), d.len);
    var found = false;
    for (d) |r| if (std.mem.eql(u8, r.model.id, "owner/Some-Abliterated-GGUF")) {
        found = true;
        try std.testing.expect(!r.installed and r.abliterated);
        try std.testing.expect(std.mem.indexOf(u8, r.note.?, "42") != null);
    };
    try std.testing.expect(found);
    const i = try buildRows(a.allocator(), .installed, inv, &cat, "", .name, false, &hits);
    try std.testing.expectEqual(@as(usize, 3), i.len);
}

test "use and access filters" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const inv, var cat = try fixture(a.allocator());
    var p: catalog.Problem = .{};
    try cat.load(a.allocator(), std.testing.allocator,
        \\[[model]]
        \\backend = "ollama"
        \\id = "cloudy:1"
        \\use_cases = ["chat", "Coding"]
        \\access = "cloud"
        \\[[model]]
        \\backend = "llama"
        \\id = "o/gated-GGUF"
        \\use_cases = ["vision"]
        \\access = "signin"
    , .user, &p);
    const coding = try buildRowsEx(a.allocator(), .discover, inv, &cat, "", .name, false, &.{}, .{ .use = "coding" });
    try std.testing.expectEqual(@as(usize, 1), coding.len);
    try std.testing.expectEqualStrings("cloudy:1", coding[0].model.id);
    const gated = try buildRowsEx(a.allocator(), .discover, inv, &cat, "", .name, false, &.{}, .{ .access = .signin });
    try std.testing.expectEqual(@as(usize, 1), gated.len);
    const hits = [_]OnlineHit{.{ .id = "x/y-GGUF", .downloads = 1, .likes = 0, .signin = true }};
    const online = try buildRowsEx(a.allocator(), .discover, inv, &cat, "", .name, false, &hits, .{ .access = .signin });
    try std.testing.expectEqual(@as(usize, 2), online.len);
}
