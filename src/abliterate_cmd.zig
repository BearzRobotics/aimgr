//! `aimgr abliterate setup|run`. Every network step and the final result are
//! announced and confirmed; nothing happens without --yes or an interactive "y".
const std = @import("std");
const abl = @import("abliterate.zig");
const config = @import("config.zig");
const inventory = @import("inventory.zig");
const supervise = @import("supervise.zig");

const usage =
    \\usage:
    \\  aimgr abliterate setup [--yes] [--dry-run]
    \\      Create an aimgr-managed Python venv and install torch (CPU), transformers, ...
    \\  aimgr abliterate run <owner/repo> [options]
    \\      Make an abliterated copy of a full-precision (safetensors) Hugging Face model.
    \\options for run:
    \\  --name NAME            new model name (default: <repo>-abliterated, lowercase)
    \\  --quant Q              F16|Q8_0|Q6_K|Q5_K_M|Q5_K_S|Q4_K_M|Q4_K_S|Q4_0|Q3_K_M|Q2_K (default Q4_K_M)
    \\  --layer-frac X         layer to measure, as a fraction of depth, 0.1-0.95 (default 0.6)
    \\  --n-prompts N          prompts per set, 8-1024 (default 64)
    \\  --holdout N            held-out prompts for the before/after check, 0-64 (default 8)
    \\  --harmful FILE --harmless FILE   your own prompt files (one prompt per line) instead of the public datasets
    \\  --register ollama|none import the result into Ollama (default) or leave the GGUF file only
    \\  --check-quality        also compare perplexity of the original vs the result (same quant, wikitext-2 test text); adds time and disk
    \\  --ppl-text FILE        use your own evaluation text instead of wikitext-2
    \\  --ppl-chunks N         512-token chunks to evaluate, 4-1000 (default 40)
    \\  --force                continue even if the RAM check fails
    \\  --yes                  skip the confirmation question
    \\  --dry-run              print the plan and run nothing
    \\
;

const Common = struct { yes: bool = false, dry_run: bool = false };

fn writeFileSimple(io: std.Io, path: []const u8, content: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });
}

pub fn run(e: supervise.Env, report: inventory.Inventory, arena: std.mem.Allocator, args: []const [:0]const u8) !u8 {
    if (args.len == 0) {
        try e.err.writeAll(usage);
        return 2;
    }
    const data = (try config.dataDir(arena, e.environ)) orelse {
        try e.err.writeAll("aimgr: cannot determine a data directory (HOME / XDG_DATA_HOME not set)\n");
        return 1;
    };
    const res = (try config.resourceDir(arena, e.io, e.environ)) orelse {
        try e.err.writeAll("aimgr: bundled resources not found (expected <exe dir>/../share/aimgr or $AIMGR_RESOURCES); run 'zig build' to install them\n");
        return 1;
    };
    if (std.mem.eql(u8, args[0], "setup")) return setup(e, arena, data, res, args[1..]);
    if (std.mem.eql(u8, args[0], "run")) return runPipeline(e, report, arena, data, res, args[1..]);
    try e.err.writeAll(usage);
    return 2;
}

fn printStages(e: supervise.Env, stages: []const abl.Stage) !void {
    for (stages, 1..) |s, i| {
        try e.out.print("  {d}. {s}: {s}{s}\n", .{ i, s.label, s.what, if (s.network) "  [uses the network]" else "" });
        switch (s.action) {
            .run => |argv| {
                try e.out.writeAll("       $");
                for (argv) |a| try e.out.print(" {s}", .{a});
                try e.out.writeAll("\n");
            },
            .write_file => |w| try e.out.print("       write {s}\n", .{w.path}),
            .make_dir => |d| try e.out.print("       mkdir -p {s}\n", .{d}),
            .report_ppl => try e.out.writeAll("       (prints the perplexity comparison)\n"),
        }
    }
}

fn setup(e: supervise.Env, arena: std.mem.Allocator, data: []const u8, res: []const u8, args: []const [:0]const u8) !u8 {
    var c: Common = .{};
    for (args) |a| {
        if (std.mem.eql(u8, a, "--yes")) c.yes = true else if (std.mem.eql(u8, a, "--dry-run")) c.dry_run = true else {
            try e.err.writeAll(usage);
            return 2;
        }
    }
    const pa = try abl.paths(arena, data, res, "x", "Q4_K_M");
    // Already set up?
    const have_py = blk: {
        std.Io.Dir.cwd().access(e.io, pa.venv_python, .{}) catch break :blk false;
        break :blk true;
    };
    if (have_py) {
        const r = try supervise.runTransfer(e, &.{ pa.venv_python, pa.helper, "check" }, "check");
        if (r == 0) {
            try e.out.print("\nalready set up: {s}\n", .{pa.venv});
            return 0;
        }
        try e.out.writeAll("environment exists but is incomplete; will install the packages again\n");
    }
    const stages = try abl.setupStages(arena, pa);
    try e.out.writeAll("setup plan:\n");
    try printStages(e, stages);
    try e.out.print("\nThis downloads several hundred MB to ~1-2 GB of Python packages from PyPI / download.pytorch.org into {s}.\nNothing outside that directory is changed.\n", .{pa.venv});
    try e.out.flush();
    if (c.dry_run) {
        try e.out.writeAll("dry run: nothing executed.\n");
        return 0;
    }
    if (!c.yes and !supervise.confirm(e, "Create the environment and install packages?")) {
        try e.err.writeAll("aimgr: cancelled\n");
        return 1;
    }
    if (have_py) return execute(e, stages[1..], pa, "setup");
    return execute(e, stages, pa, "setup");
}

fn runPipeline(e: supervise.Env, report: inventory.Inventory, arena: std.mem.Allocator, data: []const u8, res: []const u8, args: []const [:0]const u8) !u8 {
    if (args.len == 0 or std.mem.startsWith(u8, args[0], "-")) {
        try e.err.writeAll(usage);
        return 2;
    }
    var p: abl.Params = .{ .repo = args[0] };
    var c: Common = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--yes")) {
            c.yes = true;
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            c.dry_run = true;
        } else if (std.mem.eql(u8, a, "--force")) {
            p.force = true;
        } else if (std.mem.eql(u8, a, "--check-quality")) {
            p.check_quality = true;
        } else if (i + 1 < args.len and std.mem.startsWith(u8, a, "--")) {
            i += 1;
            const v = args[i];
            if (std.mem.eql(u8, a, "--name")) p.name = v else if (std.mem.eql(u8, a, "--quant")) p.quant = v else if (std.mem.eql(u8, a, "--harmful")) p.harmful_file = v else if (std.mem.eql(u8, a, "--harmless")) p.harmless_file = v else if (std.mem.eql(u8, a, "--ppl-text")) p.ppl_text_file = v else if (std.mem.eql(u8, a, "--ppl-chunks")) {
                p.ppl_chunks = std.fmt.parseInt(u32, v, 10) catch return bad(e, "--ppl-chunks needs an integer");
            } else if (std.mem.eql(u8, a, "--layer-frac")) {
                p.layer_frac = std.fmt.parseFloat(f32, v) catch return bad(e, "--layer-frac needs a number");
            } else if (std.mem.eql(u8, a, "--n-prompts")) {
                p.n_prompts = std.fmt.parseInt(u32, v, 10) catch return bad(e, "--n-prompts needs an integer");
            } else if (std.mem.eql(u8, a, "--holdout")) {
                p.holdout = std.fmt.parseInt(u32, v, 10) catch return bad(e, "--holdout needs an integer");
            } else if (std.mem.eql(u8, a, "--register")) {
                p.register = std.meta.stringToEnum(abl.Register, v) orelse return bad(e, "--register must be ollama or none");
            } else return bad(e, "unknown option");
        } else return bad(e, "unknown or incomplete option");
    }
    abl.validate(p) catch |err| {
        try e.err.print("aimgr: {s}\n", .{abl.errorText(err)});
        return 2;
    };
    const name = p.name orelse try abl.deriveName(arena, p.repo);
    if (!abl.validName(name)) {
        try e.err.print("aimgr: {s}\n", .{abl.errorText(error.InvalidName)});
        return 2;
    }
    const pa = try abl.paths(arena, data, res, name, p.quant);

    // Preconditions, each with an actionable message.
    std.Io.Dir.cwd().access(e.io, pa.venv_python, .{}) catch {
        if (!c.dry_run) {
            try e.err.writeAll("aimgr: the abliteration environment is not set up; run 'aimgr abliterate setup' first\n");
            return 1;
        }
        try e.out.writeAll("warning: the abliteration environment is not set up yet ('aimgr abliterate setup'); showing the plan only\n\n");
    };
    for (report.reports) |r| {
        const need = (r.kind == .llama and !std.mem.eql(u8, p.quant, "F16")) or (r.kind == .ollama and p.register == .ollama);
        if (need and r.probe != .available) {
            try e.err.print("aimgr: {s} is unavailable but this run needs it (quantize / register)\n", .{r.kind.name()});
            return 1;
        }
        if (r.kind == .ollama and p.register == .ollama) for (r.models orelse &.{}) |m| if (std.mem.eql(u8, m.id, name) or std.mem.startsWith(u8, m.id, try std.fmt.allocPrint(arena, "{s}:", .{name}))) {
            try e.err.print("aimgr: ollama already has a model named '{s}'; pick another --name (nothing is overwritten)\n", .{name});
            return 1;
        };
    }
    if (std.Io.Dir.cwd().access(e.io, pa.final_gguf, .{})) |_| {
        try e.err.print("aimgr: {s} already exists; pick another --name (nothing is overwritten)\n", .{pa.final_gguf});
        return 1;
    } else |_| {}

    const stages = try abl.runStages(arena, p, name, pa);
    try e.out.print("abliteration plan\n  source:  {s} (full-precision safetensors)\n  new model: {s}\n  quant:   {s}\n  GGUF:    {s}\n  register: {s}\n\n", .{ p.repo, name, p.quant, pa.final_gguf, @tagName(p.register) });
    try printStages(e, stages);
    try e.out.print("\nNotes:\n  - The source model is only read; the new model is a separate copy.\n  - On CPU this can take a long time; the RAM check aborts early if the model will not fit.\n  - Needs disk for the source weights (~2 bytes/param) plus the edited copy plus GGUF files, under {s}.\n  - {s}\n", .{ pa.work, abl.note_after });
    if (p.harmful_file == null) try e.out.writeAll("  - Default prompt sets are the public datasets mlabonne/harmful_behaviors and mlabonne/harmless_alpaca at pinned revisions (they declare no license; use --harmful/--harmless to supply your own).\n");
    try e.out.flush();
    if (c.dry_run) {
        try e.out.writeAll("dry run: nothing executed.\n");
        return 0;
    }
    if (!c.yes and !supervise.confirm(e, "Run this abliteration (uses the network where marked)?")) {
        try e.err.writeAll("aimgr: cancelled\n");
        return 1;
    }
    const code = try execute(e, stages, pa, "abliterate");
    if (code == 0) {
        try e.out.print("\ndone: {s}\n  {s}\n", .{ name, abl.note_after });
        if (p.register == .none) try e.out.print("GGUF file: {s} (run with: llama serve -m {s})\n", .{ pa.final_gguf, pa.final_gguf });
        try e.out.print("working files kept in {s} (safe to delete once you are happy)\n", .{pa.work});
    }
    return code;
}

fn bad(e: supervise.Env, msg: []const u8) !u8 {
    try e.err.print("aimgr: {s}\n\n{s}", .{ msg, usage });
    return 2;
}

fn execute(e: supervise.Env, stages: []const abl.Stage, pa: abl.Paths, what: []const u8) !u8 {
    for (stages, 1..) |s, i| {
        try e.out.print("\n== [{d}/{d}] {s}: {s}\n", .{ i, stages.len, s.label, s.what });
        try e.out.flush();
        switch (s.action) {
            .make_dir => |d| std.Io.Dir.cwd().createDirPath(e.io, d) catch |err| {
                try e.err.print("aimgr: cannot create {s}: {s}\n", .{ d, @errorName(err) });
                return 1;
            },
            .write_file => |w| writeFileSimple(e.io, w.path, w.content) catch |err| {
                try e.err.print("aimgr: cannot write {s}: {s}\n", .{ w.path, @errorName(err) });
                return 1;
            },
            .report_ppl => |r| try reportPpl(e, r.base_log, r.new_log, r.quant),
            .run => |argv| {
                var env = try e.environ.clone(e.gpa);
                defer env.deinit();
                try env.put("HF_HUB_DISABLE_TELEMETRY", "1");
                try env.put("PYTHONUNBUFFERED", "1");
                if (abl.pythonPathFor(s.label, pa)) |pp| try env.put("PYTHONPATH", pp);
                const code = try supervise.runTransferEnv(e, argv, &env, s.label);
                if (code != 0) {
                    try e.err.print("aimgr: {s} stopped at stage '{s}' (exit {d}). Earlier results are kept under {s}.\n", .{ what, s.label, code, pa.work });
                    return if (code == 130) 130 else 1;
                }
            },
        }
    }
    return 0;
}

fn readLog(e: supervise.Env, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(e.io, path, e.gpa, .limited(64 << 20)) catch null;
}

fn reportPpl(e: supervise.Env, base_log: []const u8, new_log: []const u8, quant: []const u8) !void {
    const bt = readLog(e, base_log);
    defer if (bt) |t| e.gpa.free(t);
    const nt = readLog(e, new_log);
    defer if (nt) |t| e.gpa.free(t);
    const b = if (bt) |t| abl.parsePpl(t) else null;
    const n = if (nt) |t| abl.parsePpl(t) else null;
    if (b == null or n == null) {
        try e.err.print("aimgr: could not read a perplexity result from {s} / {s}\n", .{ base_log, new_log });
        return;
    }
    const delta = (n.?.value - b.?.value) / b.?.value * 100.0;
    try e.out.print("\nperplexity ({s}, lower is better; same text, same settings):\n  original:    {d:.4} +/- {d:.4}\n  abliterated: {d:.4} +/- {d:.4}\n  change:      {s}{d:.2}%\n", .{ quant, b.?.value, b.?.err, n.?.value, n.?.err, if (delta >= 0) "+" else "", delta });
    const noise = (b.?.err + n.?.err);
    if (@abs(n.?.value - b.?.value) <= noise) {
        try e.out.writeAll("  the difference is within the measurement error\n");
    }
    try e.out.writeAll("  perplexity measures general text prediction only; it does not tell you whether answers got worse in other ways\n");
}
