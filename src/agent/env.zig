//! Shared types for agent sessions: the single stdin reader, the environment, session state and the audit log.
const std = @import("std");
const platform = @import("../platform.zig");
const chat = @import("chat.zig");
const mcp = @import("../mcp.zig");
const process = std.process;

/// One stdin reader shared by the prompt and all approvals (two buffered readers would lose input).
pub const Input = struct {
    reader: std.Io.File.Reader,
    buf: [4096]u8 = undefined,
    /// Unattended runs: there is no one to type, every read ends the input.
    closed: bool = false,

    pub fn init(self: *Input, io: std.Io) void {
        self.reader = std.Io.File.stdin().reader(io, &self.buf);
    }

    /// Next line without the newline; null at end of input.
    pub fn line(self: *Input) ?[]const u8 {
        if (self.closed) return null;
        const l = self.reader.interface.takeDelimiter('\n') catch return null;
        return std.mem.trim(u8, l orelse return null, "\r");
    }
};

pub const Env = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    input: *Input,
    /// Where the JSON-lines audit log goes (null = no log).
    audit_path: ?[]const u8,
    /// Server address, e.g. "127.0.0.1:11434" (ollama) or "127.0.0.1:9931" (llama-server).
    host_port: []const u8,
    api: chat.Api = .ollama,
    /// Model id being used (for the audit log and sub-agents).
    model: []const u8 = "",
    /// PATH and HOME of the aimgr process, used to find the user's shell (dksh may live in ~/.local/bin).
    path_env: ?[]const u8 = null,
    home: ?[]const u8 = null,
    /// Directory of user-written skill files (*.md), if it exists.
    skills_dir: ?[]const u8 = null,
    /// Where background task logs go ($XDG_STATE_HOME/aimgr/agent-bg).
    state_dir: ?[]const u8 = null,
    /// MCP servers from mcp.toml (user-chosen programs; tools need approval unless listed read-only).
    mcp: []const mcp.Server = &.{},
};

pub const Audit = struct {
    io: std.Io,
    file: ?std.Io.File = null,
    pos: u64 = 0,

    pub fn open(io: std.Io, path: ?[]const u8) Audit {
        var a: Audit = .{ .io = io };
        const p = path orelse return a;
        if (std.fs.path.dirname(p)) |d| std.Io.Dir.cwd().createDirPath(io, d) catch {};
        a.file = std.Io.Dir.cwd().createFile(io, p, .{ .truncate = false }) catch null;
        if (a.file) |f| a.pos = f.length(io) catch 0;
        return a;
    }

    pub fn close(self: *Audit) void {
        if (self.file) |f| f.close(self.io);
    }

    pub fn record(self: *Audit, arena: std.mem.Allocator, model: []const u8, tool: []const u8, args: []const u8, decision: []const u8, reason: []const u8, result_bytes: usize) void {
        const f = self.file orelse return;
        var aw: std.Io.Writer.Allocating = .init(arena);
        var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
        s.beginObject() catch return;
        const fields = .{
            .{ "t", self.io.vtable.now(self.io.userdata, .real).toSeconds() },
            .{ "model", model },
            .{ "tool", tool },
            .{ "args", args[0..@min(args.len, 2000)] },
            .{ "decision", decision },
            .{ "reason", reason },
            .{ "result_bytes", result_bytes },
        };
        inline for (fields) |kv| {
            s.objectField(kv[0]) catch return;
            s.write(kv[1]) catch return;
        }
        s.endObject() catch return;
        aw.writer.writeByte('\n') catch return;
        const data = aw.written();
        f.writePositionalAll(self.io, data, self.pos) catch return;
        self.pos += data.len;
    }
};

/// A background task started by run_background (owned by the session; stopped when it ends).
pub const Bg = struct {
    id: u32,
    pid: platform.Pid,
    log_path: []const u8,
    command: []const u8,
    child: process.Child,
    exit_code: ?u8 = null,
    reaped: bool = false,
};

/// The active git worktree (all strings owned by the gpa).
pub const Worktree = struct {
    path: []const u8,
    branch: []const u8,
    toplevel: []const u8,
};

pub const Todo = struct {
    text: []const u8,
    status: enum { pending, in_progress, done },
};

/// Mutable state of one conversation (shared with tool handlers). Strings live in the session arena.
pub const State = struct {
    /// MCP tools found at the start of the session (null = not asked yet) and their function schemas.
    mcp_tools: ?[]const mcp.Tool = null,
    mcp_schemas: []const []const u8 = &.{},
    todos: std.ArrayList(Todo) = .empty,
    /// Plan mode: only read tools and submit_plan are offered until the user approves a plan.
    plan_mode: bool = false,
    /// 0 = the session itself, 1 = a sub-agent. Sub-agents cannot spawn further agents.
    depth: u8 = 0,
    /// ask_user calls in the current request (capped).
    questions: u32 = 0,
    /// Directory with user-written skill files (*.md), if any.
    skills_dir: ?[]const u8 = null,
    /// Label shown on approval prompts that come from a sub-agent ("" for the main session).
    actor: []const u8 = "",
    /// Sub-agents started during the current request (capped).
    spawned: u32 = 0,
    /// The session's audit log (shared with sub-agents).
    audit: ?*Audit = null,
    bg: std.ArrayList(Bg) = .empty,
    next_bg: u32 = 1,
    worktree: ?Worktree = null,
    /// Set for the duration of one tool call when one of the user's allow rules matched: the approval
    /// prompt is then answered "yes" automatically (and says which rule did it).
    rule_allow: ?[]const u8 = null,
    /// A scheduled run: nobody can approve or answer, so anything that needs a person is denied.
    unattended: bool = false,
};
