//! TUI application state. Owned allocations are noted per field.
const std = @import("std");
const backend = @import("../backend.zig");
const inventory = @import("../inventory.zig");
const catalog_io = @import("../catalog_io.zig");
const model = @import("model.zig");
const jobs = @import("jobs.zig");
const hardware = @import("../hardware.zig");
const catalog = @import("../catalog.zig");
const discover = @import("../discover.zig");
const agent_settings = @import("../agent/settings.zig");
const settings_view = @import("settings_view.zig");

pub const Target = struct { backend: backend.Kind, id: []const u8 };

pub const Action = union(enum) {
    pull: Target,
    update: Target,
    remove: Target,
    kill_job: u32,
    /// Hugging Face repo (gpa-owned) to abliterate.
    abliterate: []const u8,
    abliterate_setup,
    quit,
};

pub const Modal = struct {
    text: []const u8,
    action: Action,
};

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,

    /// Rebuilt on refresh: report, catalog, rows live here.
    data: std.heap.ArenaAllocator,
    /// Reset every frame.
    frame: std.heap.ArenaAllocator,
    report: inventory.Inventory = undefined,
    loaded: catalog_io.Loaded = .{},
    rows: []model.Row = &.{},
    /// Stored per-model agent settings (rebuilt on refresh).
    agent_entries: []const agent_settings.Entry = &.{},
    /// `ollama show` facts for installed Ollama models (rebuilt on refresh).
    infos: model.InfoMap = .empty,
    /// Results of the last online search (kept across refreshes).
    online_arena: std.heap.ArenaAllocator,
    online: []model.OnlineHit = &.{},
    hw: hardware.Info = .{ .mem = .{}, .gpus = &.{} },

    tab: model.Tab = .installed,
    sel: [5]usize = .{ 0, 0, 0, 0, 0 },
    filter: std.ArrayList(u8) = .empty,
    searching: bool = false,
    /// Single-line text prompt (label is a static string); input in prompt_buf.
    prompt: ?[]const u8 = null,
    prompt_buf: std.ArrayList(u8) = .empty,
    prompt_is_search: bool = false,
    prompt_is_agent: bool = false,
    /// Next sort used by the Discover "N" browse key (cycles each press).
    browse_sort: discover.Sort = .trending,
    sort: model.Sort = .name,
    only_abliterated: bool = false,
    /// 0 = no use-case filter, else index+1 into model.use_tags.
    use_idx: usize = 0,
    access_filter: ?catalog.Access = null,
    detail_full: bool = false,
    show_help: bool = false,
    modal: ?Modal = null,
    /// gpa-owned.
    message: []u8 = &.{},
    message_error: bool = false,
    quit: bool = false,

    jobs: jobs.Jobs,
    log_dir: ?[]const u8,
    use_color: bool,

    pub fn setMessage(self: *App, is_error: bool, comptime fmt: []const u8, args: anytype) void {
        const m = std.fmt.allocPrint(self.gpa, fmt, args) catch return;
        self.gpa.free(self.message);
        self.message = m;
        self.message_error = is_error;
    }

    pub fn currentRow(self: *const App) ?model.Row {
        if (self.tab != .installed and self.tab != .discover) return null;
        if (self.rows.len == 0) return null;
        return self.rows[@min(self.sel[@backingInt(self.tab)], self.rows.len - 1)];
    }

    /// Indices into jobs.list visible on the current (Transfers/Servers) tab.
    pub fn visibleJobs(self: *const App, arena: std.mem.Allocator) ![]usize {
        var out: std.ArrayList(usize) = .empty;
        for (self.jobs.list.items, 0..) |j, i| {
            const is_server = j.kind == .server;
            if ((self.tab == .servers) == is_server) try out.append(arena, i);
        }
        return out.toOwnedSlice(arena);
    }

    pub fn currentJob(self: *App) ?*jobs.Job {
        if (self.tab != .transfers and self.tab != .servers) return null;
        const vis = self.visibleJobs(self.frame.allocator()) catch return null;
        if (vis.len == 0) return null;
        return &self.jobs.list.items[vis[@min(self.sel[@backingInt(self.tab)], vis.len - 1)]];
    }

    /// Selectable rows of the Settings tab (sources, then tool-capable models).
    pub fn settingsItems(self: *const App, arena: std.mem.Allocator) ![]settings_view.Item {
        var models: std.ArrayList(backend.Model) = .empty;
        for (self.report.reports) |r| try models.appendSlice(arena, r.models orelse &.{});
        return settings_view.items(arena, self.loaded.sources, models.items, &self.infos, self.agent_entries);
    }
};
