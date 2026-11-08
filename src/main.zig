const std = @import("std");
const aimgr = @import("aimgr");
const inv = aimgr.inventory;

const usage =
    \\aimgr - local AI model manager
    \\
    \\usage: aimgr <command>
    \\
    \\commands:
    \\  tui      interactive interface (default when run in a terminal)
    \\  agent    let a tool-capable model inspect files / run commands under guardrails: agent <ollama> <model> --dir DIR | show | set | settings | reset
    \\  setup-backends  Windows only: download Ollama (checked, asks first): setup-backends [--yes] [--dry-run]
    \\  schedule saved agent tasks that run unattended (read-only/inspect only): schedule add|list|run|run-due|results|install ...
    \\  sources  manage where models are discovered: sources [list] | add <kind> <id> [<location>] | enable|disable|remove <id> | refresh [<id>]
    \\  search   search Hugging Face for GGUF models (network, only when you run it): search <text> [--limit N]
    \\  browse   list GGUF models without a query (network, only when you run it): browse [--sort trending|downloads|recent] [--limit N]
    \\  hardware show RAM and GPUs found, and what the fit estimates are based on
    \\  probe    show backend availability and versions
    \\  list     list installed models from every backend
    \\             [--backend ollama|llama] [--filter TEXT] [--abliterated] [--use TAG] [--access open|signin|cloud] [--fit]
    \\  chat     run a model interactively (offline; model must be installed)
    \\             chat <ollama|llama> <model> [--ctx N] [--gpu-layers N|auto|all]
    \\  serve    run an API server, bound to 127.0.0.1 unless confirmed
    \\             serve <ollama|llama> [model] [--host H] [--port P] [--ctx N] [--gpu-layers N|auto|all]
    \\             (llama needs a model; ollama serve takes none and reuses a running daemon)
    \\  pull     download a model (network):   pull <ollama|llama> <id> [--yes] [--dry-run]
    \\  update   re-pull an installed model:   update <ollama|llama> <id> [--yes] [--dry-run]
    \\  remove   delete via backend (ollama only; disabled for llama): remove <backend> <id> [--yes] [--dry-run]
    \\  abliterate  make an abliterated copy of a model: abliterate setup | abliterate run <owner/repo> [options]
    \\  help     show this help
    \\
;

/// Restore the terminal before a panic message is printed.
pub const panic = std.debug.FullPanic(panicRestore);

fn panicRestore(msg: []const u8, first_trace_addr: ?usize) noreturn {
    aimgr.term.deinit();
    std.debug.defaultPanic(msg, first_trace_addr);
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (@import("builtin").os.tag == .windows) {
        // Ollama installed by `aimgr setup-backends` lives in aimgr's data folder.
        if (aimgr.setup_backends.ollamaDir(arena, init.environ_map) catch null) |d| {
            const exe = std.fs.path.join(arena, &.{ d, "ollama.exe" }) catch "";
            if (std.Io.Dir.cwd().access(io, exe, .{})) |_| aimgr.platform.prependPath(arena, init.environ_map, d) else |_| {}
        }
    }

    var out_buf: [4096]u8 = undefined;
    var out_w: std.Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
    const out = &out_w.interface;
    var err_buf: [1024]u8 = undefined;
    var err_w: std.Io.File.Writer = .initStreaming(.stderr(), io, &err_buf);
    const err = &err_w.interface;

    const interactive = std.Io.File.stdout().isTty(io) catch false;
    const cmd = if (args.len > 1) args[1] else if (interactive) "tui" else "help";
    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "version")) {
        try out.print("aimgr {s} ({s}-{s})\n", .{ aimgr.version, @tagName(@import("builtin").cpu.arch), @tagName(@import("builtin").os.tag) });
        try out.flush();
        return 0;
    }
    var code: u8 = 0;
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try out.writeAll(usage);
    } else if (std.mem.eql(u8, cmd, "tui")) {
        if (!interactive) {
            try err.writeAll("aimgr: tui needs a terminal on stdout\n");
            code = 1;
        } else {
            code = aimgr.tui_app.run(init.gpa, io, init.environ_map) catch |e| blk: {
                try err.print("aimgr: tui failed: {s}\n", .{@errorName(e)});
                break :blk 1;
            };
        }
    } else if (std.mem.eql(u8, cmd, "agent")) {
        const report = inv.discover(arena, init.gpa, io);
        code = try aimgr.agent_cmd.main(arena, init.gpa, io, init.environ_map, out, err, report, args[2..]);
    } else if (std.mem.eql(u8, cmd, "setup-backends")) {
        code = try aimgr.setup_backends.main(arena, init.gpa, io, init.environ_map, out, err, args[2..]);
    } else if (std.mem.eql(u8, cmd, "schedule")) {
        const report = inv.discover(arena, init.gpa, io);
        code = try aimgr.schedule_cmd.main(arena, init.gpa, io, init.environ_map, out, err, report, args[2..]);
    } else if (std.mem.eql(u8, cmd, "sources")) {
        code = try aimgr.sources_cmd.run(arena, init.gpa, io, init.environ_map, out, err, args[2..]);
    } else if (std.mem.eql(u8, cmd, "search")) {
        code = try runSearch(arena, init.gpa, io, init.environ_map, out, err, args[2..]);
    } else if (std.mem.eql(u8, cmd, "browse")) {
        code = try runBrowse(arena, init.gpa, io, init.environ_map, out, err, args[2..]);
    } else if (std.mem.eql(u8, cmd, "hardware")) {
        const hw = try aimgr.hardware.detect(arena, init.gpa, io);
        try out.print("RAM: {d:.1} GB total, {d:.1} GB available\n", .{ aimgr.hardware.gb(hw.mem.total), aimgr.hardware.gb(hw.mem.available) });
        if (hw.gpus.len == 0) try out.writeAll("GPU: none detected\n");
        for (hw.gpus) |g| try out.print("GPU: {s} {s}: {d:.1} GB VRAM, {d:.1} GB free{s} [{s}]\n", .{ @tagName(g.vendor), g.label, aimgr.hardware.gb(g.vram_total), aimgr.hardware.gb(g.free()), if (g.integrated) " (integrated, ignored for fit)" else "", g.source });
        try out.writeAll("Fit estimates (list --fit, TUI detail) are advisory ranges at 4096 context:\n  weights from the reported size (or parameter count in the name x quantization bits),\n  plus a KV-cache range of 0.01-0.075 MiB per token per billion parameters and 0.3-0.8 GB runtime overhead.\n");
    } else if (std.mem.eql(u8, cmd, "probe") or std.mem.eql(u8, cmd, "list")) {
        const report = inv.discover(arena, init.gpa, io);
        if (cmd[0] == 'p') {
            code = try printProbe(out, report);
        } else {
            const opts = parseListArgs(args[2..]) catch {
                try err.print("aimgr: bad arguments for 'list'\n\n{s}", .{usage});
                try err.flush();
                return 2;
            };
            var cat: aimgr.catalog.Catalog = .{};
            try loadCatalog(arena, init.gpa, io, init.environ_map, &cat, err);
            code = try printList(arena, init.gpa, io, out, err, report, &cat, opts);
        }
    } else if (std.mem.eql(u8, cmd, "chat") or std.mem.eql(u8, cmd, "serve")) {
        const report = inv.discover(arena, init.gpa, io);
        const log_dir = try aimgr.config.statePath(arena, init.environ_map, "logs");
        const env: aimgr.supervise.Env = .{ .gpa = init.gpa, .io = io, .environ = init.environ_map, .out = out, .err = err, .log_dir = log_dir };
        const mode: aimgr.launcher.Mode = if (cmd[0] == 'c') .chat else .server;
        code = try aimgr.launch_cmd.run(env, report, arena, mode, args[2..]);
    } else if (std.mem.eql(u8, cmd, "pull") or std.mem.eql(u8, cmd, "update") or std.mem.eql(u8, cmd, "remove")) {
        const report = inv.discover(arena, init.gpa, io);
        const env: aimgr.supervise.Env = .{ .gpa = init.gpa, .io = io, .environ = init.environ_map, .out = out, .err = err, .log_dir = null };
        const action = std.meta.stringToEnum(aimgr.manage.Action, cmd).?;
        code = try aimgr.manage_cmd.run(env, report, arena, action, args[2..]);
    } else if (std.mem.eql(u8, cmd, "abliterate")) {
        const report = inv.discover(arena, init.gpa, io);
        const env: aimgr.supervise.Env = .{ .gpa = init.gpa, .io = io, .environ = init.environ_map, .out = out, .err = err, .log_dir = null };
        code = try aimgr.abliterate_cmd.run(env, report, arena, args[2..]);
    } else {
        try err.print("aimgr: unknown command '{s}'\n\n", .{cmd});
        try err.writeAll(usage);
        code = 2;
    }
    try out.flush();
    try err.flush();
    return code;
}

fn printProbe(out: *std.Io.Writer, report: inv.Inventory) !u8 {
    var code: u8 = 0;
    for (report.reports) |r| switch (r.probe) {
        .available => |v| try out.print("{s}: available, version {s}\n", .{ r.kind.name(), v }),
        .missing => {
            try out.print("{s}: unavailable (executable not found)\n", .{r.kind.name()});
            code = 1;
        },
        .failed => |why| {
            try out.print("{s}: unavailable ({s})\n", .{ r.kind.name(), why });
            code = 1;
        },
    };
    return code;
}

const ListOpts = struct {
    backend: ?aimgr.backend.Kind = null,
    filter: ?[]const u8 = null,
    /// Only models detected as abliterated (tag or name heuristic).
    abliterated: bool = false,
    /// Add an advisory hardware-fit column.
    fit: bool = false,
    /// Only entries tagged as good for this use (coding, reasoning, vision, tools, ...).
    use: ?[]const u8 = null,
    access: ?aimgr.catalog.Access = null,
};

fn parseListArgs(args: []const [:0]const u8) !ListOpts {
    var o: ListOpts = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--backend")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            o.backend = std.meta.stringToEnum(aimgr.backend.Kind, args[i]) orelse return error.BadArgs;
        } else if (std.mem.eql(u8, args[i], "--filter")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            o.filter = args[i];
        } else if (std.mem.eql(u8, args[i], "--abliterated")) {
            o.abliterated = true;
        } else if (std.mem.eql(u8, args[i], "--fit")) {
            o.fit = true;
        } else if (std.mem.eql(u8, args[i], "--use")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            o.use = args[i];
        } else if (std.mem.eql(u8, args[i], "--access")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            o.access = std.meta.stringToEnum(aimgr.catalog.Access, args[i]) orelse return error.BadArgs;
        } else return error.BadArgs;
    }
    return o;
}

fn loadCatalog(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, cat: *aimgr.catalog.Catalog, err: *std.Io.Writer) !void {
    const loaded = try aimgr.catalog_io.loadAll(arena, gpa, io, env);
    cat.* = loaded.cat;
    for (loaded.warnings) |w| try err.print("aimgr: {s}\n", .{w});
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    return std.ascii.findIgnoreCase(hay, needle) != null;
}

fn matches(m: aimgr.backend.Model, e: ?*const aimgr.catalog.Entry, f: []const u8) bool {
    if (containsIgnoreCase(m.id, f)) return true;
    const ent = e orelse return false;
    if (ent.name) |n| if (containsIgnoreCase(n, f)) return true;
    if (ent.description) |d| if (containsIgnoreCase(d, f)) return true;
    for (ent.use_cases) |u| if (containsIgnoreCase(u, f)) return true;
    for (ent.tags) |t| if (containsIgnoreCase(t, f)) return true;
    return false;
}

fn printList(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, err: *std.Io.Writer, report: inv.Inventory, cat: *const aimgr.catalog.Catalog, opts: ListOpts) !u8 {
    var code: u8 = 0;
    const hw = if (opts.fit) try aimgr.hardware.detect(arena, gpa, io) else aimgr.hardware.Info{ .mem = .{}, .gpus = &.{} };
    for (report.reports) |r| {
        if (opts.backend) |b| if (b != r.kind) continue;
        if (r.probe != .available) {
            try err.print("aimgr: {s}: unavailable\n", .{r.kind.name()});
            code = 1;
            continue;
        }
        if (r.list_error) |e| {
            try err.print("aimgr: {s}: list failed: {s}\n", .{ r.kind.name(), inv.listErrorText(e) });
            code = 1;
            continue;
        }
        for (r.models.?) |m| {
            const ent = cat.find(m.backend, m.id);
            if (opts.filter) |f| if (!matches(m, ent, f)) continue;
            const ablit = aimgr.catalog.isAbliterated(m.id, ent);
            if (opts.abliterated and !ablit) continue;
            if (opts.use) |u| {
                var has_use = false;
                if (ent) |x| for (x.use_cases) |c| if (std.ascii.eqlIgnoreCase(c, u)) {
                    has_use = true;
                };
                if (!has_use) continue;
            }
            if (opts.access) |want| {
                const got = if (ent) |x| x.access else null;
                if (got == null or got.? != want) continue;
            }
            try out.print("{s}\t{s}", .{ m.backend.name(), m.id });
            if (m.size_text) |s| try out.print("\tsize={s}", .{s});
            if (m.quant) |q| try out.print("\tquant={s}", .{q});
            if (m.modified) |t| try out.print("\tmodified={s}", .{t});
            if (opts.fit) {
                const f = aimgr.hardware.estimate(m.id, m.quant, aimgr.backend.parseSizeText(m.size_text), 4096, hw);
                try out.print("\tfit={s}", .{@tagName(f.verdict)});
                if (f.verdict != .unknown) try out.print("({d:.1}-{d:.1}GB@4k{s})", .{ aimgr.hardware.gb(f.need_low), aimgr.hardware.gb(f.need_high), if (f.weights_estimated) ",est" else "" });
            }
            if (ablit) try out.writeAll("\t[abliterated]");
            if (ent) |x| {
                if (x.name) |n| try out.print("\tname={s}", .{n});
                if (x.access) |ac| try out.print("\taccess={s}\toffline={s}", .{ ac.label(), if (ac.runsOffline()) "yes" else "no" });
                if (x.use_cases.len > 0) {
                    try out.writeAll("\tuse=");
                    for (x.use_cases, 0..) |u, i| try out.print("{s}{s}", .{ if (i > 0) "," else "", u });
                }
            } else try out.writeAll("\t(no catalog entry)");
            try out.writeAll("\n");
        }
    }
    return code;
}

/// Enabled online sources, optionally restricted to one id.
fn onlineSources(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, only: ?[]const u8, err: *std.Io.Writer) !?[]aimgr.sources.Source {
    const loaded = try aimgr.sources_io.load(arena, gpa, io, env);
    if (loaded.warning) |w| try err.print("aimgr: {s}\n", .{w});
    var picked: std.ArrayList(aimgr.sources.Source) = .empty;
    for (loaded.list) |src| {
        if (!src.kind.isOnline()) continue;
        if (only) |o| {
            if (!std.mem.eql(u8, o, src.id)) continue;
        } else if (!src.enabled) continue;
        if (only != null and !src.enabled) {
            try err.print("aimgr: source '{s}' is disabled (aimgr sources enable {s})\n", .{ src.id, src.id });
            return null;
        }
        try picked.append(arena, src);
    }
    if (picked.items.len == 0) {
        try err.writeAll(if (only != null) "aimgr: no such online source (see 'aimgr sources')\n" else "aimgr: no enabled online source; enable one with 'aimgr sources enable huggingface'\n");
        return null;
    }
    return try picked.toOwnedSlice(arena);
}

fn printHit(out: *std.Io.Writer, r: aimgr.discover.Result, source_id: []const u8) !void {
    try out.print("llama\t{s}\tdownloads={d}\tlikes={d}\tsource={s}{s}{s}\n", .{ r.id, r.downloads, r.likes, source_id, if (r.gated) "\taccess=signin" else "", if (aimgr.catalog.isAbliterated(r.id, null)) "\t[abliterated]" else "" });
}

fn runSearch(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, out: *std.Io.Writer, err: *std.Io.Writer, args: []const [:0]const u8) !u8 {
    var query: ?[]const u8 = null;
    var limit: u32 = 15;
    var only: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--limit")) {
            i += 1;
            if (i >= args.len) return searchUsage(err);
            limit = std.fmt.parseInt(u32, args[i], 10) catch return searchUsage(err);
            if (limit == 0 or limit > 100) return searchUsage(err);
        } else if (std.mem.eql(u8, args[i], "--source")) {
            i += 1;
            if (i >= args.len) return searchUsage(err);
            only = args[i];
        } else if (query == null and !std.mem.startsWith(u8, args[i], "--")) {
            query = args[i];
        } else return searchUsage(err);
    }
    const q = query orelse return searchUsage(err);
    const targets = (try onlineSources(arena, gpa, io, env, only, err)) orelse return 1;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var code: u8 = 0;
    var total: usize = 0;
    for (targets) |t| {
        try out.print("searching {s} for GGUF models matching \"{s}\" (network, source '{s}')...\n", .{ t.endpoint(), q, t.id });
        try out.flush();
        const results = aimgr.discover.search(arena, gpa, io, t.endpoint(), q, limit) catch |e| {
            try err.print("aimgr: source '{s}': search failed: {s}\n", .{ t.id, aimgr.discover.errorText(e) });
            code = 1;
            continue;
        };
        for (results) |r| {
            if ((try seen.getOrPut(arena, r.id)).found_existing) continue;
            total += 1;
            try printHit(out, r, t.id);
        }
    }
    if (total == 0 and code == 0) try out.writeAll("no results\n");
    if (total > 0) try out.writeAll("download with: aimgr pull llama <id>[:QUANT]   (default quant Q4_K_M; see 'aimgr hardware' for what fits)\n");
    return code;
}

fn searchUsage(err: *std.Io.Writer) !u8 {
    try err.writeAll("usage: aimgr search <text> [--limit 1-100] [--source ID]\n");
    return 2;
}

fn runBrowse(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, out: *std.Io.Writer, err: *std.Io.Writer, args: []const [:0]const u8) !u8 {
    var sort: aimgr.discover.Sort = .trending;
    var limit: u32 = 30;
    var only: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return browseUsage(err);
        if (std.mem.eql(u8, args[i], "--sort")) {
            sort = std.meta.stringToEnum(aimgr.discover.Sort, args[i + 1]) orelse return browseUsage(err);
        } else if (std.mem.eql(u8, args[i], "--limit")) {
            limit = std.fmt.parseInt(u32, args[i + 1], 10) catch return browseUsage(err);
            if (limit == 0 or limit > 100) return browseUsage(err);
        } else if (std.mem.eql(u8, args[i], "--source")) {
            only = args[i + 1];
        } else return browseUsage(err);
    }
    const targets = (try onlineSources(arena, gpa, io, env, only, err)) orelse return 1;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var code: u8 = 0;
    var total: usize = 0;
    for (targets) |t| {
        try out.print("browsing {s} GGUF text-generation models, sorted by {s} (network, source '{s}')...\n", .{ t.endpoint(), @tagName(sort), t.id });
        try out.flush();
        const results = aimgr.discover.browse(arena, gpa, io, t.endpoint(), sort, limit) catch |e| {
            try err.print("aimgr: source '{s}': browse failed: {s}\n", .{ t.id, aimgr.discover.errorText(e) });
            code = 1;
            continue;
        };
        for (results) |r| {
            if ((try seen.getOrPut(arena, r.id)).found_existing) continue;
            total += 1;
            try printHit(out, r, t.id);
        }
    }
    if (total > 0) try out.writeAll("these are unvetted third-party repositories; check the model card. download with: aimgr pull llama <id>[:QUANT]\n");
    return code;
}

fn browseUsage(err: *std.Io.Writer) !u8 {
    try err.writeAll("usage: aimgr browse [--sort trending|downloads|recent] [--limit 1-100] [--source ID]\n");
    return 2;
}
