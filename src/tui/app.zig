//! TUI event loop and actions. Every state-changing action goes through a
//! confirmation modal and the same argv builders as the CLI.
const std = @import("std");
const term = @import("term.zig");
const model = @import("model.zig");
const jobs_mod = @import("jobs.zig");
const draw_mod = @import("draw.zig");
const State = @import("state.zig");
const backend = @import("../backend.zig");
const inventory = @import("../inventory.zig");
const catalog_io = @import("../catalog_io.zig");
const catalog = @import("../catalog.zig");
const config = @import("../config.zig");
const launcher = @import("../launcher.zig");
const manage = @import("../manage.zig");
const netstat = @import("../netstat.zig");
const supervise = @import("../supervise.zig");
const sources_io = @import("../sources_io.zig");
const agent_settings = @import("../agent/settings.zig");
const abl = @import("../abliterate.zig");
const hardware = @import("../hardware.zig");
const agent_policy = @import("../agent/policy.zig");
const modelinfo = @import("../modelinfo.zig");

const App = State.App;

// Signal handlers cannot take context: one atomic flag (documented exception).
var signalled = std.atomic.Value(bool).init(false);

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    signalled.store(true, .monotonic);
}

fn installSignals() void {
    const act: std.posix.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
    std.posix.sigaction(.HUP, &act, null);
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, environ: *std.process.Environ.Map) !u8 {
    const no_color = environ.get("NO_COLOR") != null;
    var app: App = .{
        .gpa = gpa,
        .io = io,
        .environ = environ,
        .data = std.heap.ArenaAllocator.init(gpa),
        .frame = std.heap.ArenaAllocator.init(gpa),
        .online_arena = std.heap.ArenaAllocator.init(gpa),
        .jobs = .{ .gpa = gpa, .io = io },
        .log_dir = try config.statePath(gpa, environ, "logs"),
        .use_color = !no_color,
    };
    defer {
        app.data.deinit();
        app.frame.deinit();
        app.online_arena.deinit();
        app.filter.deinit(gpa);
        app.prompt_buf.deinit(gpa);
        app.jobs.deinit();
        gpa.free(app.message);
        if (app.log_dir) |d| gpa.free(d);
    }
    refresh(&app);

    try term.init(gpa, io, environ);
    defer term.deinit(); // restores the terminal on every exit path
    installSignals();

    while (!app.quit) {
        if (signalled.load(.monotonic)) {
            _ = stopAll(&app);
            break;
        }
        draw_mod.draw(&app);
        const key = term.getKey();
        if (app.jobs.poll()) {
            consumeSearches(&app);
            refresh(&app);
            noteFinished(&app);
        }
        if (key == .none) continue;
        handleKey(&app, key);
    }
    term.deinit();
    reportLeftovers(&app, io);
    return 0;
}

fn noteFinished(app: *App) void {
    for (app.jobs.list.items) |j| {
        if (j.isActive()) continue;
        if (j.state == .failed and j.exit_code != null and app.message.len == 0) {
            app.setMessage(true, "job #{d} ({s} {s}) failed with exit code {d}; see Transfers tab / log {s}", .{ j.id, @tagName(j.kind), j.model, j.exit_code.?, j.log_path });
        }
    }
}

/// Rebuild inventory, catalog and rows. Existing selections are clamped by draw.
pub fn refresh(app: *App) void {
    app.data.deinit();
    app.data = std.heap.ArenaAllocator.init(app.gpa);
    const a = app.data.allocator();
    app.report = inventory.discover(a, app.gpa, app.io);
    app.loaded = catalog_io.loadAll(a, app.gpa, app.io, app.environ) catch .{};
    app.hw = hardware.detect(a, app.gpa, app.io) catch .{ .mem = .{}, .gpus = &.{} };
    app.infos = .empty;
    var asked: usize = 0;
    for (app.report.reports) |r| {
        if (r.kind != .ollama) continue;
        for (r.models orelse &.{}) |m| {
            if (asked >= 80) break;
            asked += 1;
            if (modelinfo.fetchOllama(a, app.gpa, app.io, m.id)) |info| app.infos.put(a, m.id, info) catch {};
        }
    }
    rebuildRows(app);
    if (app.loaded.warnings.len > 0 and app.message.len == 0) app.setMessage(true, "{s}", .{app.loaded.warnings[0]});
    for (app.report.reports) |r| {
        if (r.list_error) |e| app.setMessage(true, "{s}: list failed: {s}", .{ r.kind.name(), inventory.listErrorText(e) });
        if (r.probe != .available) app.setMessage(true, "{s} is unavailable (see Settings)", .{r.kind.name()});
    }
}

fn rebuildRows(app: *App) void {
    app.rows = model.buildRowsEx(app.data.allocator(), app.tab, app.report, &app.loaded.cat, app.filter.items, app.sort, app.only_abliterated, app.online, .{
        .use = if (app.use_idx > 0) model.use_tags[app.use_idx - 1] else null,
        .access = app.access_filter,
        .infos = &app.infos,
    }) catch &.{};
}

fn stopAll(app: *App) bool {
    var any = false;
    for (app.jobs.list.items) |*j| if (j.state == .running) {
        _ = app.jobs.stop(j);
        any = true;
    };
    // Give jobs up to ~5 s to exit gracefully; never SIGKILL without approval.
    var waited: usize = 0;
    while (app.jobs.activeCount() > 0 and waited < 50) : (waited += 1) {
        _ = app.jobs.poll();
        app.io.sleep(.fromMilliseconds(100), .awake) catch {};
    }
    return any;
}

fn reportLeftovers(app: *App, io: std.Io) void {
    _ = io;
    for (app.jobs.list.items) |j| if (j.isActive()) {
        std.debug.print("aimgr: job #{d} ({s} {s}) is still running as pid {d}\n", .{ j.id, @tagName(j.kind), j.model, j.pid });
    };
}

fn moveSel(app: *App, delta: isize, len: usize) void {
    const i = &app.sel[@backingInt(app.tab)];
    if (len == 0) return;
    const cur: isize = @intCast(i.*);
    const nxt = std.math.clamp(cur + delta, 0, @as(isize, @intCast(len)) - 1);
    i.* = @intCast(nxt);
}

fn listLen(app: *App) usize {
    return switch (app.tab) {
        .installed, .discover => app.rows.len,
        .transfers, .servers => blk: {
            const v = app.visibleJobs(app.frame.allocator()) catch break :blk 0;
            break :blk v.len;
        },
        .settings => 0,
    };
}

fn setTab(app: *App, t: model.Tab) void {
    app.tab = t;
    app.detail_full = false;
    rebuildRows(app);
}

fn handleKey(app: *App, key: term.Key) void {
    if (app.modal) |m| {
        defer if (app.modal != null) clearModal(app);
        if (key == .char and (key.char == 'y' or key.char == 'Y')) {
            const act = m.action;
            app.modal = null; // action takes ownership of its strings via copies below
            execute(app, act);
            freeAction(app, act);
            app.gpa.free(m.text);
        }
        return;
    }
    if (app.show_help) {
        app.show_help = false;
        return;
    }
    if (app.prompt != null) return promptKey(app, key);
    if (app.searching) return searchKey(app, key);

    switch (key) {
        .resize, .none => {},
        .ctrl_c => requestQuit(app),
        .redraw => term.redraw(),
        .esc => {
            app.setMessage(false, "", .{});
            app.detail_full = false;
        },
        .up => moveSel(app, -1, listLen(app)),
        .down => moveSel(app, 1, listLen(app)),
        .page_up => moveSel(app, -10, listLen(app)),
        .page_down => moveSel(app, 10, listLen(app)),
        .home => moveSel(app, -1_000_000, listLen(app)),
        .end => moveSel(app, 1_000_000, listLen(app)),
        .left => setTab(app, prevTab(app.tab)),
        .right, .tab => setTab(app, nextTab(app.tab)),
        .enter => app.detail_full = !app.detail_full,
        .backspace => {},
        .char => |ch| charKey(app, ch),
    }
}

fn nextTab(t: model.Tab) model.Tab {
    const n = @backingInt(t) + 1;
    return @fromBackingInt(@intCast(if (n >= 5) 0 else n));
}

fn prevTab(t: model.Tab) model.Tab {
    const v = @backingInt(t);
    return @fromBackingInt(@intCast(if (v == 0) 4 else v - 1));
}

fn clearModal(app: *App) void {
    if (app.modal) |m| {
        freeAction(app, m.action);
        app.gpa.free(m.text);
        app.modal = null;
    }
}

fn freeAction(app: *App, act: State.Action) void {
    switch (act) {
        .pull, .update, .remove => |t| app.gpa.free(t.id),
        .abliterate => |repo| app.gpa.free(repo),
        else => {},
    }
}

fn searchKey(app: *App, key: term.Key) void {
    switch (key) {
        .enter => app.searching = false,
        .esc => {
            app.searching = false;
            app.filter.clearRetainingCapacity();
            rebuildRows(app);
        },
        .backspace => {
            if (app.filter.items.len > 0) {
                // drop one UTF-8 codepoint
                var n = app.filter.items.len - 1;
                while (n > 0 and (app.filter.items[n] & 0xC0) == 0x80) n -= 1;
                app.filter.shrinkRetainingCapacity(n);
            }
            rebuildRows(app);
        },
        .char => |ch| {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(ch, &buf) catch return;
            if (app.filter.items.len < 200) app.filter.appendSlice(app.gpa, buf[0..n]) catch {};
            app.sel[@backingInt(app.tab)] = 0;
            rebuildRows(app);
        },
        else => {},
    }
}

fn charKey(app: *App, ch: u21) void {
    switch (ch) {
        'q' => requestQuit(app),
        '?' => app.show_help = true,
        'r' => {
            app.setMessage(false, "", .{});
            refresh(app);
        },
        '1'...'5' => setTab(app, @fromBackingInt(@intCast(ch - '1'))),
        'j' => moveSel(app, 1, listLen(app)),
        'k' => moveSel(app, -1, listLen(app)),
        '/' => if (app.tab == .installed or app.tab == .discover) {
            app.searching = true;
        },
        'o' => {
            app.sort = app.sort.next();
            rebuildRows(app);
        },
        'a' => {
            app.only_abliterated = !app.only_abliterated;
            app.sel[@backingInt(app.tab)] = 0;
            rebuildRows(app);
        },
        'b' => if (app.tab == .installed or app.tab == .discover) beginAbliterate(app),
        'n' => if (app.tab == .discover) beginSearch(app),
        'N' => if (app.tab == .discover) browseOnline(app),
        't' => if (app.tab == .installed or app.tab == .discover) {
            app.use_idx = (app.use_idx + 1) % (model.use_tags.len + 1);
            app.sel[@backingInt(app.tab)] = 0;
            rebuildRows(app);
        },
        'f' => if (app.tab == .installed or app.tab == .discover) {
            app.access_filter = switch (app.access_filter orelse .cloud) {
                .cloud => if (app.access_filter == null) .open else null,
                .open => .signin,
                .signin => .cloud,
            };
            app.sel[@backingInt(app.tab)] = 0;
            rebuildRows(app);
        },
        'g' => if (app.tab == .installed) beginAgent(app),
        'c' => chat(app),
        's' => startServer(app),
        'd' => askRowAction(app, .pull),
        'u' => askRowAction(app, .update),
        'x' => if (app.tab == .installed) askRowAction(app, .remove) else stopJob(app),
        else => {},
    }
}

fn requestQuit(app: *App) void {
    if (app.jobs.activeCount() == 0) {
        app.quit = true;
        return;
    }
    openModal(app, std.fmt.allocPrint(app.gpa, "{d} job(s) are still running. Quit and ask them to stop (SIGTERM)?", .{app.jobs.activeCount()}) catch return, .quit);
}

fn openModal(app: *App, text: []const u8, action: State.Action) void {
    app.modal = .{ .text = text, .action = action };
}

fn askRowAction(app: *App, kind: manage.Action) void {
    const row = app.currentRow() orelse return app.setMessage(true, "no model selected", .{});
    const be = row.model.backend;
    if (manage.unsupportedReason(be, kind)) |why| return app.setMessage(true, "{s} is disabled for {s}: {s}", .{ @tagName(kind), be.name(), why });
    if (kind == .pull and row.installed) return app.setMessage(true, "already installed; press u to update", .{});
    if (kind != .pull and !row.installed) return app.setMessage(true, "not installed; press d on this Discover entry to download", .{});
    var avail = true;
    for (app.report.reports) |r| if (r.kind == be and r.probe != .available) {
        avail = false;
    };
    if (!avail) return app.setMessage(true, "{s} is unavailable", .{be.name()});
    const argv = manage.plan(app.frame.allocator(), be, kind, row.model.id) catch |e| return app.setMessage(true, "{s}", .{manage.errorText(e)});

    var text: std.ArrayList(u8) = .empty;
    const fa = app.frame.allocator();
    text.print(fa, "{s} on backend {s}, exact id \"{s}\". ", .{ @tagName(kind), be.name(), row.model.id }) catch return;
    switch (kind) {
        .pull => {
            text.appendSlice(fa, "Uses the network and downloads model files. ") catch return;
            accessNote(app, &text, fa, row);
        },
        .update => {
            text.print(fa, "Uses the network. {s} ", .{manage.mutable_tag_warning}) catch return;
            accessNote(app, &text, fa, row);
        },
        .remove => {
            var all: std.ArrayList(backend.Model) = .empty;
            for (app.report.reports) |r| all.appendSlice(fa, r.models orelse &.{}) catch return;
            for (manage.duplicates(fa, all.items, be, row.model.id) catch &.{}) |d| {
                text.print(fa, "Note: {s} {s} {s}. ", .{ if (d.exact_id) "same id also in" else "similar model:", d.model.backend.name(), d.model.id }) catch return;
            }
            text.appendSlice(fa, "PERMANENTLY deletes this model from this backend.") catch return;
        },
    }
    _ = argv;
    const owned_text = app.gpa.dupe(u8, text.items) catch return;
    const id = app.gpa.dupe(u8, row.model.id) catch return;
    const t: State.Target = .{ .backend = be, .id = id };
    openModal(app, owned_text, switch (kind) {
        .pull => .{ .pull = t },
        .update => .{ .update = t },
        .remove => .{ .remove = t },
    });
}

fn execute(app: *App, act: State.Action) void {
    switch (act) {
        .quit => {
            _ = stopAll(app);
            app.quit = true;
        },
        .kill_job => |id| for (app.jobs.list.items) |*j| if (j.id == id and j.isActive()) {
            app.jobs.kill(j);
            app.setMessage(false, "sent SIGKILL to job #{d}", .{id});
        },
        .abliterate => |repo| startSelf(app, .abliterate, .ollama, &.{ "abliterate", "run", repo, "--yes" }, abl.deriveName(app.frame.allocator(), repo) catch repo),
        .abliterate_setup => startSelf(app, .setup, .ollama, &.{ "abliterate", "setup", "--yes" }, ""),
        .pull => |t| startManage(app, .pull, t),
        .update => |t| startManage(app, .update, t),
        .remove => |t| startManage(app, .remove, t),
    }
}

fn startManage(app: *App, kind: manage.Action, t: State.Target) void {
    // llama prints no progress when not on a terminal: run the download through `aimgr pull`,
    // which measures it (see dlwatch.zig) and prints progress lines the Transfers tab turns into a bar.
    if (t.backend == .llama and kind != .remove) {
        const jk: jobs_mod.Kind = if (kind == .pull) .pull else .update;
        return startSelf(app, jk, .llama, &.{ @tagName(kind), "llama", t.id, "--yes" }, t.id);
    }
    const argv = manage.plan(app.frame.allocator(), t.backend, kind, t.id) catch |e| return app.setMessage(true, "{s}", .{manage.errorText(e)});
    const jk: jobs_mod.Kind = switch (kind) {
        .pull => .pull,
        .update => .update,
        .remove => .remove,
    };
    const err = app.jobs.start(jk, t.backend, t.id, argv, app.environ, app.log_dir, null) catch return app.setMessage(true, "could not start job (out of memory)", .{});
    if (err.len > 0) return app.setMessage(true, "{s}: {s}", .{ argv[0], err });
    selectNewest(app, jk);
    app.setMessage(false, "started {s} {s} {s}; see Transfers (key 3)", .{ @tagName(kind), t.backend.name(), t.id });
}

fn startServer(app: *App) void {
    const row = app.currentRow() orelse return app.setMessage(true, "no model selected", .{});
    if (!row.installed) return app.setMessage(true, "only installed models can be served; nothing is downloaded implicitly", .{});
    if (row.access == .cloud) return app.setMessage(true, "this is a cloud model: it runs remotely and needs sign-in + API usage, so aimgr (offline-first) will not serve it", .{});
    const be = row.model.backend;
    const fa = app.frame.allocator();
    if (be == .ollama) {
        if (netstat.isListening(app.gpa, app.io, launcher.default_ollama_port)) {
            return app.setMessage(false, "ollama daemon already listening on 127.0.0.1:{d}; using it (model loads on first request)", .{launcher.default_ollama_port});
        }
        const pl = launcher.plan(fa, .ollama, .server, null, .{}) catch |e| return app.setMessage(true, "{s}", .{launcher.errorText(e)});
        var env = app.environ.clone(app.gpa) catch return;
        defer env.deinit();
        for (pl.env) |kv| env.put(kv[0], kv[1]) catch return;
        const err = app.jobs.start(.server, .ollama, "", pl.argv, &env, app.log_dir, pl.listen_port) catch return;
        if (err.len > 0) return app.setMessage(true, "ollama: {s}", .{err});
        return app.setMessage(false, "starting ollama daemon on 127.0.0.1:{d}", .{pl.listen_port.?});
    }
    // llama: first free port from the default upward; localhost only.
    var port: u16 = launcher.default_llama_port;
    while (netstat.isListening(app.gpa, app.io, port) and port < launcher.default_llama_port + 50) port += 1;
    const pl = launcher.plan(fa, .llama, .server, row.model.id, .{ .port = port }) catch |e| return app.setMessage(true, "{s}", .{launcher.errorText(e)});
    const err = app.jobs.start(.server, .llama, row.model.id, pl.argv, app.environ, app.log_dir, port) catch return;
    if (err.len > 0) return app.setMessage(true, "llama: {s}", .{err});
    app.setMessage(false, "starting llama server on 127.0.0.1:{d}; see Servers (key 4)", .{port});
}

fn stopJob(app: *App) void {
    const j = app.currentJob() orelse return;
    if (!j.isActive()) return app.setMessage(false, "job #{d} already finished", .{j.id});
    if (app.jobs.stop(j)) {
        const text = std.fmt.allocPrint(app.gpa, "Job #{d} has not exited after SIGTERM. Send SIGKILL (may leave partial files)?", .{j.id}) catch return;
        openModal(app, text, .{ .kill_job = j.id });
    } else app.setMessage(false, "sent SIGTERM to job #{d}; press x again if it does not exit", .{j.id});
}

/// Leave curses, run the chat on the real terminal, then come back intact.
fn chat(app: *App) void {
    const row = app.currentRow() orelse return app.setMessage(true, "no model selected", .{});
    if (!row.installed) return app.setMessage(true, "only installed models can be chatted with", .{});
    if (row.access == .cloud) return app.setMessage(true, "this is a cloud model: it runs remotely and needs sign-in + API usage, so aimgr (offline-first) will not launch it; use ollama directly if you want that", .{});
    const be = row.model.backend;
    const pl = launcher.plan(app.frame.allocator(), be, .chat, row.model.id, .{}) catch |e| return app.setMessage(true, "{s}", .{launcher.errorText(e)});
    term.suspendTerm();
    var ob: [1024]u8 = undefined;
    var eb: [1024]u8 = undefined;
    var ow: std.Io.File.Writer = .initStreaming(.stdout(), app.io, &ob);
    var ew: std.Io.File.Writer = .initStreaming(.stderr(), app.io, &eb);
    const env: supervise.Env = .{ .gpa = app.gpa, .io = app.io, .environ = app.environ, .out = &ow.interface, .err = &ew.interface, .log_dir = null };
    const code = supervise.runChat(env, pl) catch 1;
    ow.interface.flush() catch {};
    ew.interface.flush() catch {};
    term.resumeTerm();
    installSignals(); // runChat reset the handlers to default
    if (code == 0) app.setMessage(false, "chat ended", .{}) else app.setMessage(true, "chat exited with code {d}", .{code});
}

// ---- abliteration -------------------------------------------------------

/// Preconditions are checked here so problems show up before a job starts.
fn beginAbliterate(app: *App) void {
    const fa = app.frame.allocator();
    const data = (config.dataDir(fa, app.environ) catch null) orelse return app.setMessage(true, "no data directory (HOME / XDG_DATA_HOME not set)", .{});
    const res = (config.resourceDir(fa, app.io, app.environ) catch null) orelse return app.setMessage(true, "bundled resources not found (run 'zig build' to install them, or set AIMGR_RESOURCES)", .{});
    const pa = abl.paths(fa, data, res, "x", "Q4_K_M") catch return;
    std.Io.Dir.cwd().access(app.io, pa.venv_python, .{}) catch {
        const text = app.gpa.dupe(u8, "Abliteration needs its own Python environment (torch CPU, transformers; about 1.4 GB from PyPI / download.pytorch.org, installed only under aimgr's data directory). Set it up now as a job?") catch return;
        return openModal(app, text, .abliterate_setup);
    };
    app.prompt_is_search = false;
    app.prompt_is_agent = false;
    app.prompt = "Hugging Face repo to abliterate (owner/name, full-precision safetensors):";
    app.prompt_buf.clearRetainingCapacity();
}

fn promptKey(app: *App, key: term.Key) void {
    switch (key) {
        .esc => {
            app.prompt = null;
        },
        .enter => if (app.prompt_is_agent) submitAgent(app) else if (app.prompt_is_search) submitSearch(app) else submitPrompt(app),
        .backspace => if (app.prompt_buf.items.len > 0) {
            var n = app.prompt_buf.items.len - 1;
            while (n > 0 and (app.prompt_buf.items[n] & 0xC0) == 0x80) n -= 1;
            app.prompt_buf.shrinkRetainingCapacity(n);
        },
        .char => |ch| {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(ch, &buf) catch return;
            if (app.prompt_buf.items.len < 200) app.prompt_buf.appendSlice(app.gpa, buf[0..n]) catch {};
        },
        else => {},
    }
}

fn submitPrompt(app: *App) void {
    app.prompt = null;
    const repo = std.mem.trim(u8, app.prompt_buf.items, " ");
    if (repo.len == 0) return app.setMessage(false, "abliterate cancelled (no repo entered)", .{});
    if (!abl.validRepo(repo)) return app.setMessage(true, "'{s}' is not a repo id like owner/name", .{repo});
    const fa = app.frame.allocator();
    const name = abl.deriveName(fa, repo) catch return;
    for (app.report.reports) |r| {
        if (r.kind != .ollama) continue;
        if (r.probe != .available) return app.setMessage(true, "ollama is unavailable; the result is registered in Ollama", .{});
        for (r.models orelse &.{}) |m| {
            if (std.mem.eql(u8, m.id, name) or (std.mem.startsWith(u8, m.id, name) and m.id.len > name.len and m.id[name.len] == ':')) {
                return app.setMessage(true, "ollama already has '{s}'; remove it first or use the CLI with --name", .{name});
            }
        }
    }
    for (app.report.reports) |r| if (r.kind == .llama and r.probe != .available) {
        return app.setMessage(true, "llama is unavailable; it is needed to quantize", .{});
    };
    const text = std.fmt.allocPrint(app.gpa, "Abliterate {s} into a NEW model \"{s}\" (Q4_K_M, registered in Ollama). Uses the network to download the full-precision weights (can be many GB) and public prompt datasets; runs on CPU and can take a long time. The source is not modified. {s} Start as a job?", .{ repo, name, abl.note_after }) catch return;
    const owned = app.gpa.dupe(u8, repo) catch {
        app.gpa.free(text);
        return;
    };
    openModal(app, text, .{ .abliterate = owned });
}

/// Run `aimgr <args>` (this same executable) as a background job.
fn startSelf(app: *App, kind: jobs_mod.Kind, be: backend.Kind, args: []const []const u8, label: []const u8) void {
    const fa = app.frame.allocator();
    const exe = std.process.executablePathAlloc(app.io, fa) catch return app.setMessage(true, "cannot locate the aimgr executable", .{});
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(fa, exe) catch return;
    argv.appendSlice(fa, args) catch return;
    const err = app.jobs.start(kind, be, label, argv.items, app.environ, app.log_dir, null) catch return app.setMessage(true, "could not start job (out of memory)", .{});
    if (err.len > 0) return app.setMessage(true, "{s}", .{err});
    selectNewest(app, kind);
    app.setMessage(false, "started {s}; see Transfers (key 3). x there cancels it", .{@tagName(kind)});
}

// ---- online discovery ---------------------------------------------------

/// `N`: browse GGUF models without typing a query; each press uses the next sort
/// (trending, downloads, recent). Runs `aimgr browse` as a job (network).
fn browseOnline(app: *App) void {
    const sort = app.browse_sort;
    app.browse_sort = sort.next();
    startSelf(app, .search, .llama, &.{ "browse", "--sort", @tagName(sort), "--limit", "40" }, "");
    app.setMessage(false, "browsing online models sorted by {s} (network, runs as a job); press N again for the next sort", .{@tagName(sort)});
}

fn beginSearch(app: *App) void {
    app.prompt_is_search = true;
    app.prompt_is_agent = false;
    app.prompt = "Search Hugging Face for GGUF models (uses the network):";
    app.prompt_buf.clearRetainingCapacity();
}

fn submitSearch(app: *App) void {
    app.prompt = null;
    app.prompt_is_search = false;
    const q = std.mem.trim(u8, app.prompt_buf.items, " ");
    if (q.len == 0) return;
    if (std.mem.startsWith(u8, q, "-")) return app.setMessage(true, "search text must not start with '-'", .{});
    startSelf(app, .search, .llama, &.{ "search", q, "--limit", "30" }, "");
}

/// Load results of finished `aimgr search` jobs into the Discover list.
fn consumeSearches(app: *App) void {
    for (app.jobs.list.items) |*j| {
        if (j.kind != .search or j.handled or j.isActive()) continue;
        j.handled = true;
        if (j.state != .done) {
            app.setMessage(true, "search failed (exit {d}): {s}; log {s}", .{ j.exit_code orelse 0, j.last_line, j.log_path });
            continue;
        }
        const text = std.Io.Dir.cwd().readFileAlloc(app.io, j.log_path, app.gpa, .limited(1 << 20)) catch {
            app.setMessage(true, "cannot read search results from {s}", .{j.log_path});
            continue;
        };
        defer app.gpa.free(text);
        _ = app.online_arena.reset(.free_all);
        const oa = app.online_arena.allocator();
        var hits: std.ArrayList(model.OnlineHit) = .empty;
        var it = std.mem.tokenizeScalar(u8, text, '\n');
        while (it.next()) |line| {
            // "llama\t<id>\tdownloads=N\tlikes=M..." ; anything else is ignored (untrusted)
            var f = std.mem.splitScalar(u8, line, '\t');
            const be = f.next() orelse continue;
            if (!std.mem.eql(u8, be, "llama")) continue;
            const id = f.next() orelse continue;
            if (!abl.validRepo(id)) continue;
            var dl: u64 = 0;
            var lk: u64 = 0;
            var signin = false;
            while (f.next()) |kv| {
                if (std.mem.startsWith(u8, kv, "downloads=")) dl = std.fmt.parseInt(u64, kv[10..], 10) catch 0;
                if (std.mem.startsWith(u8, kv, "likes=")) lk = std.fmt.parseInt(u64, kv[6..], 10) catch 0;
                if (std.mem.eql(u8, kv, "access=signin")) signin = true;
            }
            hits.append(oa, .{ .id = oa.dupe(u8, id) catch continue, .downloads = dl, .likes = lk, .signin = signin }) catch continue;
        }
        app.online = hits.toOwnedSlice(oa) catch &.{};
        app.setMessage(false, "search found {d} online model(s); they are listed on Discover (d downloads the default quant)", .{app.online.len});
    }
}

/// Append what this model needs (sign-in / cloud / offline) to a confirmation text.
fn accessNote(app: *App, text: *std.ArrayList(u8), fa: std.mem.Allocator, row: model.Row) void {
    const a = row.access orelse return;
    text.print(fa, "Access: {s}. ", .{a.explain()}) catch return;
    if (a == .signin and app.environ.get("HF_TOKEN") == null) {
        text.appendSlice(fa, "HF_TOKEN is not set in aimgr's environment, so a gated download will fail. ") catch return;
    }
}

/// Point the Transfers/Servers selection at the job that was just started.
fn selectNewest(app: *App, kind: jobs_mod.Kind) void {
    var n: usize = 0;
    const want_server = kind == .server;
    for (app.jobs.list.items) |j| {
        if ((j.kind == .server) == want_server) n += 1;
    }
    if (n == 0) return;
    app.sel[@backingInt(if (want_server) model.Tab.servers else model.Tab.transfers)] = n - 1;
}

// ---- agent mode ---------------------------------------------------------

/// `g`: let the selected tool-capable Ollama model look at a directory (see ai/SPEC.md, "Agent mode").
fn beginAgent(app: *App) void {
    const row = app.currentRow() orelse return app.setMessage(true, "no model selected", .{});
    if (row.model.backend != .ollama) return app.setMessage(true, "agent mode currently supports ollama models only", .{});
    if (!row.installed) return app.setMessage(true, "only installed models can be used", .{});
    if (row.access == .cloud) return app.setMessage(true, "cloud models are not given access to this computer", .{});
    const info = row.info orelse return app.setMessage(true, "ollama did not describe this model, so tool support is unknown", .{});
    if (!info.hasCap("tools")) return app.setMessage(true, "ollama reports no tool support for this model; pick one tagged [tools]", .{});
    // A stored directory means no question: the settings are the user's.
    const entries = sources_io.loadAgents(app.frame.allocator(), app.gpa, app.io, app.environ) catch &.{};
    if (agent_settings.find(entries, .ollama, row.model.id)) |i| if (entries[i].dirs != null) return runAgent(app, row.model.id, null);
    app.prompt_is_agent = true;
    app.prompt_is_search = false;
    app.prompt = "Directory the model may look at (absolute path; it cannot leave it):";
    app.prompt_buf.clearRetainingCapacity();
}

fn submitAgent(app: *App) void {
    app.prompt = null;
    app.prompt_is_agent = false;
    const dir = std.mem.trim(u8, app.prompt_buf.items, " ");
    if (dir.len == 0) return app.setMessage(false, "agent cancelled (no directory entered)", .{});
    if (dir[0] != '/') return app.setMessage(true, "the directory must be an absolute path", .{});
    const row = app.currentRow() orelse return;
    runAgent(app, row.model.id, dir);
}

/// Leave the TUI, run `aimgr agent ...` on the real terminal (it prints every tool call and asks before
/// anything beyond read-only), then come back.
fn runAgent(app: *App, id: []const u8, dir: ?[]const u8) void {
    const fa = app.frame.allocator();
    const exe = std.process.executablePathAlloc(app.io, fa) catch return app.setMessage(true, "cannot locate the aimgr executable", .{});
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(fa, &.{ exe, "agent", "ollama", id }) catch return;
    if (dir) |d| argv.appendSlice(fa, &.{ "--dir", d }) catch return;
    term.suspendTerm();
    var ob: [1024]u8 = undefined;
    var eb: [1024]u8 = undefined;
    var ow: std.Io.File.Writer = .initStreaming(.stdout(), app.io, &ob);
    var ew: std.Io.File.Writer = .initStreaming(.stderr(), app.io, &eb);
    const env: supervise.Env = .{ .gpa = app.gpa, .io = app.io, .environ = app.environ, .out = &ow.interface, .err = &ew.interface, .log_dir = null };
    const code = supervise.runChat(env, .{ .argv = argv.items }) catch 1;
    ow.interface.flush() catch {};
    ew.interface.flush() catch {};
    term.resumeTerm();
    installSignals();
    if (code == 0) app.setMessage(false, "agent session ended", .{}) else app.setMessage(true, "agent exited with code {d} (see the messages above in your terminal history)", .{code});
}
