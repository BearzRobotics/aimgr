//! Tool handlers: each model request goes through policy, then (if needed) the user, then execution.
//! Model output is data: it can never approve anything or change settings.
const std = @import("std");
const chat = @import("chat.zig");
const policy = @import("policy.zig");
const tools = @import("tools.zig");
const envm = @import("env.zig");
const extra = @import("extra.zig");
const workflow = @import("workflow.zig");

const Env = envm.Env;
const mcp = @import("../mcp.zig");
const activity = @import("activity.zig");
const State = envm.State;

/// What a rule pattern is matched against, per tool (paths are normalized so rules can use absolute paths).
fn ruleSubjects(arena: std.mem.Allocator, s: policy.Settings, tool: tools.Tool, args: std.json.ObjectMap) ![2]?[]const u8 {
    const base = if (s.dirs.len > 0) s.dirs[0] else "/";
    const norm = struct {
        fn f(a: std.mem.Allocator, b: []const u8, p: ?[]const u8) !?[]const u8 {
            const path = p orelse return null;
            if (path.len == 0 or path.len > 4096) return null;
            return try policy.normalizePath(a, b, path);
        }
    }.f;
    return switch (tool) {
        .list_dir, .read_file, .write_file, .edit_file, .make_dir, .delete_file, .edit_notebook_cell => .{ try norm(arena, base, getStr(args, "path")), null },
        .search_files, .find_files => .{ try norm(arena, base, getStr(args, "path") orelse base), null },
        .move_file => .{ try norm(arena, base, getStr(args, "from")), try norm(arena, base, getStr(args, "to")) },
        .run_command, .run_shell, .run_background => .{ getStr(args, "command"), null },
        .web_fetch => .{ getStr(args, "url"), null },
        .web_search => .{ getStr(args, "query"), null },
        .notify => .{ getStr(args, "title"), null },
        else => .{ null, null },
    };
}

pub fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

pub fn getInt(obj: std.json.ObjectMap, key: []const u8) ?u64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| if (i >= 0) @as(u64, @intCast(i)) else null,
        .float => |f| if (f >= 0 and f < 1e15) @as(u64, @intFromFloat(f)) else null,
        .string => |sv| std.fmt.parseInt(u64, sv, 10) catch null,
        else => null,
    };
}

fn shellQuote(arena: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (argv, 0..) |a, i| {
        if (i > 0) try out.append(arena, ' ');
        const plain = a.len > 0 and std.mem.indexOfAny(u8, a, " \t'\"\\") == null;
        if (plain) try out.appendSlice(arena, a) else try out.print(arena, "'{s}'", .{a});
    }
    return out.toOwnedSlice(arena);
}

pub const Outcome = struct { text: []const u8, decision: []const u8, reason: []const u8 };

/// Show `what` live in the status line while a slow operation runs (the output so far is flushed first).
pub fn busy(e: Env, what: []const u8) !void {
    try e.out.flush();
    activity.set(what);
}

pub fn ask(e: Env, st: *State, question: []const u8) bool {
    if (st.unattended) {
        e.out.print("\n  (unattended run: \"{s}\" would need approval, so it is denied)\n", .{question[0..@min(question.len, 100)]}) catch {};
        return false;
    }
    if (st.rule_allow) |rule| {
        e.out.print("\n  (approved automatically by your rule {s})\n", .{rule}) catch {};
        return true;
    }
    if (st.ask_edit and st.auto_edits) {
        e.out.writeAll("  (approved: edits mode)\n") catch {};
        return true;
    }
    if (st.ask_always) for (st.session_allow.items) |k| if (std.mem.eql(u8, k, st.ask_key)) {
        e.out.print("  (approved: you said 'always' for {s} this session)\n", .{k}) catch {};
        return true;
    };
    var l: []const u8 = "";
    if (e.ui) |u| {
        // A menu: arrows, numbers, y/n or the mouse. The last option is always No.
        var full_buf: [600]u8 = undefined;
        const full = std.fmt.bufPrint(&full_buf, "{s}{s}{s}{s}", .{ if (st.actor.len > 0) "[" else "", st.actor, if (st.actor.len > 0) "] " else "", question }) catch question;
        const always_label: []const u8 = if (st.ask_edit) "Yes, and allow all edits in these folders for this session" else "Yes, and don't ask again for this exact action this session";
        const with_always = [_][]const u8{ "Yes", always_label, "No" };
        const plain = [_][]const u8{ "Yes", "No" };
        const opts: []const []const u8 = if (st.ask_always) &with_always else &plain;
        const pick = u.choose(full, opts) orelse return false;
        l = if (pick == 0) "y" else if (st.ask_always and pick == 1) "a" else "n";
    } else {
        const choices: []const u8 = if (!st.ask_always) "[y/N]" else if (st.ask_edit) "[y/N/a=allow all edits this session]" else "[y/N/a=always this session]";
        e.out.print("\n  ? {s}{s}{s}{s}  {s} ", .{ if (st.actor.len > 0) "[" else "", st.actor, if (st.actor.len > 0) "] " else "", question, choices }) catch return false;
        e.out.flush() catch return false;
        l = e.input.line() orelse return false;
    }
    if (st.ask_always and (std.ascii.eqlIgnoreCase(l, "a") or std.ascii.eqlIgnoreCase(l, "always"))) {
        if (st.ask_edit) {
            st.auto_edits = true;
            e.out.writeAll("  edits mode on: file edits in the allowed folders are approved for the rest of this session (/mode default to undo)\n") catch {};
        } else if (e.gpa.dupe(u8, st.ask_key)) |k| {
            st.session_allow.append(e.gpa, k) catch e.gpa.free(k);
            e.out.print("  will not ask again this session for {s}\n", .{st.ask_key}) catch {};
        } else |_| {}
        return true;
    }
    return std.ascii.eqlIgnoreCase(l, "y") or std.ascii.eqlIgnoreCase(l, "yes");
}

pub fn resolveText(er: tools.ResolveError) []const u8 {
    return switch (er) {
        error.OutsideDirs => "a symlink leads outside the allowed directories",
        error.NotFound => "no such file or directory (absolute paths start with '/'; other paths are relative to the first allowed directory)",
        error.BadPath => "invalid path",
        error.OutOfMemory => "out of memory",
    };
}

pub fn denied(arena: std.mem.Allocator, reason: []const u8) !Outcome {
    return .{ .text = try std.fmt.allocPrint(arena, "DENIED: {s}", .{reason}), .decision = "denied", .reason = reason };
}

/// Run one tool call through policy and (if needed) the user. Never returns an error for model mistakes:
/// those become text for the model.
/// A tool of a user-configured MCP server: level ask only, never in plan mode / unattended / sub-agents,
/// approval for every call unless the user listed the tool as read-only (deny rules always apply).
fn mcpCall(e: Env, st: *State, arena: std.mem.Allocator, s: policy.Settings, server: []const u8, tool: []const u8, call: chat.Call) anyerror!Outcome {
    if (s.level != .ask or st.plan_mode or st.unattended or st.depth != 0) return denied(arena, "MCP tools need level ask, outside plan mode, in the main session");
    // Only tools the server really announced at session start can be called.
    var idx: ?usize = null;
    for (st.mcp_tools orelse &.{}) |t| {
        if (std.mem.eql(u8, e.mcp[t.server].id, server) and std.mem.eql(u8, t.name, tool)) idx = t.server;
    }
    const si = idx orelse return denied(arena, "unknown tool");
    const srv = e.mcp[si];
    const parsed = std.json.parseFromSlice(std.json.Value, arena, call.args_json, .{}) catch return denied(arena, "arguments are not valid JSON");
    if (parsed.value != .object) return denied(arena, "arguments must be an object");
    st.rule_allow = null;
    defer st.rule_allow = null;
    st.ask_key = call.name;
    st.ask_always = true;
    defer {
        st.ask_key = "";
        st.ask_always = false;
    }
    switch (policy.ruleCheck(s, call.name, call.args_json)) {
        .deny => |r| return denied(arena, try std.fmt.allocPrint(arena, "denied by your rule {s}", .{r})),
        .allow => |r| st.rule_allow = r,
        .none => {},
    }
    var how: []const u8 = "auto (listed read-only)";
    if (!mcp.isReadOnly(srv, tool)) {
        const shown = call.args_json[0..@min(call.args_json.len, 300)];
        if (!ask(e, st, try std.fmt.allocPrint(arena, "ALLOW MCP tool {s}.{s} (a program you configured, NOT sandboxed) with {s}?", .{ server, tool, shown }))) return .{ .text = "DENIED: the user declined", .decision = "declined", .reason = "mcp" };
        how = "approved";
    }
    try e.out.print("  [{s}]  ({s})\n", .{ call.name, how });
    const tmp = e.state_dir orelse return denied(arena, "no state directory for MCP");
    const text = mcp.callTool(arena, e.gpa, e.io, tmp, srv, tool, call.args_json, s.timeout_s * 3);
    return .{ .text = text, .decision = how, .reason = "mcp" };
}

pub fn handleCall(e: Env, st: *State, arena: std.mem.Allocator, s_in: policy.Settings, sandbox_on: bool, call: chat.Call) anyerror!Outcome {
    // Inside a git worktree the working directory is the worktree (the originals stay allowed).
    const s = try workflow.view(arena, s_in, st);
    if (mcp.splitName(call.name)) |m| return mcpCall(e, st, arena, s, m.server, m.tool, call);
    const tool = tools.toolFromName(call.name) orelse return denied(arena, "unknown tool");
    const level_ok = switch (tool) {
        .list_dir, .read_file, .search_files, .find_files, .ask_user, .update_todos, .load_skill => s.level.atLeast(.read_only),
        .run_command, .notify => s.level.atLeast(.inspect),
        .write_file, .edit_file, .move_file, .make_dir, .delete_file, .run_shell, .edit_notebook_cell, .enter_worktree, .exit_worktree => s.level == .ask,
        .run_background, .check_background, .stop_background => s.level == .ask and policy.effectiveShell(s) != .none,
        .submit_plan => s.level.atLeast(.read_only) and st.plan_mode,
        .spawn_agent => s.level.atLeast(.read_only) and s.subagents and st.depth == 0,
        .web_fetch => s.level.atLeast(.read_only) and s.web,
        .web_search => s.level.atLeast(.read_only) and s.web and s.search_url != null,
    };
    if (!level_ok) return denied(arena, "this tool is not enabled at the current autonomy level or settings");
    // Plan mode: whatever the model asks for by name, nothing that changes state, runs code or reaches out.
    if (st.plan_mode) switch (tool) {
        .run_command, .run_shell, .write_file, .edit_file, .move_file, .make_dir, .delete_file, .spawn_agent, .web_fetch, .web_search, .notify, .edit_notebook_cell, .run_background, .check_background, .stop_background, .enter_worktree, .exit_worktree => return denied(arena, "plan mode: only reading tools work until the user approves a plan (use submit_plan)"),
        else => {},
    };

    const parsed = std.json.parseFromSlice(std.json.Value, arena, call.args_json, .{}) catch return denied(arena, "arguments are not valid JSON");
    if (parsed.value != .object) return denied(arena, "arguments must be an object");
    const args = parsed.value.object;

    // The user's own rules: a matching deny always wins; an allow rule answers approval prompts.
    st.rule_allow = null;
    defer st.rule_allow = null;
    const subjects = try ruleSubjects(arena, s, tool, args);
    st.ask_key = try std.fmt.allocPrint(arena, "{s}({s})", .{ @tagName(tool), subjects[0] orelse "" });
    st.ask_edit = switch (tool) {
        .write_file, .edit_file, .edit_notebook_cell, .make_dir, .move_file => true,
        else => false,
    };
    // Never "always" for deleting, approving plans, or switching worktrees: those are asked every time.
    st.ask_always = switch (tool) {
        .delete_file, .submit_plan, .enter_worktree, .exit_worktree => false,
        else => true,
    };
    defer {
        st.ask_key = "";
        st.ask_edit = false;
        st.ask_always = false;
    }
    for (subjects) |subject| {
        const subj = subject orelse continue;
        switch (policy.ruleCheck(s, @tagName(tool), subj)) {
            .deny => |r| return denied(arena, try std.fmt.allocPrint(arena, "denied by your rule {s}", .{r})),
            .allow => |r| st.rule_allow = r,
            .none => {},
        }
    }

    switch (tool) {
        .find_files, .ask_user, .update_todos, .load_skill, .run_shell, .submit_plan, .spawn_agent, .web_fetch, .web_search, .notify, .edit_notebook_cell => return extra.handle(e, st, arena, s, sandbox_on, tool, args),
        .run_background, .check_background, .stop_background, .enter_worktree, .exit_worktree => return workflow.handle(e, st, arena, s, sandbox_on, tool, args),
        .list_dir, .read_file => {
            const path = getStr(args, "path") orelse return denied(arena, "missing 'path'");
            const norm = tools.resolve(arena, e.io, s, path, true) catch |er| return denied(arena, switch (er) {
                error.OutsideDirs => "a symlink leads outside the allowed directories",
                error.NotFound => try std.fmt.allocPrint(arena, "no such file or directory: '{s}'. Absolute paths start with '/'; other paths are relative to {s}", .{ path, if (s.dirs.len > 0) s.dirs[0] else "/" }),
                error.BadPath => "invalid path",
                error.OutOfMemory => return error.OutOfMemory,
            });
            const d = policy.classifyRead(s, norm);
            var reason: []const u8 = "";
            var how: []const u8 = "auto";
            switch (d) {
                .deny => |r| return denied(arena, r),
                .ask => |r| {
                    reason = r;
                    if (!ask(e, st, try std.fmt.allocPrint(arena, "ALLOW {s} of {s}? ({s})", .{ call.name, norm, r }))) return .{ .text = "DENIED: the user declined", .decision = "declined", .reason = r };
                    how = "approved";
                },
                .auto => {},
            }
            try e.out.print("  [{s}] {s}  ({s})\n", .{ call.name, norm, how });
            try busy(e, if (tool == .list_dir) "listing the folder" else "reading the file (PDFs and OCR can take a while)");
            defer activity.clear();
            const text = if (tool == .list_dir)
                tools.listDir(arena, e.io, norm, 400) catch |er| return denied(arena, @errorName(er))
            else
                tools.readFile(arena, e.io, norm, getInt(args, "offset") orelse 0, getInt(args, "limit") orelse 16384, @as(u64, s.max_output_kb) * 1024) catch |er| return denied(arena, @errorName(er));
            return .{ .text = text, .decision = how, .reason = reason };
        },
        .run_command => {
            const line = getStr(args, "command") orelse return denied(arena, "missing 'command'");
            const argv = policy.splitCommand(arena, line) catch |er| return denied(arena, switch (er) {
                error.ShellSyntax => "shell syntax (pipes, redirects, &&, ;, wildcards, ~, $) is not supported: give one plain command per call",
                error.UnbalancedQuote => "unbalanced quote",
                error.Empty => "empty command",
                error.OutOfMemory => return error.OutOfMemory,
            });
            const c = try policy.classifyCommand(arena, s, argv);
            const shown = try shellQuote(arena, argv);
            var how: []const u8 = "auto";
            var reason: []const u8 = c.kind;
            switch (c.decision) {
                .deny => |r| {
                    try e.out.print("  [run_command] {s}  (denied: {s})\n", .{ shown, r });
                    return denied(arena, r);
                },
                .ask => |r| {
                    reason = r;
                    if (!ask(e, st, try std.fmt.allocPrint(arena, "RUN {s}: {s}   ({s})", .{ c.kind, shown, r }))) return .{ .text = "DENIED: the user declined", .decision = "declined", .reason = r };
                    how = "approved";
                },
                .auto => {},
            }
            // Network commands (gh) were approved by the user and cannot work in the network-less sandbox.
            const sb = sandbox_on and c.needs != .network;
            try e.out.print("  [run_command] {s}  ({s}{s})\n", .{ shown, how, if (sb) ", sandboxed" else if (c.needs == .network) ", network" else "" });
            const extra_ro: []const []const u8 = if (c.needs == .pkgdb) try tools.pkgDbDirs(arena, e.io) else &.{};
            try busy(e, "running the command");
            const r = tools.runCommandWith(arena, e.gpa, e.io, s, argv, sb, extra_ro) catch |er| {
                activity.clear();
                return er;
            };
            activity.clear();
            return .{ .text = r.text, .decision = how, .reason = reason };
        },
        .search_files => {
            const query = getStr(args, "query") orelse return denied(arena, "missing 'query'");
            if (query.len == 0 or query.len > 500) return denied(arena, "query must be 1-500 characters");
            const where = getStr(args, "path") orelse (if (s.dirs.len > 0) s.dirs[0] else "/");
            const norm = tools.resolve(arena, e.io, s, where, true) catch |er| return denied(arena, resolveText(er));
            switch (policy.classifyRead(s, norm)) {
                .deny => |r| return denied(arena, r),
                .ask => |r| if (!ask(e, st, try std.fmt.allocPrint(arena, "ALLOW searching {s}? ({s})", .{ norm, r }))) return .{ .text = "DENIED: the user declined", .decision = "declined", .reason = r },
                .auto => {},
            }
            const ic = if (args.get("ignore_case")) |v| (v == .bool and v.bool) else false;
            try e.out.print("  [search_files] \"{s}\" in {s}  (auto)\n", .{ query, norm });
            try busy(e, "searching text files");
            const text = tools.searchFiles(arena, e.io, norm, query, ic, .{}) catch |er| {
                activity.clear();
                return denied(arena, @errorName(er));
            };
            activity.clear();
            return .{ .text = text, .decision = "auto", .reason = "" };
        },
        .edit_file => {
            const path = getStr(args, "path") orelse return denied(arena, "missing 'path'");
            if (std.mem.endsWith(u8, path, ".ipynb")) return denied(arena, "notebooks are JSON with outputs: use edit_notebook_cell so stale outputs are cleared and the structure stays valid");

            const old = getStr(args, "old_text") orelse return denied(arena, "missing 'old_text'");
            const new = getStr(args, "new_text") orelse return denied(arena, "missing 'new_text'");
            const replace_all = if (args.get("replace_all")) |v| (v == .bool and v.bool) else false;
            const norm = tools.resolve(arena, e.io, s, path, true) catch |er| return denied(arena, resolveText(er));
            switch (policy.classifyWrite(s, norm)) {
                .deny => |r| return denied(arena, r),
                .auto => unreachable,
                .ask => {},
            }
            const content = std.Io.Dir.cwd().readFileAlloc(e.io, norm, arena, .limited(2 << 20)) catch return denied(arena, "cannot read the file (missing, too large, or not a regular file)");
            const edit = tools.applyEdit(arena, content, old, new, replace_all) catch |er| return denied(arena, switch (er) {
                error.EmptyOldText => "old_text is empty",
                error.NotFound => "old_text was not found in the file; read the file again and copy the text exactly",
                error.Ambiguous => "old_text matches more than once; include more surrounding text or set replace_all",
                error.OutOfMemory => return error.OutOfMemory,
            });
            const preview = try tools.previewEdit(arena, old, new);
            try e.out.print("\n  --- EDIT {s} ({d} replacement(s)){s}\n", .{ norm, edit.count, preview });
            if (!ask(e, st, try std.fmt.allocPrint(arena, "APPLY this edit to {s}?", .{norm}))) return .{ .text = "DENIED: the user declined", .decision = "declined", .reason = "edit" };
            tools.writeFile(e.io, norm, edit.content) catch |er| return denied(arena, @errorName(er));
            try e.out.print("  [edit_file] changed {s}\n", .{norm});
            return .{ .text = try std.fmt.allocPrint(arena, "edited {s}: {d} replacement(s)", .{ norm, edit.count }), .decision = "approved", .reason = "edit" };
        },
        .move_file => {
            const from = getStr(args, "from") orelse return denied(arena, "missing 'from'");
            const to = getStr(args, "to") orelse return denied(arena, "missing 'to'");
            const nf = tools.resolve(arena, e.io, s, from, true) catch |er| return denied(arena, resolveText(er));
            const nt = tools.resolve(arena, e.io, s, to, false) catch |er| return denied(arena, resolveText(er));
            for ([_][]const u8{ nf, nt }) |p| switch (policy.classifyWrite(s, p)) {
                .deny => |r| return denied(arena, r),
                .auto => unreachable,
                .ask => {},
            };
            try e.out.print("\n  --- MOVE {s}\n          -> {s}\n", .{ nf, nt });
            if (!ask(e, st, try std.fmt.allocPrint(arena, "MOVE {s} to {s}?", .{ nf, nt }))) return .{ .text = "DENIED: the user declined", .decision = "declined", .reason = "move" };
            tools.movePath(e.io, nf, nt) catch |er| return denied(arena, switch (er) {
                error.DestinationExists => "the destination already exists (nothing is overwritten)",
                error.SourceMissing => "the source does not exist",
                error.Failed => "the move failed (different filesystem or permissions)",
            });
            return .{ .text = try std.fmt.allocPrint(arena, "moved {s} to {s}", .{ nf, nt }), .decision = "approved", .reason = "move" };
        },
        .make_dir => {
            const path = getStr(args, "path") orelse return denied(arena, "missing 'path'");
            const base = if (s.dirs.len > 0) s.dirs[0] else "/";
            const norm = policy.normalizePath(arena, base, path) catch return error.OutOfMemory;
            switch (policy.classifyWrite(s, norm)) {
                .deny => |r| return denied(arena, r),
                .auto => unreachable,
                .ask => {},
            }
            if (tools.pathExists(e.io, norm)) return denied(arena, "that path already exists");
            try e.out.print("\n  --- MKDIR {s}\n", .{norm});
            if (!ask(e, st, try std.fmt.allocPrint(arena, "CREATE directory {s}?", .{norm}))) return .{ .text = "DENIED: the user declined", .decision = "declined", .reason = "mkdir" };
            tools.makeDir(e.io, norm) catch |er| return denied(arena, @errorName(er));
            return .{ .text = try std.fmt.allocPrint(arena, "created {s}", .{norm}), .decision = "approved", .reason = "mkdir" };
        },
        .delete_file => {
            const path = getStr(args, "path") orelse return denied(arena, "missing 'path'");
            const norm = tools.resolve(arena, e.io, s, path, true) catch |er| return denied(arena, resolveText(er));
            switch (policy.classifyWrite(s, norm)) {
                .deny => |r| return denied(arena, r),
                .auto => unreachable,
                .ask => {},
            }
            try e.out.print("\n  --- DELETE {s}\n", .{norm});
            if (!ask(e, st, try std.fmt.allocPrint(arena, "PERMANENTLY DELETE {s}?", .{norm}))) return .{ .text = "DENIED: the user declined", .decision = "declined", .reason = "delete" };
            const size = tools.deleteFile(e.io, norm) catch |er| return denied(arena, switch (er) {
                error.NotAFile => "only regular files can be deleted (not directories or links)",
                error.Missing => "no such file",
                error.Failed => "the delete failed",
            });
            return .{ .text = try std.fmt.allocPrint(arena, "deleted {s} ({d} bytes)", .{ norm, size }), .decision = "approved", .reason = "delete" };
        },
        .write_file => {
            const path = getStr(args, "path") orelse return denied(arena, "missing 'path'");
            if (std.mem.endsWith(u8, path, ".ipynb")) return denied(arena, "notebooks are JSON with outputs: use edit_notebook_cell so stale outputs are cleared and the structure stays valid");

            const content = getStr(args, "content") orelse return denied(arena, "missing 'content'");
            if (content.len > 1 << 20) return denied(arena, "content is larger than 1 MiB");
            const norm = tools.resolve(arena, e.io, s, path, false) catch |er| return denied(arena, switch (er) {
                error.OutsideDirs => "a symlink leads outside the allowed directories",
                error.NotFound => "the parent directory does not exist",
                error.BadPath => "invalid path",
                error.OutOfMemory => return error.OutOfMemory,
            });
            switch (policy.classifyWrite(s, norm)) {
                .deny => |r| return denied(arena, r),
                .auto => unreachable,
                .ask => |r| {
                    const exists = if (std.Io.Dir.cwd().access(e.io, norm, .{})) |_| true else |_| false;
                    var preview: std.ArrayList(u8) = .empty;
                    var lines = std.mem.splitScalar(u8, content, '\n');
                    var n: usize = 0;
                    while (lines.next()) |l| : (n += 1) {
                        if (n >= 12) {
                            try preview.appendSlice(arena, "\n    ...");
                            break;
                        }
                        try preview.print(arena, "\n    + {s}", .{l[0..@min(l.len, 100)]});
                    }
                    try e.out.print("\n  --- {s} {s} ({d} bytes){s}\n", .{ if (exists) "OVERWRITE" else "CREATE", norm, content.len, preview.items });
                    if (!ask(e, st, try std.fmt.allocPrint(arena, "WRITE {s}? ({s})", .{ norm, r }))) return .{ .text = "DENIED: the user declined", .decision = "declined", .reason = r };
                },
            }
            tools.writeFile(e.io, norm, content) catch |er| return denied(arena, @errorName(er));
            try e.out.print("  [write_file] wrote {d} bytes to {s}\n", .{ content.len, norm });
            return .{ .text = try std.fmt.allocPrint(arena, "wrote {d} bytes to {s}", .{ content.len, norm }), .decision = "approved", .reason = "write" };
        },
    }
}

test "shellQuote shows exactly what will run" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectEqualStrings("grep -rn 'two words' ./x", try shellQuote(a.allocator(), &.{ "grep", "-rn", "two words", "./x" }));
}
