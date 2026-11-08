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
const progress_mod = @import("../progress.zig");
const agent_policy = @import("../agent/policy.zig");
const sources_mod = @import("../sources.zig");
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
        // Capability tags (tools / vision / thinking / coding), colored, right after the text.
        var tags: [4]model.Tag = undefined;
        const nt = model.capTags(row, &tags);
        var col: usize = std.unicode.utf8CountCodepoints(line.items) catch line.items.len;
        for (tags[0..nt]) |t| {
            if (col + t.text.len + 3 > list_w) break;
            term.setAttr(tagColor(t.color) | term.A_BOLD | (if (is_sel) term.A_REVERSE else 0));
            var tb: [24]u8 = undefined;
            const txt = std.fmt.bufPrint(&tb, " [{s}]", .{t.text}) catch break;
            term.put(top + 1 + r, col, list_w - col, txt);
            col += txt.len;
        }
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

const Line = struct {
    text: []const u8,
    /// Bytes of `text` that are the "Label:" part (drawn in the label color).
    label_len: usize = 0,
    /// Color for the value part.
    color: c_int = 0,
    bold: bool = false,
};

fn tagColor(c: model.TagColor) c_int {
    return switch (c) {
        .green => term.C_GREEN,
        .cyan => term.C_CYAN,
        .magenta => term.C_MAGENTA,
        .blue => term.C_BLUE,
        .yellow => term.C_YELLOW,
        .red => term.C_RED,
    };
}

fn addKv(al: std.mem.Allocator, ls: *std.ArrayList(Line), iw: usize, k: []const u8, v: []const u8, color: c_int) !void {
    const t = try std.fmt.allocPrint(al, "{s}: {s}", .{ k, v });
    var parts: std.ArrayList([]const u8) = .empty;
    try wrap(al, t, iw, &parts);
    for (parts.items, 0..) |p, i| try ls.append(al, .{ .text = p, .label_len = if (i == 0) @min(k.len + 1, p.len) else 0, .color = color });
}

fn addNote(al: std.mem.Allocator, ls: *std.ArrayList(Line), iw: usize, text: []const u8, color: c_int) !void {
    var parts: std.ArrayList([]const u8) = .empty;
    try wrap(al, text, iw, &parts);
    for (parts.items) |p| try ls.append(al, .{ .text = p, .color = color });
}

fn addHeading(al: std.mem.Allocator, ls: *std.ArrayList(Line), text: []const u8) !void {
    try ls.append(al, .{ .text = text, .color = term.C_CYAN, .bold = true });
}

fn gbRange(a: std.mem.Allocator, f: hardware.Fit) ![]const u8 {
    return std.fmt.allocPrint(a, "about {d:.1}-{d:.1} GB", .{ hardware.gb(f.need_low), hardware.gb(f.need_high) });
}

fn drawDetail(app: *App, a: std.mem.Allocator, row: model.Row, x: usize, w: usize, top: usize, h: usize) !void {
    var lines: std.ArrayList(Line) = .empty;
    const inner = if (w > 2) w - 2 else w;
    try addKv(a, &lines, inner, "Name", row.title(), 0);
    try addKv(a, &lines, inner, "Backend", row.model.backend.name(), 0);
    try addKv(a, &lines, inner, "Exact ID", row.model.id, 0);
    try addKv(a, &lines, inner, "Status", if (row.installed) "installed" else "not installed", if (row.installed) term.C_GREEN else term.C_YELLOW);

    // Tool use gets its own, always-present line.
    switch (model.toolSupport(row)) {
        .reported_yes => try addKv(a, &lines, inner, "Tools", "YES - can call tools (reported by ollama)", term.C_GREEN),
        .reported_no => try addKv(a, &lines, inner, "Tools", "no - ollama does not report tool support", term.C_YELLOW),
        .catalog_yes => try addKv(a, &lines, inner, "Tools", "YES - can call tools (catalog hint, derived from the registry)", term.C_GREEN),
        .catalog_no => try addKv(a, &lines, inner, "Tools", "not indicated by the catalog", term.C_YELLOW),
        .unknown => try addKv(a, &lines, inner, "Tools", "unknown (this backend does not report it and there is no catalog entry)", 0),
    }
    if (row.info) |i| if (i.hasCap("tools") and row.installed) {
        const lvl = agent_policy.defaultLevel(true, i.paramsB());
        try addKv(a, &lines, inner, "Agent mode", try std.fmt.allocPrint(a, "available - default level '{s}' for this size (press g; tune with: aimgr agent set)", .{lvl.text()}), term.C_GREEN);
    };
    if (row.info) |i| {
        if (i.caps.len > 0) try addKv(a, &lines, inner, "Capabilities (ollama)", try std.mem.join(a, ", ", i.caps), term.C_GREEN);
        if (i.architecture) |v| try addKv(a, &lines, inner, "Architecture", v, 0);
        if (i.parameters) |v| try addKv(a, &lines, inner, "Parameters", v, 0);
        if (i.context_length) |v| try addKv(a, &lines, inner, "Context length", try std.fmt.allocPrint(a, "{d} tokens", .{v}), 0);
        if (i.quantization) |v| try addKv(a, &lines, inner, "Quantization", v, 0);
    } else if (row.model.quant) |q| try addKv(a, &lines, inner, "Quantization", q, 0);
    if (row.model.size_text) |sz| try addKv(a, &lines, inner, "Size", sz, 0);
    if (row.model.modified) |m| try addKv(a, &lines, inner, "Modified", m, 0);
    if (row.model.digest) |d| try addKv(a, &lines, inner, "Digest", d, 0);
    if (row.entry) |e| {
        if (e.description) |d| try addKv(a, &lines, inner, "About", d, 0);
        if (e.use_cases.len > 0) try addKv(a, &lines, inner, "Good for (derived hints, not benchmarks)", try std.mem.join(a, ", ", e.use_cases), term.C_GREEN);
        if (e.tags.len > 0) try addKv(a, &lines, inner, "Tags", try std.mem.join(a, ", ", e.tags), term.C_YELLOW);
        if (e.notes) |n| try addKv(a, &lines, inner, "Notes", n, 0);
        try addKv(a, &lines, inner, "Catalog", if (e.origin.len > 0) e.origin else @tagName(e.source), 0);
    } else try addKv(a, &lines, inner, "Catalog", "no entry (metadata unknown)", 0);
    if (row.access) |ac| {
        const col: c_int = switch (ac) {
            .open => term.C_GREEN,
            .signin => term.C_YELLOW,
            .cloud => term.C_RED,
        };
        try addKv(a, &lines, inner, "Access", try std.fmt.allocPrint(a, "{s} - {s}", .{ ac.label(), ac.explain() }), col);
    } else if (!row.installed) try addKv(a, &lines, inner, "Access", "unknown (not stated in the catalog)", 0);
    if (row.abliterated) try addNote(a, &lines, inner, catalog.abliterated_note, term.C_RED);

    // What it takes to run it decently (advisory ranges).
    {
        const bytes = backend_mod.parseSizeText(row.model.size_text) orelse (if (row.entry) |e| e.size_bytes else null);
        const params = (if (row.info) |i| i.paramsB() else null) orelse (if (row.entry) |e| e.params_b else null);
        const quant = (if (row.info) |i| i.quantization else null) orelse row.model.quant;
        const f4 = hardware.estimateWith(row.model.id, quant, bytes, params, 4096, app.hw);
        try addHeading(a, &lines, "To run it decently (advisory estimate)");
        if (f4.verdict == .unknown) {
            try addNote(a, &lines, inner, "Cannot estimate: neither a size nor a parameter count + quantization is known for this model.", 0);
        } else {
            const f32k = hardware.estimateWith(row.model.id, quant, bytes, params, 32768, app.hw);
            try addKv(a, &lines, inner, "  GPU memory (full speed)", try std.fmt.allocPrint(a, "{s} VRAM at 4096 context", .{try gbRange(a, f4)}), 0);
            try addKv(a, &lines, inner, "  CPU only (slower)", try std.fmt.allocPrint(a, "{s} free RAM, and expect noticeably lower speed than a GPU", .{try gbRange(a, f4)}), 0);
            try addKv(a, &lines, inner, "  At 32k context", try std.fmt.allocPrint(a, "{s} (the cache grows with context)", .{try gbRange(a, f32k)}), 0);
            try addKv(a, &lines, inner, "  Weights", try std.fmt.allocPrint(a, "{d:.1} GB, {s}", .{ hardware.gb(f4.weights), if (f4.weights_estimated) "estimated from the parameter count and quantization" else "as reported" }), 0);
            const vcol: c_int = switch (f4.verdict) {
                .fits_gpu, .cpu_ok => term.C_GREEN,
                .maybe_fits_gpu, .needs_offload => term.C_YELLOW,
                .unlikely => term.C_RED,
                .unknown => 0,
            };
            try addKv(a, &lines, inner, "On this machine", f4.verdict.text(), vcol);
        }
    }
    if (row.installed) {
        var all: std.ArrayList(backend_mod.Model) = .empty;
        for (app.report.reports) |r| try all.appendSlice(a, r.models orelse &.{});
        for (try manage.duplicates(a, all.items, row.model.backend, row.model.id)) |d| {
            try addKv(a, &lines, inner, if (d.exact_id) "Same id in" else "Similar", try std.fmt.allocPrint(a, "{s} {s}", .{ d.model.backend.name(), d.model.id }), 0);
        }
        if (manage.unsupportedReason(row.model.backend, .remove)) |why| try addKv(a, &lines, inner, "Delete disabled", why, 0);
    }
    for (lines.items, 0..) |l, i| {
        if (i >= h) break;
        const lab = @min(l.label_len, l.text.len);
        if (lab > 0) {
            term.setAttr(term.A_BOLD | term.C_CYAN);
            term.put(top + i, x + 1, inner, l.text[0..lab]);
            term.setAttr(l.color | (if (l.bold) term.A_BOLD else 0));
            const off = std.unicode.utf8CountCodepoints(l.text[0..lab]) catch lab;
            if (inner > off) term.put(top + i, x + 1 + off, inner - off, l.text[lab..]);
        } else {
            term.setAttr(l.color | (if (l.bold) term.A_BOLD else 0));
            term.put(top + i, x + 1, inner, l.text);
        }
    }
    term.setAttr(0);
}

/// "[=====>      ]  45%" (ASCII bar + percent; the percent is always printed, so no glyph or
/// color is needed to read it). Indeterminate jobs get a sliding block.
fn jobBar(a: std.mem.Allocator, j: jobs.Job, width: usize, tick: u64) ![]const u8 {
    var buf: [96]u8 = undefined;
    if (j.progress) |pr| {
        if (pr.fraction()) |f| {
            const b = progress_mod.bar(&buf, width, f);
            return std.fmt.allocPrint(a, "{s} {d:>3}%", .{ b, pr.percent().? });
        }
    }
    if (j.state == .done) return std.fmt.allocPrint(a, "{s} 100%", .{progress_mod.bar(&buf, width, 1.0)});
    if (j.isActive()) return std.fmt.allocPrint(a, "{s}  ...", .{progress_mod.spinnerBar(&buf, width, tick)});
    return "";
}

fn fmtBytes(a: std.mem.Allocator, n: u64) ![]const u8 {
    const f: f64 = @floatFromInt(n);
    if (n >= 1_000_000_000) return std.fmt.allocPrint(a, "{d:.2} GB", .{f / 1e9});
    if (n >= 1_000_000) return std.fmt.allocPrint(a, "{d:.1} MB", .{f / 1e6});
    return std.fmt.allocPrint(a, "{d} KB", .{n / 1000});
}

fn drawJobs(app: *App, a: std.mem.Allocator, cols: usize, top: usize, h: usize) !void {
    const vis = try app.visibleJobs(a);
    const sel = clampSel(app, vis.len);
    term.setAttr(term.A_BOLD | term.C_CYAN);
    term.put(top, 0, cols, if (app.tab == .servers) "Servers (started by aimgr)" else "Transfers (pull / update / remove / abliterate)");
    term.setAttr(0);
    if (vis.len == 0) {
        term.put(top + 2, 2, cols, if (app.tab == .servers) "No servers. Select a model on Installed and press s." else "No transfers. Press d on Discover or u / x on Installed.");
        return;
    }
    const bar_w: usize = if (cols >= 100) 24 else if (cols >= 80) 14 else 10;
    var r: usize = 0;
    while (r < vis.len and r < h / 2) : (r += 1) {
        const j = app.jobs.list.items[vis[r]];
        const status = if (j.kind == .server and j.state == .running) (if (j.listening) "LISTENING" else "STARTING") else stateWord(j.state);
        const has_bar = j.kind != .server and j.kind != .remove and j.kind != .search;
        const bar_txt = if (has_bar) try jobBar(a, j, bar_w, app.jobs.tick / 2) else "";
        // The model name gives way so the bar always fits at the right edge.
        const name_full = if (j.model.len > 0) j.model else if (j.kind == .server) "(daemon)" else "(environment)";
        const prefix = try std.fmt.allocPrint(a, "{s}#{d} {s:<10} {s:<10} {s:<6} ", .{ if (r == sel) "> " else "  ", j.id, status, @tagName(j.kind), j.backend.name() });
        const reserve: usize = if (bar_txt.len > 0) bar_txt.len + 2 else 0;
        const avail = cols -| (prefix.len + reserve);
        const name_shown = if (name_full.len <= avail) name_full else if (avail > 4) try std.fmt.allocPrint(a, "{s}...", .{name_full[0 .. avail - 3]}) else "";
        var line: std.ArrayList(u8) = .empty;
        try line.print(a, "{s}{s}", .{ prefix, name_shown });
        if (j.port) |p| try line.print(a, " :{d}", .{p});
        const sel_attr: c_int = if (r == sel) term.A_REVERSE else 0;
        const state_color: c_int = switch (j.state) {
            .running, .stopping => term.C_YELLOW,
            .done => term.C_GREEN,
            .failed => term.C_RED,
            .cancelled => term.C_MAGENTA,
        };
        term.setAttr(sel_attr);
        term.put(top + 1 + r, 0, cols, line.items);
        // Re-draw the status word in its color on top of the plain text.
        term.setAttr(sel_attr | state_color | term.A_BOLD);
        const sp = std.mem.indexOf(u8, line.items, status) orelse 0;
        term.put(top + 1 + r, sp, status.len, status);
        if (bar_txt.len > 0) {
            term.setAttr(sel_attr | (if (j.state == .done) term.C_GREEN else term.C_CYAN));
            term.put(top + 1 + r, cols -| (bar_txt.len + 1), bar_txt.len, bar_txt);
        }
    }
    term.setAttr(0);
    const j = app.jobs.list.items[vis[sel]];
    var y = top + 2 + @min(vis.len, h / 2);

    // Detail: big bar + numbers for the selected job.
    if (j.kind != .server and j.kind != .remove and j.kind != .search) {
        const wide_bar = @min(cols -| 24, 50);
        const bt = try jobBar(a, j, @max(wide_bar, 10), app.jobs.tick / 2);
        if (bt.len > 0 and y < top + h) {
            term.setAttr(term.A_BOLD | term.C_CYAN);
            term.put(y, 2, 10, "Progress: ");
            term.setAttr(if (j.state == .done) term.C_GREEN else term.C_YELLOW);
            term.put(y, 12, cols -| 12, bt);
            term.setAttr(0);
            y += 1;
        }
        if (j.progress) |pr| if (pr.total > 0 and y < top + h) {
            const txt = switch (pr.unit) {
                .bytes => try std.fmt.allocPrint(a, "{s} of {s}", .{ try fmtBytes(a, @min(pr.done, pr.total)), try fmtBytes(a, pr.total) }),
                .steps => "stage-based estimate (see the latest output below)",
            };
            term.put(y, 12, cols -| 12, txt);
            y += 1;
        } else if (pr.unit == .bytes and y < top + h) {
            term.put(y, 12, cols -| 12, try std.fmt.allocPrint(a, "{s} downloaded (total size unknown)", .{try fmtBytes(a, pr.done)}));
            y += 1;
        };
    }

    var cmd: std.ArrayList(u8) = .empty;
    for (j.argv) |arg| try cmd.print(a, "{s} ", .{arg});
    const Item = struct { label: []const u8, value: []const u8 };
    const info = [_]Item{
        .{ .label = "Command: ", .value = cmd.items },
        .{ .label = "Log: ", .value = j.log_path },
        .{ .label = "Latest output: ", .value = if (j.last_line.len > 0) j.last_line else "(none yet)" },
        .{ .label = "Exit code: ", .value = if (j.exit_code) |c| try std.fmt.allocPrint(a, "{d}", .{c}) else "(running)" },
    };
    for (info) |it| {
        if (y >= top + h) break;
        term.setAttr(term.A_BOLD | term.C_CYAN);
        term.put(y, 2, it.label.len, it.label);
        term.setAttr(0);
        term.put(y, 2 + it.label.len, cols -| (2 + it.label.len), it.value);
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

fn padRight(a: std.mem.Allocator, text: []const u8, width: usize) ![]const u8 {
    if (text.len >= width) return text;
    const out = try a.alloc(u8, width);
    @memcpy(out[0..text.len], text);
    @memset(out[text.len..], ' ');
    return out;
}

/// Sources and agent levels, selectable. Returns the next free row (relative to `top`).
fn drawSettingsLists(app: *App, a: std.mem.Allocator, cols: usize, top: usize, h: usize) !usize {
    const items = try app.settingsItems(a);
    const sel = clampSel(app, items.len);
    var y: usize = 0;
    var printed_agent_head = false;
    term.setAttr(term.A_BOLD | term.C_CYAN);
    term.put(top, 1, cols, "Model sources   (Enter/space = enable or disable, u = download a catalog URL)");
    y += 1;
    for (items, 0..) |it, i| {
        if (y + 2 >= h) break;
        const picked = i == sel;
        switch (it) {
            .source => |si| {
                const src = app.loaded.sources[si];
                const state: []const u8 = switch (src.kind) {
                    .bundled => "built in snapshot",
                    .overlay => "your models.toml",
                    .catalog_file => "local file",
                    .catalog_url => "downloaded on request",
                    .huggingface => "online: search / browse",
                };
                const line = try std.fmt.allocPrint(a, "{s}[{s}] {s:<14} {s:<13} {s}{s}{s}", .{ if (picked) "> " else "  ", if (src.enabled) "x" else " ", src.id, src.kind.text(), state, if (src.location != null) "  " else "", src.location orelse "" });
                term.setAttr(if (picked) term.A_REVERSE else 0);
                term.put(top + y, 1, cols, line);
                term.setAttr((if (src.enabled) term.C_GREEN else term.C_YELLOW) | term.A_BOLD | (if (picked) term.A_REVERSE else 0));
                term.put(top + y, 3, 3, if (src.enabled) "[x]" else "[ ]");
                y += 1;
            },
            .agent => |ag| {
                if (!printed_agent_head) {
                    y += 1;
                    term.setAttr(term.A_BOLD | term.C_CYAN);
                    term.put(top + y, 1, cols, "Agent mode: autonomy per tool-capable model   (Enter/space = next level; g on Installed starts it)");
                    y += 1;
                    printed_agent_head = true;
                }
                if (y + 1 >= h) break;
                const params = if (ag.params_b) |p| try std.fmt.allocPrint(a, "{d:.1}B", .{p}) else "?";
                const id_w: usize = 34;
                const id_shown = if (ag.id.len <= id_w) ag.id else try std.fmt.allocPrint(a, "{s}...", .{ag.id[0 .. id_w - 3]});
                const prefix = try std.fmt.allocPrint(a, "{s}{s}", .{ if (picked) "> " else "  ", try padRight(a, id_shown, id_w) });
                const line = try std.fmt.allocPrint(a, "{s} level {s:<9} {s}  {s}", .{
                    prefix,
                    ag.level.text(),
                    if (ag.custom) "(yours)" else try std.fmt.allocPrint(a, "(default for {s})", .{params}),
                    if (ag.stored_dirs) |d| (if (d.len > 0) try std.fmt.allocPrint(a, "dirs: {s}", .{d[0]}) else "") else "dir asked at start",
                });
                term.setAttr(if (picked) term.A_REVERSE else 0);
                term.put(top + y, 1, cols, line);
                const lc: c_int = switch (ag.level) {
                    .off => 0,
                    .read_only, .inspect => term.C_GREEN,
                    .ask => term.C_YELLOW,
                };
                term.setAttr(lc | term.A_BOLD | (if (picked) term.A_REVERSE else 0));
                term.put(top + y, 1 + prefix.len + " level ".len, 9, ag.level.text());
                y += 1;
            },
        }
    }
    term.setAttr(0);
    return y + 1;
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
    // Interactive lists first: model sources, then per-model agent levels.
    var y: usize = try drawSettingsLists(app, a, cols, top, h);
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
        "  g                     agent: let a tool-capable model look at a directory (asks before anything but reads)",
        "  s                     start API server for selected model (localhost only)",
        "  d                     download selected Discover model (network, confirmed)",
        "  n                     Discover: search Hugging Face for GGUF models (network, runs as a job)",
        "  N                     Discover: browse GGUF models, no query; each press = next sort (network)",
        "  u                     update (re-pull) selected installed model",
        "  x                     delete installed model; on Transfers/Servers: stop job",
        "  b                     abliterate: make a refusal-removed copy of a Hugging Face model (job)",
        "  r                     refresh inventory",
        "  Ctrl-L                repaint the whole screen (if the terminal shows stray characters)",
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
        .installed => "c chat  g agent  s serve  u update  x delete  t good-for  b abliterate  ? keys  q quit",
        .discover => "d download  n search  N browse  t good-for  f access  b abliterate  ? keys  q quit",
        .transfers, .servers => "x stop  r refresh  ? help  q quit",
        .settings => "Enter/space toggle or change level  u download URL source  r refresh  ? keys  q quit",
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
