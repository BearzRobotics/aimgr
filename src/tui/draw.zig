//! Rendering. Never relies on color alone: selection uses a "> " marker plus
//! reverse video, status is always spelled out in words.
const std = @import("std");
const term = @import("term.zig");
const model = @import("model.zig");
const jobs = @import("jobs.zig");
const catalog = @import("../catalog.zig");
const manage = @import("../manage.zig");
const backend_mod = @import("../backend.zig");
const netstat = @import("../netstat.zig");
const launcher = @import("../launcher.zig");
const hardware = @import("../hardware.zig");
const State = @import("state.zig");

const App = State.App;

pub fn draw(app: *App) void {
    _ = app.frame.reset(.retain_capacity);
    const a = app.frame.allocator();
    const sz = term.size();
    term.erase();
    if (sz.rows < 8 or sz.cols < 40) {
        term.put(0, 0, sz.cols, "terminal too small (need 40x8)");
        term.flush();
        return;
    }
    drawTabs(app, sz.cols);
    const body_top: usize = 1;
    const body_h = sz.rows - 3;
    if (app.show_help) {
        drawHelp(sz.cols, body_top, body_h);
    } else switch (app.tab) {
        .installed, .discover => drawModels(app, a, sz.cols, body_top, body_h) catch {},
        .transfers, .servers => drawJobs(app, a, sz.cols, body_top, body_h) catch {},
        .settings => drawSettings(app, a, sz.cols, body_top, body_h) catch {},
    }
    drawStatus(app, sz.rows, sz.cols);
    if (app.modal) |m| drawModal(m.text, sz.rows, sz.cols);
    term.flush();
}

fn drawTabs(app: *App, cols: usize) void {
    var col: usize = 0;
    const tabs = [_]model.Tab{ .installed, .discover, .transfers, .servers, .settings };
    for (tabs, 0..) |t, i| {
        const active = t == app.tab;
        var buf: [48]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{s}{d} {s}{s}", .{ if (active) "[" else " ", i + 1, t.title(), if (active) "]" else " " }) catch "?";
        term.setAttr(if (active) term.A_REVERSE | term.A_BOLD else 0);
        term.put(0, col, cols - @min(col, cols), label);
        col += label.len + 1;
    }
    term.setAttr(0);
    if (app.jobs.activeCount() > 0) {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "jobs running: {d}", .{app.jobs.activeCount()}) catch "";
        if (cols > s.len + col) term.put(0, cols - s.len, s.len, s);
    }
}

fn clampSel(app: *App, len: usize) usize {
    const i = &app.sel[@backingInt(app.tab)];
    if (len == 0) i.* = 0 else if (i.* >= len) i.* = len - 1;
    return i.*;
}

fn drawModels(app: *App, a: std.mem.Allocator, cols: usize, top: usize, h: usize) !void {
    const sel = clampSel(app, app.rows.len);
    if (app.detail_full) {
        if (app.currentRow()) |row| try drawDetail(app, a, row, 0, cols, top, h);
        return;
    }
    const wide = cols >= 100;
    const list_w = if (wide) cols * 55 / 100 else cols;
    // header line with filter / sort state
    var hdr: std.ArrayList(u8) = .empty;
    try hdr.print(a, "{s} {d} model(s)  sort:{s}", .{ if (app.tab == .installed) "Installed:" else "Not installed (catalog):", app.rows.len, @tagName(app.sort) });
    if (app.filter.items.len > 0 or app.searching) try hdr.print(a, "  filter:\"{s}\"{s}", .{ app.filter.items, if (app.searching) "_" else "" });
    if (app.only_abliterated) try hdr.appendSlice(a, "  [abliterated only]");
    if (app.use_idx > 0) try hdr.print(a, "  good-for:{s}", .{model.use_tags[app.use_idx - 1]});
    if (app.access_filter) |af| try hdr.print(a, "  access:{s}", .{af.label()});
    term.setAttr(term.A_BOLD);
    term.put(top, 0, list_w, hdr.items);
    term.setAttr(0);

    const list_h = h - 1;
    var first: usize = 0;
    if (sel >= list_h) first = sel - list_h + 1;
    if (app.rows.len == 0) {
        const msg = if (app.tab == .installed) "No models found. Press r to refresh; see Settings for backend status." else "Nothing to discover: every catalog entry is installed (or filtered out).";
        term.put(top + 2, 2, list_w, msg);
    }
    var r: usize = 0;
    while (r < list_h and first + r < app.rows.len) : (r += 1) {
        const row = app.rows[first + r];
        const is_sel = first + r == sel;
        var line: std.ArrayList(u8) = .empty;
        try line.print(a, "{s}{s:<6} {s}", .{ if (is_sel) "> " else "  ", row.model.backend.name(), row.title() });
        if (row.model.size_text) |s| try line.print(a, "  {s}", .{s});
        if (row.abliterated) try line.appendSlice(a, "  [abliterated]");
        if (row.access) |ac| if (ac != .open) try line.print(a, "  [{s}]", .{ac.label()});
        if (row.note) |n| try line.print(a, "  ({s})", .{n});
        term.setAttr(if (is_sel) term.A_REVERSE else 0);
        term.put(top + 1 + r, 0, list_w, line.items);
    }
    term.setAttr(0);

    if (wide) {
        const dx = list_w + 1;
        {
            var y: usize = top;
            while (y < top + h) : (y += 1) term.put(y, list_w, 1, "|");
        }
        if (app.currentRow()) |row| try drawDetail(app, a, row, dx, cols - dx, top, h);
    }
}

pub fn wrap(a: std.mem.Allocator, text: []const u8, width: usize, out: *std.ArrayList([]const u8)) !void {
    if (width < 4) return;
    var rest = std.mem.trim(u8, text, " ");
    while (rest.len > 0) {
        if (rest.len <= width) {
            try out.append(a, rest);
            return;
        }
        var cut = width;
        if (rest[width] != ' ') {
            if (std.mem.lastIndexOfScalar(u8, rest[0..width], ' ')) |sp| if (sp > 0) {
                cut = sp;
            };
        }
        // never split a UTF-8 sequence
        while (cut > 0 and cut < rest.len and (rest[cut] & 0xC0) == 0x80) cut -= 1;
        try out.append(a, std.mem.trimEnd(u8, rest[0..cut], " "));
        rest = std.mem.trimStart(u8, rest[cut..], " ");
    }
}

fn drawDetail(app: *App, a: std.mem.Allocator, row: model.Row, x: usize, w: usize, top: usize, h: usize) !void {
    var lines: std.ArrayList([]const u8) = .empty;
    const inner = if (w > 2) w - 2 else w;
    const kv = struct {
        fn add(al: std.mem.Allocator, ls: *std.ArrayList([]const u8), iw: usize, k: []const u8, v: []const u8) !void {
            const t = try std.fmt.allocPrint(al, "{s}: {s}", .{ k, v });
            try wrap(al, t, iw, ls);
        }
    };
    try kv.add(a, &lines, inner, "Name", row.title());
    try kv.add(a, &lines, inner, "Backend", row.model.backend.name());
    try kv.add(a, &lines, inner, "Exact ID", row.model.id);
    try kv.add(a, &lines, inner, "Status", if (row.installed) "installed" else "not installed");
    if (row.model.size_text) |s| try kv.add(a, &lines, inner, "Size", s);
    if (row.model.quant) |q| try kv.add(a, &lines, inner, "Quantization", q);
    if (row.model.modified) |m| try kv.add(a, &lines, inner, "Modified", m);
    if (row.model.digest) |d| try kv.add(a, &lines, inner, "Digest", d);
    if (row.entry) |e| {
        if (e.description) |d| try kv.add(a, &lines, inner, "About", d);
        if (e.use_cases.len > 0) try kv.add(a, &lines, inner, "Good for (derived hints, not benchmarks)", try std.mem.join(a, ", ", e.use_cases));
        if (e.tags.len > 0) try kv.add(a, &lines, inner, "Tags", try std.mem.join(a, ", ", e.tags));
        if (e.notes) |n| try kv.add(a, &lines, inner, "Notes", n);
        try kv.add(a, &lines, inner, "Catalog", @tagName(e.source));
    } else try kv.add(a, &lines, inner, "Catalog", "no entry (metadata unknown)");
    if (row.access) |ac| try kv.add(a, &lines, inner, "Access", try std.fmt.allocPrint(a, "{s} - {s}", .{ ac.label(), ac.explain() })) else if (!row.installed) try kv.add(a, &lines, inner, "Access", "unknown (not stated in the catalog)");
    if (row.abliterated) try wrap(a, catalog.abliterated_note, inner, &lines);
    {
        const fit = hardware.estimate(row.model.id, row.model.quant, backend_mod.parseSizeText(row.model.size_text), 4096, app.hw);
        try kv.add(a, &lines, inner, "Hardware fit (advisory)", fit.verdict.text());
        if (fit.verdict != .unknown) {
            try kv.add(a, &lines, inner, "  estimate", try std.fmt.allocPrint(a, "about {d:.1}-{d:.1} GB at 4096 context (weights {d:.1} GB, {s})", .{ hardware.gb(fit.need_low), hardware.gb(fit.need_high), hardware.gb(fit.weights), if (fit.weights_estimated) "estimated from the name and quant" else "as reported" }));
        }
    }
    if (row.installed) {
        var all: std.ArrayList(@import("../backend.zig").Model) = .empty;
        for (app.report.reports) |r| try all.appendSlice(a, r.models orelse &.{});
        for (try manage.duplicates(a, all.items, row.model.backend, row.model.id)) |d| {
            try kv.add(a, &lines, inner, if (d.exact_id) "Same id in" else "Similar", try std.fmt.allocPrint(a, "{s} {s}", .{ d.model.backend.name(), d.model.id }));
        }
        if (manage.unsupportedReason(row.model.backend, .remove)) |why| try kv.add(a, &lines, inner, "Delete disabled", why);
    }
    for (lines.items, 0..) |l, i| {
        if (i >= h) break;
        term.put(top + i, x + 1, inner, l);
    }
}

fn drawJobs(app: *App, a: std.mem.Allocator, cols: usize, top: usize, h: usize) !void {
    const vis = try app.visibleJobs(a);
    const sel = clampSel(app, vis.len);
    term.setAttr(term.A_BOLD);
    term.put(top, 0, cols, if (app.tab == .servers) "Servers (started by aimgr)" else "Transfers (pull / update / remove)");
    term.setAttr(0);
    if (vis.len == 0) {
        term.put(top + 2, 2, cols, if (app.tab == .servers) "No servers. Select a model on Installed and press s." else "No transfers. Press d on Discover or u / x on Installed.");
        return;
    }
    var r: usize = 0;
    while (r < vis.len and r < h / 2) : (r += 1) {
        const j = app.jobs.list.items[vis[r]];
        var line: std.ArrayList(u8) = .empty;
        const status = if (j.kind == .server and j.state == .running) (if (j.listening) "LISTENING" else "STARTING") else stateWord(j.state);
        try line.print(a, "{s}#{d} {s:<10} {s:<10} {s:<6} {s}", .{ if (r == sel) "> " else "  ", j.id, status, @tagName(j.kind), j.backend.name(), if (j.model.len > 0) j.model else if (j.kind == .server) "(daemon)" else "(environment)" });
        if (j.port) |p| try line.print(a, " :{d}", .{p});
        term.setAttr(if (r == sel) term.A_REVERSE else 0);
        term.put(top + 1 + r, 0, cols, line.items);
    }
    term.setAttr(0);
    const j = app.jobs.list.items[vis[sel]];
    var y = top + 2 + @min(vis.len, h / 2);
    var cmd: std.ArrayList(u8) = .empty;
    for (j.argv) |arg| try cmd.print(a, "{s} ", .{arg});
    const info = [_][]const u8{
        try std.fmt.allocPrint(a, "Command: {s}", .{cmd.items}),
        try std.fmt.allocPrint(a, "Log: {s}", .{j.log_path}),
        try std.fmt.allocPrint(a, "Latest output: {s}", .{if (j.last_line.len > 0) j.last_line else "(none yet)"}),
        if (j.exit_code) |c| try std.fmt.allocPrint(a, "Exit code: {d}", .{c}) else "Exit code: (running)",
    };
    for (info) |s| {
        if (y >= top + h) break;
        term.put(y, 2, cols - 2, s);
        y += 1;
    }
}

fn stateWord(s: jobs.State) []const u8 {
    return switch (s) {
        .running => "RUNNING",
        .stopping => "STOPPING",
        .done => "DONE",
        .failed => "FAILED",
        .cancelled => "CANCELLED",
    };
}

fn drawSettings(app: *App, a: std.mem.Allocator, cols: usize, top: usize, h: usize) !void {
    var lines: std.ArrayList([]const u8) = .empty;
    try lines.append(a, "Backends");
    for (app.report.reports) |r| {
        const text = switch (r.probe) {
            .available => |v| try std.fmt.allocPrint(a, "  {s}: available, version {s}", .{ r.kind.name(), v }),
            .missing => try std.fmt.allocPrint(a, "  {s}: UNAVAILABLE (executable not found)", .{r.kind.name()}),
            .failed => |why| try std.fmt.allocPrint(a, "  {s}: UNAVAILABLE ({s})", .{ r.kind.name(), why }),
        };
        try lines.append(a, text);
        if (r.list_error) |e| try lines.append(a, try std.fmt.allocPrint(a, "    list error: {s}", .{@import("../inventory.zig").listErrorText(e)}));
        if (manage.unsupportedReason(r.kind, .remove)) |why| try lines.append(a, try std.fmt.allocPrint(a, "    delete disabled: {s}", .{why}));
    }
    try lines.append(a, "");
    try lines.append(a, "Catalog");
    try lines.append(a, try std.fmt.allocPrint(a, "  entries: {d}", .{app.loaded.cat.entries.items.len}));
    try lines.append(a, try std.fmt.allocPrint(a, "  user overlay: {s}", .{app.loaded.overlay_path orelse "(HOME not set)"}));
    for (app.loaded.warnings) |w| try lines.append(a, try std.fmt.allocPrint(a, "  WARNING: {s}", .{w}));
    try lines.append(a, "");
    try lines.append(a, "Paths and display");
    try lines.append(a, try std.fmt.allocPrint(a, "  job logs: {s}", .{app.log_dir orelse "(none)"}));
    try lines.append(a, "  styling: bold and reverse video only; no color is used (NO_COLOR is respected)");
    try lines.append(a, "  public (non-loopback) server binding is only available from the CLI, with confirmation");
    try lines.append(a, "");
    try lines.append(a, "Hardware");
    try lines.append(a, try std.fmt.allocPrint(a, "  RAM: {d:.1} GB total, {d:.1} GB available", .{ hardware.gb(app.hw.mem.total), hardware.gb(app.hw.mem.available) }));
    if (app.hw.gpus.len == 0) try lines.append(a, "  GPU: none detected (checked nvidia-smi and /sys/class/drm)");
    for (app.hw.gpus) |g| {
        try lines.append(a, try std.fmt.allocPrint(a, "  GPU: {s} {s}: {d:.1} GB VRAM, {d:.1} GB free{s}", .{ @tagName(g.vendor), g.label, hardware.gb(g.vram_total), hardware.gb(g.free()), if (g.integrated) " (integrated; ignored for fit)" else "" }));
    }
    try lines.append(a, "  Fit estimates are advisory ranges; architecture, context and runtime differ.");
    var y: usize = 0;
    for (lines.items) |l| {
        const indent = l.len - std.mem.trimStart(u8, l, " ").len;
        const bold = l.len > 0 and indent == 0;
        var parts: std.ArrayList([]const u8) = .empty;
        try wrap(a, l, if (cols > indent + 4) cols - indent - 2 else cols, &parts);
        if (parts.items.len == 0) y += 1;
        for (parts.items, 0..) |part, pi| {
            if (y >= h) return;
            term.setAttr(if (bold) term.A_BOLD else 0);
            term.put(top + y, 1 + indent + (if (pi > 0) @as(usize, 2) else 0), cols, part);
            y += 1;
        }
    }
    term.setAttr(0);
}

fn drawHelp(cols: usize, top: usize, h: usize) void {
    const lines = [_][]const u8{
        "Keys",
        "  1-5, Tab, Left/Right  switch tab",
        "  Up/Down, j/k          move; PgUp/PgDn, Home/End jump",
        "  Enter                 toggle full-width detail",
        "  /                     search (Enter keeps, Esc clears)",
        "  o                     cycle sort: name, backend, size",
        "  a                     toggle abliterated-only filter",
        "  t                     cycle the good-for filter (coding, reasoning, vision, tools, ...)",
        "  f                     cycle the access filter (open / sign-in / cloud)",
        "  c                     chat with selected installed model (leaves and returns to the TUI)",
        "  s                     start API server for selected model (localhost only)",
        "  d                     download selected Discover model (network, confirmed)",
        "  n                     Discover: search Hugging Face for GGUF models (network, runs as a job)",
        "  N                     Discover: browse GGUF models, no query; each press = next sort (network)",
        "  u                     update (re-pull) selected installed model",
        "  x                     delete installed model; on Transfers/Servers: stop job",
        "  b                     abliterate: make a refusal-removed copy of a Hugging Face model (job)",
        "  r                     refresh inventory",
        "  ?                     this help",
        "  q                     quit",
        "",
        "Press any key to close.",
    };
    for (lines, 0..) |l, i| {
        if (i >= h) break;
        term.setAttr(if (i == 0) term.A_BOLD else 0);
        term.put(top + i, 1, cols - 1, l);
    }
    term.setAttr(0);
}

fn drawStatus(app: *App, rows: usize, cols: usize) void {
    if (app.prompt) |label| {
        var pb: [512]u8 = undefined;
        const t = std.fmt.bufPrint(&pb, "{s} {s}_   (Enter = continue, Esc = cancel)", .{ label, app.prompt_buf.items }) catch label;
        term.setAttr(term.A_BOLD);
        term.put(rows - 2, 0, cols, t);
        term.setAttr(0);
    } else if (app.message.len > 0) {
        term.setAttr(if (app.message_error) term.A_BOLD else 0);
        var buf: [1024]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, "{s}{s}", .{ if (app.message_error) "ERROR: " else "", app.message }) catch app.message;
        term.put(rows - 2, 0, cols, t);
        term.setAttr(0);
    }
    const hint = switch (app.tab) {
        .installed => "c chat  s serve  u update  x delete  t good-for  f access  b abliterate  ? keys  q quit",
        .discover => "d download  n search  N browse  t good-for  f access  b abliterate  ? keys  q quit",
        .transfers, .servers => "x stop  r refresh  ? help  q quit",
        .settings => "r refresh  ? help  q quit",
    };
    term.setAttr(term.A_REVERSE);
    var y: usize = 0;
    var pad: [256]u8 = undefined;
    const n = @min(cols, pad.len);
    @memset(pad[0..n], ' ');
    term.put(rows - 1, y, n, pad[0..n]);
    term.put(rows - 1, y, cols, hint);
    y += 1;
    term.setAttr(0);
}

fn drawModal(text: []const u8, rows: usize, cols: usize) void {
    var tmp: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&tmp);
    var lines: std.ArrayList([]const u8) = .empty;
    const w = @min(cols - 4, 70);
    wrap(fba.allocator(), text, w - 2, &lines) catch return;
    const h = lines.items.len + 4;
    const y0 = (rows -| h) / 2;
    const x0 = (cols -| w) / 2;
    term.setAttr(term.A_REVERSE);
    var blank: [80]u8 = undefined;
    @memset(&blank, ' ');
    var r: usize = 0;
    while (r < h) : (r += 1) term.put(y0 + r, x0, w, blank[0..@min(w, blank.len)]);
    for (lines.items, 0..) |l, i| term.put(y0 + 1 + i, x0 + 1, w - 2, l);
    term.put(y0 + h - 2, x0 + 1, w - 2, "y = yes    any other key = cancel");
    term.setAttr(0);
}

test "wrap breaks on spaces and respects width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    try wrap(arena.allocator(), "the quick brown fox jumps over the lazy dog", 15, &out);
    for (out.items) |l| try std.testing.expect(l.len <= 15);
    try std.testing.expectEqualStrings("the quick brown", out.items[0]);
}
