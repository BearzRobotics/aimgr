//! `aimgr agent ...`: run a tool-using session with a local model, and tune its settings per model.
const std = @import("std");
const backend = @import("backend.zig");
const catalog_io = @import("catalog_io.zig");
const config = @import("config.zig");
const inventory = @import("inventory.zig");
const modelinfo = @import("modelinfo.zig");
const netstat = @import("netstat.zig");
const sources_io = @import("sources_io.zig");
const policy = @import("agent/policy.zig");
const settings = @import("agent/settings.zig");
const tools = @import("agent/tools.zig");
const run = @import("agent/run.zig");
const chat = @import("agent/chat.zig");
const llama_server = @import("agent/llama_server.zig");
const capcache = @import("agent/capcache.zig");
const hardware = @import("hardware.zig");

pub const usage =
    \\usage:
    \\  aimgr agent <ollama|llama> <model> [--dir DIR]... [--level off|read-only|inspect|ask]
    \\                               [--steps N] [--timeout S] [--sandbox auto|bwrap|none]
    \\      Chat with a tool-capable model that can look at files and (depending on its level) run commands.
    \\  aimgr agent show <ollama|llama> <model>     effective settings for a model (defaults + stored)
    \\  aimgr agent settings                        all stored per-model settings
    \\  aimgr agent set <ollama|llama> <model> key=value...
    \\        keys: level=  dirs=/a,/b  steps=N  timeout=S  output_kb=N  allow=cmd,cmd  sandbox=  root=true|false
    \\              shell=none|bash|sh|dksh (run_shell, level ask only)  web=true|false  subagents=true|false
    \\              plan=true|false (start in plan mode)  search_url=https://host/?q={q}  (enables web_search)
    \\  aimgr agent reset <ollama|llama> <model>    forget a model's stored settings
    \\
    \\levels:  off        chat only
    \\         read-only  list_dir and read_file inside the allowed directories
    \\         inspect    + a fixed allowlist of read-only commands (ls, cat, grep, find, git status, ...)
    \\         ask        + any other command or file write, each one approved by you
    \\For llama, aimgr starts a private llama server for the session (127.0.0.1, free port) and stops it afterwards.
    \\Defaults depend on the model: no tools -> off; under 7B -> read-only; 7B-30B -> inspect; 30B+ -> ask.
    \\
;

fn fail(err: *std.Io.Writer, msg: []const u8) !u8 {
    try err.print("aimgr: {s}\n", .{msg});
    return 2;
}

/// Effective settings for a model, before CLI flags.
const Effective = struct {
    s: policy.Settings,
    info: ?modelinfo.Info,
    stored: ?settings.Entry,
    has_tools: bool,
};

fn catalogParams(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, kind: backend.Kind, id: []const u8) ?f64 {
    const l = catalog_io.loadAll(arena, gpa, io, env) catch return null;
    if (l.cat.find(kind, id)) |e| if (e.params_b) |p| return p;
    return hardware.parseParamsB(id);
}

fn effective(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, kind: backend.Kind, id: []const u8) !Effective {
    // ollama reports capabilities and size itself; llama's tool support can only be checked once its
    // server is running (see llama_server.supportsTools), so it is assumed here and verified at start.
    const info: ?modelinfo.Info = if (kind == .ollama) modelinfo.fetchOllama(arena, gpa, io, id) else null;
    const has_tools = if (kind == .llama) true else (if (info) |i| i.hasCap("tools") else false);
    const params: ?f64 = if (info) |i| i.paramsB() else catalogParams(arena, gpa, io, env, kind, id);
    const base: policy.Settings = .{ .level = policy.defaultLevel(has_tools, params) };
    const entries = try sources_io.loadAgents(arena, gpa, io, env);
    const idx = settings.find(entries, kind, id);
    const stored: ?settings.Entry = if (idx) |i| entries[i] else null;
    return .{ .s = settings.apply(base, stored), .info = info, .stored = stored, .has_tools = has_tools };
}

fn printSettings(out: *std.Io.Writer, s: policy.Settings) !void {
    try out.print("  level:          {s}\n  directories:    ", .{s.level.text()});
    if (s.dirs.len == 0) try out.writeAll("(none yet)") else for (s.dirs, 0..) |d, i| try out.print("{s}{s}", .{ if (i > 0) ", " else "", d });
    try out.print("\n  max steps:      {d} per request\n  command timeout: {d} s\n  output cap:     {d} KiB\n  sandbox:        {s}\n  root commands:  {s}\n", .{ s.max_steps, s.timeout_s, s.max_output_kb, @tagName(s.sandbox), if (s.allow_root) "may be requested (always asks)" else "denied" });
    try out.print("  shell:          {s}{s}\n  web tools:      {s}{s}\n  sub-agents:     {s}\n  plan mode:      {s}\n", .{
        policy.effectiveShell(s).text(),
        if (s.level != .ask) " (run_shell needs level 'ask')" else "",
        if (s.web) "on (each request asks)" else "off",
        if (s.web and s.search_url != null) ", web_search configured" else if (s.web) ", no search endpoint (web_search off)" else "",
        if (s.subagents) "on" else "off",
        if (s.plan) "sessions start in plan mode" else "off (use /plan in a session)",
    });
    if (s.allow_commands.len > 0) {
        try out.writeAll("  extra read-only commands: ");
        for (s.allow_commands, 0..) |c, i| try out.print("{s}{s}", .{ if (i > 0) ", " else "", c });
        try out.writeByte('\n');
    }
}

pub fn main(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, out: *std.Io.Writer, err: *std.Io.Writer, report: inventory.Inventory, args: []const [:0]const u8) !u8 {
    if (args.len == 0) {
        try err.writeAll(usage);
        return 2;
    }
    const sub = args[0];
    if (std.mem.eql(u8, sub, "settings")) {
        const entries = try sources_io.loadAgents(arena, gpa, io, env);
        if (entries.len == 0) try out.writeAll("no stored agent settings (defaults apply; see 'aimgr agent show <backend> <model>')\n");
        const text = try settings.serialize(arena, entries);
        try out.writeAll(text);
        return 0;
    }
    if (std.mem.eql(u8, sub, "show") or std.mem.eql(u8, sub, "set") or std.mem.eql(u8, sub, "reset")) {
        if (args.len < 3) return fail(err, usage);
        const kind = std.meta.stringToEnum(backend.Kind, args[1]) orelse return fail(err, "backend must be 'ollama' or 'llama'");
        const id = args[2];
        if (std.mem.eql(u8, sub, "show")) {
            const eff = try effective(arena, gpa, io, env, kind, id);
            try out.print("agent settings for {s} {s}\n", .{ kind.name(), id });
            if (kind == .llama) {
                try out.writeAll("  tool support: checked from the chat template when the llama server starts\n");
            } else if (eff.info) |i| try out.print("  reported by ollama: tools={s}, parameters={s}\n", .{ if (eff.has_tools) "yes" else "no", i.parameters orelse "?" }) else try out.writeAll("  (ollama could not describe this model: is it installed and the daemon running?)\n");
            try printSettings(out, eff.s);
            try out.print("  source:         {s}\n", .{if (eff.stored != null) "defaults + your stored settings" else "defaults for this model (nothing stored)"});
            return 0;
        }
        var entries: std.ArrayList(settings.Entry) = .empty;
        try entries.appendSlice(arena, try sources_io.loadAgents(arena, gpa, io, env));
        const idx = settings.find(entries.items, kind, id);
        if (std.mem.eql(u8, sub, "reset")) {
            if (idx) |i| _ = entries.orderedRemove(i) else {
                try out.writeAll("nothing stored for that model\n");
                return 0;
            }
            try sources_io.saveAgents(arena, gpa, io, env, entries.items);
            try out.writeAll("stored settings removed; defaults apply\n");
            return 0;
        }
        if (args.len < 4) return fail(err, usage);
        var e: settings.Entry = if (idx) |i| entries.items[i] else .{ .backend = kind, .id = try arena.dupe(u8, id) };
        for (args[3..]) |kv| {
            settings.setKey(arena, &e, kv) catch |er| {
                try err.print("aimgr: '{s}': {s}\n", .{ kv, switch (er) {
                    error.UnknownKey => "unknown key (level, dirs, steps, timeout, output_kb, allow, sandbox, root, shell, web, subagents, plan, search_url)",
                    error.BadValue => "invalid value",
                    error.OutOfMemory => "out of memory",
                } });
                return 2;
            };
        }
        if (idx) |i| entries.items[i] = e else try entries.append(arena, e);
        try sources_io.saveAgents(arena, gpa, io, env, entries.items);
        const eff = try effective(arena, gpa, io, env, kind, id);
        try out.print("saved. effective settings for {s} {s}:\n", .{ kind.name(), id });
        try printSettings(out, eff.s);
        if (eff.s.level == .ask) try out.writeAll("note: at level 'ask' every command that is not a known read-only one, and every file write, still needs your approval each time.\n");
        if (eff.s.allow_root) try out.writeAll("note: root commands may now be requested; each still needs your explicit approval and will show a warning.\n");
        return 0;
    }

    if (@import("builtin").os.tag == .windows) {
        try err.writeAll("aimgr: agent mode is not available on Windows yet (it needs a sandbox and POSIX path rules). Everything else works.\n");
        return 1;
    }

    // ---- run a session ----
    if (args.len < 2) return fail(err, usage);
    const kind = std.meta.stringToEnum(backend.Kind, args[0]) orelse return fail(err, usage);
    const id = args[1];
    var dirs_cli: std.ArrayList([]const u8) = .empty;
    var level_cli: ?policy.Level = null;
    var steps_cli: ?u32 = null;
    var timeout_cli: ?u32 = null;
    var sandbox_cli: ?policy.Sandbox = null;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (i + 1 >= args.len) return fail(err, usage);
        const a = args[i];
        const v = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, a, "--dir")) {
            try dirs_cli.append(arena, v);
        } else if (std.mem.eql(u8, a, "--level")) {
            level_cli = policy.Level.parse(v) orelse return fail(err, "level must be off, read-only, inspect or ask");
        } else if (std.mem.eql(u8, a, "--steps")) {
            steps_cli = std.fmt.parseInt(u32, v, 10) catch return fail(err, "--steps needs a number");
        } else if (std.mem.eql(u8, a, "--timeout")) {
            timeout_cli = std.fmt.parseInt(u32, v, 10) catch return fail(err, "--timeout needs a number");
        } else if (std.mem.eql(u8, a, "--sandbox")) {
            sandbox_cli = policy.Sandbox.parse(v) orelse return fail(err, "sandbox must be auto, bwrap or none");
        } else return fail(err, usage);
    }

    // Preconditions, each with an actionable message.
    for (report.reports) |r| if (r.kind == kind and r.probe != .available) {
        try err.print("aimgr: {s} is unavailable\n", .{kind.name()});
        return 1;
    };
    if (!inventoryHas(report, kind, id)) {
        try err.print("aimgr: '{s}' is not installed in {s} (exact id required; see 'aimgr list')\n", .{ id, kind.name() });
        return 1;
    }
    if (catalog_io.loadAll(arena, gpa, io, env) catch null) |l| if (l.cat.find(kind, id)) |ent| if (ent.access == .cloud) {
        try err.writeAll("aimgr: that is a cloud model: it runs on a remote service, so aimgr will not give it access to this computer\n");
        return 1;
    };
    var eff = try effective(arena, gpa, io, env, kind, id);
    if (!eff.has_tools) {
        try err.print("aimgr: ollama does not report tool support for '{s}', so it cannot use tools. Pick a model tagged [tools] in 'aimgr list'.\n", .{id});
        return 1;
    }
    if (level_cli) |l| eff.s.level = l;
    if (steps_cli) |n| eff.s.max_steps = @max(1, @min(n, 200));
    if (timeout_cli) |n| eff.s.timeout_s = @max(1, @min(n, 600));
    if (sandbox_cli) |sb| eff.s.sandbox = sb;
    if (eff.s.level == .off) {
        try err.print("aimgr: the autonomy level for '{s}' is 'off'. Raise it with: aimgr agent set {s} {s} level=read-only\n", .{ id, kind.name(), id });
        return 1;
    }

    // Directories: canonical real paths that exist and are directories.
    var dirs: std.ArrayList([]const u8) = .empty;
    const wanted: []const []const u8 = if (dirs_cli.items.len > 0) dirs_cli.items else eff.s.dirs;
    // No directory given: the current one, like launching an editor agent in a project folder.
    const cwd_list: []const []const u8 = &.{"."};
    const from_cwd = wanted.len == 0;
    for (if (from_cwd) cwd_list else wanted) |d| {
        const real = std.Io.Dir.cwd().realPathFileAlloc(io, d, arena) catch {
            try err.print("aimgr: directory not found: {s}\n", .{d});
            return 1;
        };
        var dh = std.Io.Dir.cwd().openDir(io, real, .{}) catch {
            try err.print("aimgr: not a directory: {s}\n", .{d});
            return 1;
        };
        dh.close(io);
        if (std.mem.eql(u8, real, "/")) {
            try err.writeAll("aimgr: refusing to give a model access to '/'; pick a specific directory\n");
            return 1;
        }
        try dirs.append(arena, try arena.dupe(u8, real));
    }
    eff.s.dirs = dirs.items;
    // Folders the user already chose (stored for this model, or trusted before) need no question; a new one
    // is asked once on a terminal and remembered. An explicit --dir/stored dir from a script is consent enough.
    if (from_cwd or dirs_cli.items.len > 0) {
        if (!try trustDirs(arena, io, env, out, err, dirs.items)) return 1;
    }

    return launch(arena, gpa, io, env, out, err, kind, id, eff.s, .interactive);
}

pub const Once = struct { task: []const u8, transcript: *std.Io.Writer };
pub const Mode = union(enum) { interactive, once: Once };

/// Everything after the settings are known and the directories are validated: check the backend server,
/// pick the sandbox, (for llama) start the private server, then run an interactive session or one unattended task.
pub fn launch(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, out_in: *std.Io.Writer, err: *std.Io.Writer, kind: backend.Kind, id: []const u8, s: policy.Settings, mode: Mode) !u8 {
    const out: *std.Io.Writer = switch (mode) {
        .interactive => out_in,
        .once => |o| o.transcript,
    };
    if (kind == .ollama and !netstat.isListening(gpa, io, 11434)) {
        try err.writeAll("aimgr: the ollama daemon is not running on 127.0.0.1:11434. Start it with: aimgr serve ollama\n");
        return 1;
    }
    const sandbox_on = switch (s.sandbox) {
        .none => false,
        .auto => tools.sandboxAvailable(gpa, io),
        .bwrap => blk: {
            if (!tools.sandboxAvailable(gpa, io)) {
                try err.writeAll("aimgr: sandbox=bwrap was requested but bubblewrap cannot run here (not installed, or user namespaces are blocked)\n");
                return 1;
            }
            break :blk true;
        },
    };

    var input: run.Input = undefined;
    switch (mode) {
        .interactive => input.init(io),
        .once => input = .{ .reader = undefined, .closed = true },
    }
    const audit = try config.statePath(arena, env, "agent-audit.log");
    var renv: run.Env = .{ .gpa = gpa, .io = io, .out = out, .err = err, .input = &input, .audit_path = audit, .host_port = "127.0.0.1:11434", .path_env = env.get("PATH"), .home = env.get("HOME"), .skills_dir = skillsDir(arena, io, env), .state_dir = config.statePath(arena, env, "agent-bg") catch null, .mcp = loadMcp(arena, gpa, io, env, err) };
    try out.print("audit log: {s}\n", .{audit orelse "(none)"});

    if (kind == .ollama) return finish(renv, id, s, sandbox_on, mode, arena);

    // llama: start a private server for this session, verify tool support, always stop it afterwards.
    const log_dir = try config.statePath(arena, env, "logs");
    var srv = llama_server.start(arena, gpa, io, env, id, 8192, log_dir, out, 300) catch |e| {
        try err.print("aimgr: {s}", .{llama_server.startErrorText(e)});
        if (e == error.ExitedEarly or e == error.Timeout) try err.print(" (see the llama log in {s})", .{log_dir orelse "the state directory"});
        try err.writeAll("\n");
        return 1;
    };
    defer srv.stop(gpa, io);
    const checked = llama_server.supportsTools(arena, gpa, io, srv.port);
    if (checked) |v| capcache.record(arena, gpa, io, env, .llama, id, v); // remembered for the Settings tab
    switch (checked orelse false) {
        true => {},
        false => {
            try err.print("aimgr: this model's chat template does not support tool calls, so it cannot be used in agent mode. Pick a model tagged [tools] in 'aimgr list'.\n", .{});
            return 1;
        },
    }
    renv.api = .openai;
    renv.host_port = try std.fmt.allocPrint(arena, "127.0.0.1:{d}", .{srv.port});
    return finish(renv, id, s, sandbox_on, mode, arena);
}

fn finish(renv: run.Env, id: []const u8, s: policy.Settings, sandbox_on: bool, mode: Mode, arena: std.mem.Allocator) !u8 {
    switch (mode) {
        .interactive => return run.session(renv, id, s, sandbox_on),
        .once => |o| {
            const text = (try run.runOnce(renv, id, s, sandbox_on, o.task, arena)) orelse {
                try o.transcript.writeAll("\nRESULT: the model server could not be reached or failed.\n");
                return 1;
            };
            try o.transcript.print("\n## Result\n\n{s}\n", .{text});
            return 0;
        },
    }
}

/// ~/.config/aimgr/skills if it exists (user-written *.md instruction files for load_skill).
fn skillsDir(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ?[]const u8 {
    const dir = (config.configPath(arena, env, "skills") catch return null) orelse return null;
    var d = std.Io.Dir.cwd().openDir(io, dir, .{}) catch return null;
    d.close(io);
    return dir;
}

fn inventoryHas(report: inventory.Inventory, kind: backend.Kind, id: []const u8) bool {
    for (report.reports) |r| {
        if (r.kind != kind) continue;
        for (r.models orelse &.{}) |m| if (std.mem.eql(u8, m.id, id)) return true;
    }
    return false;
}

fn loadMcp(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, err: *std.Io.Writer) []const @import("mcp.zig").Server {
    const path = (config.configPath(arena, env, "mcp.toml") catch return &.{}) orelse return &.{};
    return @import("mcp.zig").load(arena, gpa, io, path) catch {
        err.print("aimgr: {s} is invalid; MCP servers are not loaded\n", .{path}) catch {};
        return &.{};
    };
}

/// Directories the user has said "yes, trust this" to, one absolute path per line.
fn trustFile(arena: std.mem.Allocator, env: *const std.process.Environ.Map) ?[]const u8 {
    return (config.configPath(arena, env, "trusted-dirs") catch return null);
}

fn isTrusted(list: []const u8, dir: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, '\n');
    while (it.next()) |l| {
        const t = std.mem.trim(u8, l, " \r");
        if (t.len == 0) continue;
        if (std.mem.eql(u8, t, dir)) return true;
        if (dir.len > t.len and std.mem.startsWith(u8, dir, t) and (t[t.len - 1] == '/' or dir[t.len] == '/')) return true;
    }
    return false;
}

/// Ask once per new directory (only on a terminal) and remember the answer. Returns false if the user declined.
fn trustDirs(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, out: *std.Io.Writer, err: *std.Io.Writer, dirs: []const []const u8) !bool {
    const path = trustFile(arena, env);
    const old = if (path) |p| std.Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(64 * 1024)) catch "" else "";
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(arena, old);
    var changed = false;
    for (dirs) |d| {
        if (isTrusted(old, d)) continue;
        if (!(std.Io.File.stdin().isTty(io) catch false)) continue;
        try out.print("\nDo you trust this folder?\n  {s}\nThe model will be able to read files here (and, at level 'ask', change them, each change shown and approved by you).\nTrust it and remember? [y/N] ", .{d});
        try out.flush();
        var buf: [64]u8 = undefined;
        var r = std.Io.File.stdin().reader(io, &buf);
        const line = (r.interface.takeDelimiter('\n') catch null) orelse "";
        const l = std.mem.trim(u8, line, " \r\t");
        if (!(std.ascii.eqlIgnoreCase(l, "y") or std.ascii.eqlIgnoreCase(l, "yes"))) {
            try err.writeAll("aimgr: not trusted; nothing was started\n");
            return false;
        }
        try text.appendSlice(arena, d);
        try text.append(arena, '\n');
        changed = true;
    }
    if (changed) if (path) |p| {
        if (std.fs.path.dirname(p)) |dd| std.Io.Dir.cwd().createDirPath(io, dd) catch {};
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = text.items }) catch {};
    };
    return true;
}

test "trusted dir matching" {
    try std.testing.expect(isTrusted("/stuff\n", "/stuff"));
    try std.testing.expect(isTrusted("/stuff\n", "/stuff/git/x"));
    try std.testing.expect(!isTrusted("/stuff\n", "/stuffy"));
    try std.testing.expect(!isTrusted("", "/a"));
}
