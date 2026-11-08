//! Background jobs (transfers and servers) for the TUI. Each job is a child
//! process in its own process group (so Ctrl-C at the terminal reaches aimgr,
//! not the job) whose stdout/stderr go to a log file. The UI polls: no threads,
//! so it stays responsive during long downloads.
const std = @import("std");
const platform = @import("../platform.zig");
const backend = @import("../backend.zig");
const netstat = @import("../netstat.zig");
const progress_mod = @import("../progress.zig");

pub const Kind = enum { pull, update, remove, server, abliterate, setup, search, refresh };
pub const State = enum { running, stopping, done, failed, cancelled };

pub const Job = struct {
    id: u32,
    kind: Kind,
    backend: backend.Kind,
    /// Exact model id ("" for an ollama daemon).
    model: []const u8,
    argv: []const []const u8,
    log_path: []const u8,
    pid: platform.Pid,
    state: State = .running,
    exit_code: ?u8 = null,
    /// Server jobs: port to watch, and whether it was observed listening.
    port: ?u16 = null,
    listening: bool = false,
    /// Last meaningful line of the log, sanitized.
    last_line: []const u8 = "",
    term_sent_tick: ?u64 = null,
    /// Set once the UI has consumed this job's result (search results).
    handled: bool = false,
    /// Parsed from the log: ollama pull layers, aimgr-progress lines (llama), or stage markers.
    progress: ?progress_mod.Progress = null,
    /// Incremental ollama-pull parser state and how much of the log it has consumed.
    tracker: progress_mod.PullTracker = .{},
    log_pos: u64 = 0,
    child: std.process.Child,

    pub fn isActive(self: Job) bool {
        return self.state == .running or self.state == .stopping;
    }
};

pub const Jobs = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    list: std.ArrayList(Job) = .empty,
    next_id: u32 = 1,
    tick: u64 = 0,

    pub fn deinit(self: *Jobs) void {
        for (self.list.items) |*j| {
            self.gpa.free(j.model);
            self.gpa.free(j.log_path);
            self.gpa.free(j.last_line);
            j.tracker.deinit(self.gpa);
            for (j.argv) |a| self.gpa.free(a);
            self.gpa.free(j.argv);
        }
        self.list.deinit(self.gpa);
    }

    pub fn activeCount(self: *const Jobs) usize {
        var n: usize = 0;
        for (self.list.items) |j| if (j.isActive()) {
            n += 1;
        };
        return n;
    }

    /// Start a job. `argv` is copied. Returns a human error text on failure (arena-free, static or gpa-owned by caller).
    pub fn start(
        self: *Jobs,
        kind: Kind,
        be: backend.Kind,
        model: []const u8,
        argv: []const []const u8,
        env: *const std.process.Environ.Map,
        log_dir: ?[]const u8,
        port: ?u16,
    ) ![]const u8 {
        const id = self.next_id;
        var sink: std.process.SpawnOptions.StdIo = .ignore;
        const log_path = if (log_dir) |d| blk: {
            std.Io.Dir.cwd().createDirPath(self.io, d) catch {};
            break :blk try std.fmt.allocPrint(self.gpa, "{s}/job-{d}-{s}.log", .{ d, id, @tagName(kind) });
        } else try self.gpa.dupe(u8, "(no log)");
        errdefer self.gpa.free(log_path);
        var file: ?std.Io.File = null;
        if (log_dir != null) {
            file = std.Io.Dir.cwd().createFile(self.io, log_path, .{ .truncate = true }) catch null;
            if (file) |f| sink = .{ .file = f };
        }
        defer if (file) |f| f.close(self.io);

        const child = std.process.spawn(self.io, .{
            .argv = argv,
            .environ_map = env,
            .stdin = .ignore,
            .stdout = sink,
            .stderr = sink,
            .pgid = if (platform.is_windows) null else 0, // own process group: terminal Ctrl-C must not hit jobs directly
        }) catch |err| return switch (err) {
            error.FileNotFound => "executable not found",
            else => "could not start process",
        };

        var copy = try self.gpa.alloc([]const u8, argv.len);
        var n: usize = 0;
        errdefer {
            for (copy[0..n]) |a| self.gpa.free(a);
            self.gpa.free(copy);
        }
        for (argv) |a| {
            copy[n] = try self.gpa.dupe(u8, a);
            n += 1;
        }
        const model_copy = try self.gpa.dupe(u8, model);
        errdefer self.gpa.free(model_copy);
        try self.list.append(self.gpa, .{
            .id = id,
            .kind = kind,
            .backend = be,
            .model = model_copy,
            .argv = copy,
            .log_path = log_path,
            .pid = child.id.?,
            .port = port,
            .last_line = try self.gpa.dupe(u8, ""),
            .child = child,
        });
        self.next_id += 1;
        return "";
    }

    /// Advance all jobs; returns true if any job changed state (UI should refresh inventory).
    pub fn poll(self: *Jobs) bool {
        self.tick += 1;
        var finished = false;
        for (self.list.items) |*j| {
            if (!j.isActive()) continue;
            if (self.tick % 5 == 0) {
                self.refreshTail(j);
                self.refreshProgress(j);
            }
            if (j.kind == .server and !j.listening and self.tick % 5 == 0) {
                if (j.port) |p| j.listening = netstat.isListening(self.gpa, self.io, p);
            }
            if (alive(self.gpa, self.io, j.pid)) continue;
            self.refreshTail(j);
            self.refreshProgress(j);
            const term = j.child.wait(self.io) catch {
                j.state = .failed;
                finished = true;
                continue;
            };
            switch (term) {
                .exited => |c| {
                    j.exit_code = c;
                    j.state = if (j.state == .stopping) .cancelled else if (c == 0) .done else .failed;
                    if (j.state == .done) if (j.progress) |*pr| {
                        if (pr.total > 0) pr.done = pr.total; // the job finished: show a full bar
                    };
                },
                else => j.state = if (j.state == .stopping) .cancelled else .failed,
            }
            finished = true;
        }
        return finished;
    }

    /// First call: SIGTERM. Second call while still alive returns true meaning
    /// "needs SIGKILL approval" (caller asks the user, then calls kill()).
    pub fn stop(self: *Jobs, j: *Job) bool {
        if (!j.isActive()) return false;
        if (j.state == .running) {
            platform.terminate(j.pid);
            j.state = .stopping;
            j.term_sent_tick = self.tick;
            return false;
        }
        return true;
    }

    pub fn kill(_: *Jobs, j: *Job) void {
        platform.killHard(j.pid);
    }

    fn refreshProgress(self: *Jobs, j: *Job) void {
        if (std.mem.eql(u8, j.log_path, "(no log)")) return;
        switch (j.kind) {
            .pull, .update => if (j.backend == .ollama) {
                var buf: [64 * 1024]u8 = undefined;
                const n = readFrom(self.io, j.log_path, j.log_pos, &buf) catch return;
                if (n == 0) return;
                j.log_pos += n;
                j.tracker.feed(self.gpa, buf[0..n]) catch return;
                if (j.tracker.progress()) |pr| j.progress = pr;
            } else {
                const text = readTail(self.gpa, self.io, j.log_path) catch return;
                defer self.gpa.free(text);
                if (progress_mod.parseAimgrProgress(text)) |pr| j.progress = pr;
            },
            .abliterate, .setup => {
                const text = readTail(self.gpa, self.io, j.log_path) catch return;
                defer self.gpa.free(text);
                if (progress_mod.parseStages(text)) |pr| j.progress = pr;
            },
            else => {},
        }
    }

    /// Sanitized last line of the job log (handles \r progress and ANSI escapes).
    fn refreshTail(self: *Jobs, j: *Job) void {
        if (std.mem.eql(u8, j.log_path, "(no log)")) return;
        const text = readTail(self.gpa, self.io, j.log_path) catch return;
        defer self.gpa.free(text);
        const line = lastLine(self.gpa, text) catch return;
        self.gpa.free(j.last_line);
        j.last_line = line;
    }
};

fn alive(gpa: std.mem.Allocator, io: std.Io, pid: platform.Pid) bool {
    return platform.alive(gpa, io, pid);
}

fn readFrom(io: std.Io, path: []const u8, pos: u64, buf: []u8) !usize {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const len = try f.length(io);
    if (pos >= len) return 0;
    const want: usize = @intCast(@min(len - pos, buf.len));
    return f.readPositionalAll(io, buf[0..want], pos);
}

fn readTail(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const len = try f.length(io);
    const want: u64 = 16384;
    const start = if (len > want) len - want else 0;
    const buf = try gpa.alloc(u8, @intCast(@min(len, want)));
    errdefer gpa.free(buf);
    const n = try f.readPositionalAll(io, buf, start);
    return gpa.realloc(buf, n);
}

/// Last non-empty segment split on \n or \r, with ANSI escape sequences and
/// control characters removed. Caller owns the result.
pub fn lastLine(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var cleaned: std.ArrayList(u8) = .empty;
    defer cleaned.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const b = text[i];
        if (b == 0x1b) { // CSI: ESC [ params final(@-~)
            if (i + 1 < text.len and text[i + 1] == '[') {
                i += 2;
                while (i < text.len and !(text[i] >= 0x40 and text[i] <= 0x7e)) i += 1;
            }
            continue;
        }
        // Block-element glyphs (U+2580-U+259F, e.g. ollama's own "▕███▏" bar) are dropped: the
        // Transfers tab draws a real bar, and a clipped multi-byte glyph would show as garbage.
        if (b == 0xE2 and i + 2 < text.len and text[i + 1] == 0x96 and text[i + 2] >= 0x80 and text[i + 2] <= 0x9F) {
            i += 2;
            continue;
        }
        if (b == '\n' or b == '\r') {
            try cleaned.append(gpa, '\n');
        } else if (b >= 0x20 and b != 0x7f) {
            try cleaned.append(gpa, b);
        }
    }
    var it = std.mem.splitBackwardsScalar(u8, cleaned.items, '\n');
    while (it.next()) |seg| {
        const t = std.mem.trim(u8, seg, " ");
        if (t.len > 0) return gpa.dupe(u8, t);
    }
    return gpa.dupe(u8, "");
}

test "lastLine strips ansi and takes the last carriage-return segment" {
    const l = try lastLine(std.testing.allocator, "pulling manifest\n\x1b[2K\rpulling abc 12%\r\x1b[2K\rpulling abc 57% \x1b[1m|\x1b[0m\n");
    defer std.testing.allocator.free(l);
    try std.testing.expectEqualStrings("pulling abc 57% |", l);
}

test "lastLine empty" {
    const l = try lastLine(std.testing.allocator, "\n\n  \n");
    defer std.testing.allocator.free(l);
    try std.testing.expectEqualStrings("", l);
}

test "lastLine drops block-element bar glyphs" {
    const l = try lastLine(std.testing.allocator, "pulling abc:  48% \xe2\x96\x95\xe2\x96\x88\xe2\x96\x88   \xe2\x96\x8f 1.2 GB/2.5 GB  30 MB/s\n");
    defer std.testing.allocator.free(l);
    try std.testing.expectEqualStrings("pulling abc:  48%     1.2 GB/2.5 GB  30 MB/s", l);
}
