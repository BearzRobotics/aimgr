//! Tool schemas offered to the model, and the executors. Executors never decide permission
//! (policy.zig does) but enforce hard limits: output size, file size, timeouts, symlink-safe paths.
const std = @import("std");
const policy = @import("policy.zig");
const process = @import("process_shim.zig");

pub const Tool = enum { list_dir, read_file, search_files, run_command, write_file, edit_file, move_file, make_dir, delete_file };

const schema_list_dir =
    \\{"type":"function","function":{"name":"list_dir","description":"List the entries of a directory with type and size.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Directory path (absolute, or relative to the first allowed directory)"}},"required":["path"]}}}
;
const schema_read_file =
    \\{"type":"function","function":{"name":"read_file","description":"Read a text file. Large files are returned in pieces; use offset and limit (bytes) to continue.","parameters":{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer","description":"Byte offset to start at (default 0)"},"limit":{"type":"integer","description":"Max bytes to return (default 16384)"}},"required":["path"]}}}
;
const schema_run_command =
    \\{"type":"function","function":{"name":"run_command","description":"Run ONE command and return its output. There is no shell: no pipes, redirects, &&, ;, wildcards, ~ or $ expansion. Quote arguments with spaces. Example: grep -rn lion /stuff/Books/Animals","parameters":{"type":"object","properties":{"command":{"type":"string","description":"A single command line"}},"required":["command"]}}}
;
const schema_write_file =
    \\{"type":"function","function":{"name":"write_file","description":"Create or overwrite a text file. The user is asked to approve every write.","parameters":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}}}
;

const schema_search_files =
    \\{"type":"function","function":{"name":"search_files","description":"Search the text files under a directory for a literal string (not a regex). Returns path:line: text for each match.","parameters":{"type":"object","properties":{"query":{"type":"string","description":"Text to find"},"path":{"type":"string","description":"Directory to search (default: the first allowed directory)"},"ignore_case":{"type":"boolean"}},"required":["query"]}}}
;
const schema_edit_file =
    \\{"type":"function","function":{"name":"edit_file","description":"Replace exact text in an existing file. old_text must match exactly once (unless replace_all is true). The user is asked to approve every edit. Prefer this over rewriting a whole file.","parameters":{"type":"object","properties":{"path":{"type":"string"},"old_text":{"type":"string","description":"Exact text to replace, including whitespace"},"new_text":{"type":"string"},"replace_all":{"type":"boolean"}},"required":["path","old_text","new_text"]}}}
;
const schema_move_file =
    \\{"type":"function","function":{"name":"move_file","description":"Move or rename a file or directory inside the allowed directories. Refuses to overwrite an existing destination. The user is asked to approve every move.","parameters":{"type":"object","properties":{"from":{"type":"string"},"to":{"type":"string"}},"required":["from","to"]}}}
;
const schema_make_dir =
    \\{"type":"function","function":{"name":"make_dir","description":"Create a directory (and missing parents) inside the allowed directories. The user is asked to approve it.","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}}
;
const schema_delete_file =
    \\{"type":"function","function":{"name":"delete_file","description":"Delete one regular file (never a directory) inside the allowed directories. The user is asked to approve every deletion.","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}}
;

/// JSON array of the tools this level may use (the model is only told about these).
pub fn schemasFor(arena: std.mem.Allocator, level: policy.Level) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '[');
    var first = true;
    const add = struct {
        fn f(o: *std.ArrayList(u8), a: std.mem.Allocator, fst: *bool, s: []const u8) !void {
            if (!fst.*) try o.append(a, ',');
            fst.* = false;
            try o.appendSlice(a, s);
        }
    }.f;
    if (level.atLeast(.read_only)) {
        try add(&out, arena, &first, schema_list_dir);
        try add(&out, arena, &first, schema_read_file);
        try add(&out, arena, &first, schema_search_files);
    }
    if (level.atLeast(.inspect)) try add(&out, arena, &first, schema_run_command);
    if (level == .ask) {
        try add(&out, arena, &first, schema_write_file);
        try add(&out, arena, &first, schema_edit_file);
        try add(&out, arena, &first, schema_move_file);
        try add(&out, arena, &first, schema_make_dir);
        try add(&out, arena, &first, schema_delete_file);
    }
    try out.append(arena, ']');
    return out.toOwnedSlice(arena);
}

pub fn toolFromName(name: []const u8) ?Tool {
    return std.meta.stringToEnum(Tool, name);
}

/// Cut `text` to `max` bytes (on a UTF-8 boundary) and say so.
pub fn truncate(arena: std.mem.Allocator, text: []const u8, max: usize) ![]const u8 {
    if (text.len <= max) return text;
    var cut = max;
    while (cut > 0 and (text[cut] & 0xC0) == 0x80) cut -= 1;
    return std.fmt.allocPrint(arena, "{s}\n[... output truncated: showing {d} of {d} bytes ...]", .{ text[0..cut], cut, text.len });
}

pub const ResolveError = error{ OutsideDirs, NotFound, OutOfMemory, BadPath };

/// Normalize `path` (relative to dirs[0]) and, if it exists, resolve symlinks and check the real
/// location is still inside the allowed directories. Returns the path to use.
/// `must_exist=false` (writes): the parent directory is resolved instead.
pub fn resolve(arena: std.mem.Allocator, io: std.Io, s: policy.Settings, path: []const u8, must_exist: bool) ResolveError![]const u8 {
    if (path.len == 0 or path.len > 4096 or std.mem.indexOfScalar(u8, path, 0) != null) return error.BadPath;
    const base = if (s.dirs.len > 0) s.dirs[0] else "/";
    const norm = policy.normalizePath(arena, base, path) catch return error.OutOfMemory;
    // The directories themselves may be symlinks; compare against their real locations too.
    var real_dirs: std.ArrayList([]const u8) = .empty;
    for (s.dirs) |d| {
        real_dirs.append(arena, d) catch return error.OutOfMemory;
        if (std.Io.Dir.cwd().realPathFileAlloc(io, d, arena)) |rd| real_dirs.append(arena, rd) catch return error.OutOfMemory else |_| {}
    }
    const target = if (must_exist) norm else (std.fs.path.dirname(norm) orelse "/");
    const real = std.Io.Dir.cwd().realPathFileAlloc(io, target, arena) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => if (must_exist) return error.NotFound else return error.NotFound,
    };
    // Policy decided on the lexical path; a symlink must not lead somewhere else.
    if (!policy.within(real_dirs.items, real) and policy.within(s.dirs, norm)) return error.OutsideDirs;
    return norm;
}

pub fn listDir(arena: std.mem.Allocator, io: std.Io, path: []const u8, max_entries: usize) ![]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    var total: usize = 0;
    while (try it.next(io)) |e| {
        total += 1;
        if (names.items.len >= max_entries) continue;
        const kind: []const u8 = switch (e.kind) {
            .directory => "dir",
            .file => "file",
            .sym_link => "symlink",
            else => "other",
        };
        var size: u64 = 0;
        if (e.kind == .file) {
            if (dir.openFile(io, e.name, .{})) |f| {
                defer f.close(io);
                size = f.length(io) catch 0;
            } else |_| {}
        }
        try names.append(arena, try std.fmt.allocPrint(arena, "{s}\t{s}\t{d}", .{ e.name, kind, size }));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "{s}: {d} entries (name, type, bytes)\n", .{ path, total });
    for (names.items) |n| try out.print(arena, "{s}\n", .{n});
    if (total > names.items.len) try out.print(arena, "[... {d} more entries not shown ...]\n", .{total - names.items.len});
    return out.toOwnedSlice(arena);
}

pub fn readFile(arena: std.mem.Allocator, io: std.Io, path: []const u8, offset: u64, limit: u64, hard_max: u64) ![]const u8 {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const len = try f.length(io);
    if (offset >= len and len > 0) return std.fmt.allocPrint(arena, "[offset {d} is past the end of the file ({d} bytes)]", .{ offset, len });
    const want: usize = @intCast(@min(@min(limit, hard_max), len - @min(offset, len)));
    const buf = try arena.alloc(u8, want);
    const n = try f.readPositionalAll(io, buf, offset);
    const data = buf[0..n];
    if (std.mem.indexOfScalar(u8, data[0..@min(data.len, 2048)], 0) != null) {
        return std.fmt.allocPrint(arena, "[binary file, {d} bytes; contents not shown]", .{len});
    }
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, data);
    if (offset + n < len) try out.print(arena, "\n[... file continues: {d} of {d} bytes shown; call read_file again with offset={d} ...]", .{ offset + n, len, offset + n });
    return out.toOwnedSlice(arena);
}

pub fn writeFile(io: std.Io, path: []const u8, content: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });
}

// ---- search / edit / move / mkdir / delete ----------------------------------------------------

pub const SearchLimits = struct { max_results: usize = 100, max_files: usize = 20000, max_depth: usize = 12, max_file_bytes: usize = 512 * 1024 };

/// Literal substring search (ASCII case folding when `ignore_case`). Skips symlinks, binary files and
/// files that look like they hold secrets. Returns "path:line: text" lines plus a summary.
pub fn searchFiles(arena: std.mem.Allocator, io: std.Io, root: []const u8, query: []const u8, ignore_case: bool, lim: SearchLimits) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var st: struct { results: usize = 0, files: usize = 0, skipped_binary: usize = 0, truncated: bool = false } = .{};
    try searchDir(arena, io, root, query, ignore_case, lim, 0, &out, &st);
    try out.print(arena, "[{d} match(es) in {d} file(s) searched{s}{s}]\n", .{ st.results, st.files, if (st.skipped_binary > 0) ", binary files skipped" else "", if (st.truncated) ", stopped at a limit; narrow the path or query" else "" });
    return out.toOwnedSlice(arena);
}

fn searchDir(arena: std.mem.Allocator, io: std.Io, dir_path: []const u8, query: []const u8, ic: bool, lim: SearchLimits, depth: usize, out: *std.ArrayList(u8), st: anytype) !void {
    if (depth > lim.max_depth or st.truncated) return;
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (st.truncated) return;
        if (e.name.len == 0 or e.name[0] == '.' and std.mem.eql(u8, e.name, ".git")) continue;
        const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ std.mem.trimEnd(u8, dir_path, "/"), e.name });
        switch (e.kind) {
            .directory => try searchDir(arena, io, full, query, ic, lim, depth + 1, out, st),
            .file => {
                if (policy.looksSensitive(full)) continue;
                if (st.files >= lim.max_files) {
                    st.truncated = true;
                    return;
                }
                st.files += 1;
                var f = dir.openFile(io, e.name, .{}) catch continue;
                defer f.close(io);
                const len = f.length(io) catch continue;
                const want: usize = @intCast(@min(len, lim.max_file_bytes));
                const buf = arena.alloc(u8, want) catch continue;
                const n = f.readPositionalAll(io, buf, 0) catch continue;
                const data = buf[0..n];
                if (std.mem.indexOfScalar(u8, data[0..@min(data.len, 2048)], 0) != null) {
                    st.skipped_binary += 1;
                    continue;
                }
                var lines = std.mem.splitScalar(u8, data, '\n');
                var ln: usize = 0;
                while (lines.next()) |line| {
                    ln += 1;
                    const hit = if (ic) std.ascii.findIgnoreCase(line, query) != null else std.mem.indexOf(u8, line, query) != null;
                    if (!hit) continue;
                    if (st.results >= lim.max_results) {
                        st.truncated = true;
                        return;
                    }
                    st.results += 1;
                    const shown = std.mem.trim(u8, line[0..@min(line.len, 200)], " \t\r");
                    try out.print(arena, "{s}:{d}: {s}\n", .{ full, ln, shown });
                }
            },
            else => {}, // symlinks and special files are not followed
        }
    }
}

pub const EditError = error{ EmptyOldText, NotFound, Ambiguous, OutOfMemory };

pub const EditResult = struct { content: []u8, count: usize };

/// Replace `old` with `new` in `content`. Without `replace_all` the match must be unique.
pub fn applyEdit(arena: std.mem.Allocator, content: []const u8, old: []const u8, new: []const u8, replace_all: bool) EditError!EditResult {
    if (old.len == 0) return error.EmptyOldText;
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, content, pos, old)) |i| : (pos = i + old.len) count += 1;
    if (count == 0) return error.NotFound;
    if (count > 1 and !replace_all) return error.Ambiguous;
    var out: std.ArrayList(u8) = .empty;
    var last: usize = 0;
    pos = 0;
    while (std.mem.indexOfPos(u8, content, pos, old)) |i| {
        try out.appendSlice(arena, content[last..i]);
        try out.appendSlice(arena, new);
        last = i + old.len;
        pos = last;
        if (!replace_all) break;
    }
    try out.appendSlice(arena, content[last..]);
    return .{ .content = try out.toOwnedSlice(arena), .count = if (replace_all) count else 1 };
}

/// "- old line" / "+ new line" preview shown to the user before an edit is approved.
pub fn previewEdit(arena: std.mem.Allocator, old: []const u8, new: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const max_lines = 12;
    inline for (.{ .{ old, "-" }, .{ new, "+" } }) |pair| {
        var it = std.mem.splitScalar(u8, pair[0], '\n');
        var n: usize = 0;
        while (it.next()) |l| : (n += 1) {
            if (n >= max_lines) {
                try out.print(arena, "\n    {s} ...", .{pair[1]});
                break;
            }
            try out.print(arena, "\n    {s} {s}", .{ pair[1], l[0..@min(l.len, 100)] });
        }
    }
    return out.toOwnedSlice(arena);
}

pub fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub const MoveError = error{ DestinationExists, SourceMissing, Failed };

/// Rename within one filesystem. Never overwrites.
pub fn movePath(io: std.Io, from: []const u8, to: []const u8) MoveError!void {
    if (!pathExists(io, from)) return error.SourceMissing;
    if (pathExists(io, to)) return error.DestinationExists;
    std.Io.Dir.rename(std.Io.Dir.cwd(), from, std.Io.Dir.cwd(), to, io) catch return error.Failed;
}

pub fn makeDir(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, path);
}

pub const DeleteError = error{ NotAFile, Missing, Failed };

/// Delete one regular file (not a directory, not through a symlink).
pub fn deleteFile(io: std.Io, path: []const u8) DeleteError!u64 {
    const st = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return error.Missing;
    if (st.kind != .file) return error.NotAFile;
    std.Io.Dir.cwd().deleteFile(io, path) catch return error.Failed;
    return st.size;
}

// ---- command execution ----------------------------------------------------------------------

/// True when `bwrap` can create the sandbox on this machine (it is installed AND user namespaces work).
pub fn sandboxAvailable(gpa: std.mem.Allocator, io: std.Io) bool {
    const r = process.run(gpa, io, &.{ "bwrap", "--ro-bind", "/", "/", "--unshare-all", "true" }, 5, null, 4096);
    defer r.deinit(gpa);
    return r.ok();
}

/// argv wrapped in bubblewrap: system dirs read-only, allowed dirs read-only (read-write at level ask),
/// no network, own PID/IPC/UTS namespaces, dies with the parent.
pub fn bwrapArgv(arena: std.mem.Allocator, s: policy.Settings, argv: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(arena, &.{ "bwrap", "--die-with-parent", "--unshare-all", "--new-session", "--ro-bind", "/usr", "/usr", "--ro-bind", "/etc", "/etc", "--symlink", "usr/bin", "/bin", "--symlink", "usr/sbin", "/sbin", "--symlink", "usr/lib", "/lib", "--symlink", "usr/lib64", "/lib64", "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp" });
    const mode: []const u8 = if (s.level == .ask) "--bind" else "--ro-bind";
    for (s.dirs) |d| try out.appendSlice(arena, &.{ mode, d, d });
    if (s.dirs.len > 0) try out.appendSlice(arena, &.{ "--chdir", s.dirs[0] });
    try out.append(arena, "--");
    try out.appendSlice(arena, argv);
    return out.toOwnedSlice(arena);
}

pub const CommandResult = struct {
    text: []const u8,
    ok: bool,
    sandboxed: bool,
};

pub fn runCommand(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, s: policy.Settings, argv: []const []const u8, use_sandbox: bool) !CommandResult {
    const wrapped = if (use_sandbox) try bwrapArgv(arena, s, argv) else argv;
    const cap: usize = @as(usize, s.max_output_kb) * 1024;
    const cwd: ?[]const u8 = if (use_sandbox) null else (if (s.dirs.len > 0) s.dirs[0] else null);
    const r = process.run(gpa, io, wrapped, s.timeout_s, cwd, cap + 4096);
    defer r.deinit(gpa);
    var out: std.ArrayList(u8) = .empty;
    switch (r.outcome) {
        .not_found => return .{ .text = "command not found", .ok = false, .sandboxed = use_sandbox },
        .spawn_failed => return .{ .text = "could not start the command", .ok = false, .sandboxed = use_sandbox },
        .timed_out => try out.print(arena, "[timed out after {d} s and was stopped]\n", .{s.timeout_s}),
        .output_too_large => try out.appendSlice(arena, "[output exceeded the limit and the command was stopped]\n"),
        .abnormal => try out.appendSlice(arena, "[terminated abnormally]\n"),
        .exited => |c| try out.print(arena, "[exit code {d}]\n", .{c}),
    }
    if (r.stdout.len > 0) try out.print(arena, "{s}", .{r.stdout});
    if (r.stderr.len > 0) try out.print(arena, "\n[stderr]\n{s}", .{r.stderr});
    return .{ .text = try truncate(arena, out.items, cap), .ok = r.ok(), .sandboxed = use_sandbox };
}

test "schemas follow the level" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const off = try schemasFor(a.allocator(), .off);
    try std.testing.expectEqualStrings("[]", off);
    const ro = try schemasFor(a.allocator(), .read_only);
    try std.testing.expect(std.mem.indexOf(u8, ro, "list_dir") != null and std.mem.indexOf(u8, ro, "run_command") == null);
    const ins = try schemasFor(a.allocator(), .inspect);
    try std.testing.expect(std.mem.indexOf(u8, ins, "run_command") != null and std.mem.indexOf(u8, ins, "write_file") == null);
    const ask = try schemasFor(a.allocator(), .ask);
    try std.testing.expect(std.mem.indexOf(u8, ask, "write_file") != null);
    // every schema must itself be valid JSON
    for ([_][]const u8{ ro, ins, ask }) |s| {
        const p = try std.json.parseFromSlice(std.json.Value, a.allocator(), s, .{});
        try std.testing.expect(p.value == .array);
    }
}

test "truncate keeps UTF-8 intact and reports it" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const t = try truncate(a.allocator(), "ab\xc3\xa9cd", 3); // cutting inside the 2-byte e-acute
    try std.testing.expect(std.mem.startsWith(u8, t, "ab\n[...") or std.mem.startsWith(u8, t, "ab\xc3\xa9"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(t));
    try std.testing.expectEqualStrings("short", try truncate(a.allocator(), "short", 100));
}

test "bwrap argv: dirs read-only below level ask, no network namespace shared" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const s: policy.Settings = .{ .level = .inspect, .dirs = &.{"/stuff/Books"} };
    const argv = try bwrapArgv(a.allocator(), s, &.{ "ls", "-la" });
    var saw_ro = false;
    var saw_share_net = false;
    for (argv, 0..) |x, i| {
        if (std.mem.eql(u8, x, "--ro-bind") and i + 2 < argv.len and std.mem.eql(u8, argv[i + 1], "/stuff/Books")) saw_ro = true;
        if (std.mem.eql(u8, x, "--share-net")) saw_share_net = true;
    }
    try std.testing.expect(saw_ro and !saw_share_net);
    try std.testing.expectEqualStrings("ls", argv[argv.len - 2]);
    const ask: policy.Settings = .{ .level = .ask, .dirs = &.{"/stuff/Books"} };
    const argv2 = try bwrapArgv(a.allocator(), ask, &.{"touch"});
    var saw_rw = false;
    for (argv2, 0..) |x, i| if (std.mem.eql(u8, x, "--bind") and std.mem.eql(u8, argv2[i + 1], "/stuff/Books")) {
        saw_rw = true;
    };
    try std.testing.expect(saw_rw);
}

test "applyEdit: unique match, ambiguity, replace_all, not found" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const r = try applyEdit(a.allocator(), "one two three", "two", "2", false);
    try std.testing.expectEqualStrings("one 2 three", r.content);
    try std.testing.expectError(error.Ambiguous, applyEdit(a.allocator(), "a b a", "a", "x", false));
    const all = try applyEdit(a.allocator(), "a b a", "a", "x", true);
    try std.testing.expectEqualStrings("x b x", all.content);
    try std.testing.expectEqual(@as(usize, 2), all.count);
    try std.testing.expectError(error.NotFound, applyEdit(a.allocator(), "abc", "zzz", "y", false));
    try std.testing.expectError(error.EmptyOldText, applyEdit(a.allocator(), "abc", "", "y", false));
    // multi-line and overlapping text
    const ml = try applyEdit(a.allocator(), "x\nfoo()\ny\n", "foo()\n", "bar()\n", false);
    try std.testing.expectEqualStrings("x\nbar()\ny\n", ml.content);
    try std.testing.expectError(error.Ambiguous, applyEdit(a.allocator(), "aaaa", "aa", "b", false)); // non-overlapping count = 2
}

test "previewEdit shows removed and added lines, capped" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const p = try previewEdit(a.allocator(), "old1\nold2", "new1");
    try std.testing.expect(std.mem.indexOf(u8, p, "- old1") != null and std.mem.indexOf(u8, p, "- old2") != null and std.mem.indexOf(u8, p, "+ new1") != null);
    var big: std.ArrayList(u8) = .empty;
    for (0..50) |_| try big.appendSlice(a.allocator(), "line\n");
    const capped = try previewEdit(a.allocator(), big.items, "x");
    try std.testing.expect(std.mem.indexOf(u8, capped, "...") != null);
}

test "schemas: new tools appear only at the right levels" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const ro = try schemasFor(a.allocator(), .read_only);
    try std.testing.expect(std.mem.indexOf(u8, ro, "search_files") != null);
    try std.testing.expect(std.mem.indexOf(u8, ro, "edit_file") == null and std.mem.indexOf(u8, ro, "delete_file") == null);
    const ins = try schemasFor(a.allocator(), .inspect);
    try std.testing.expect(std.mem.indexOf(u8, ins, "move_file") == null and std.mem.indexOf(u8, ins, "make_dir") == null);
    const ask = try schemasFor(a.allocator(), .ask);
    for ([_][]const u8{ "edit_file", "move_file", "make_dir", "delete_file", "write_file", "search_files" }) |n| try std.testing.expect(std.mem.indexOf(u8, ask, n) != null);
    const p = try std.json.parseFromSlice(std.json.Value, a.allocator(), ask, .{});
    try std.testing.expectEqual(@as(usize, 9), p.value.array.items.len);
}

test "file operations on a scratch directory: search, move, mkdir, delete" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a.allocator());
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "alpha\nBeta Needle\ngamma\n" });
    try tmp.dir.createDir(io, "sub", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/b.txt", .data = "no match here\nneedle again\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/bin.dat", .data = "needle\x00binary" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".env", .data = "needle=secret\n" });
    // case-insensitive search finds text files only (no binary, no secrets)
    const res = try searchFiles(a.allocator(), io, root, "NEEDLE", true, .{});
    try std.testing.expect(std.mem.indexOf(u8, res, "a.txt:2: Beta Needle") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "b.txt:2: needle again") != null);
    try std.testing.expect(std.mem.indexOf(u8, res, "bin.dat") == null and std.mem.indexOf(u8, res, ".env") == null);
    const cs = try searchFiles(a.allocator(), io, root, "Needle", false, .{});
    try std.testing.expect(std.mem.indexOf(u8, cs, "a.txt:2") != null and std.mem.indexOf(u8, cs, "b.txt") == null);
    // move never overwrites
    const from = try std.fmt.allocPrint(a.allocator(), "{s}/a.txt", .{root});
    const to = try std.fmt.allocPrint(a.allocator(), "{s}/sub/b.txt", .{root});
    try std.testing.expectError(error.DestinationExists, movePath(io, from, to));
    const to2 = try std.fmt.allocPrint(a.allocator(), "{s}/moved.txt", .{root});
    try movePath(io, from, to2);
    try std.testing.expect(!pathExists(io, from) and pathExists(io, to2));
    try std.testing.expectError(error.SourceMissing, movePath(io, from, to2));
    // mkdir creates parents
    const nd = try std.fmt.allocPrint(a.allocator(), "{s}/x/y/z", .{root});
    try makeDir(io, nd);
    try std.testing.expect(pathExists(io, nd));
    // delete: a file yes, a directory no
    try std.testing.expectEqual(@as(u64, 24), try deleteFile(io, to2));
    try std.testing.expectError(error.NotAFile, deleteFile(io, nd));
    try std.testing.expectError(error.Missing, deleteFile(io, to2));
}
