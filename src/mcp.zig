//! MCP (Model Context Protocol) client over stdio, kept deliberately small and stateless.
//!
//! Servers are listed by the user in mcp.toml (next to config.toml):
//!   [[mcp]]
//!   id = "files"                       # letters, digits, '_' and '-'
//!   command = ["python3", "/path/to/server.py"]
//!   read_only_tools = ["search"]       # optional: these never ask for approval; everything else does
//!
//! Each tool call starts the server, sends initialize + the request on its stdin (from a file), reads the
//! answer from stdout and lets the server exit. No long-lived child processes, every call has a timeout.
//! The server is a program the user chose to run; it is NOT sandboxed (its own access is its own business),
//! which is why every call needs approval unless the user listed the tool as read-only.
const std = @import("std");
const process = @import("process.zig");

pub const Server = struct {
    id: []const u8,
    command: []const []const u8,
    read_only_tools: []const []const u8 = &.{},
};

pub const Tool = struct {
    server: usize,
    name: []const u8,
    description: []const u8,
    /// JSON text of the tool's inputSchema.
    schema: []const u8,
};

pub const Error = error{ InvalidConfig, OutOfMemory };

fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 32) return false;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    return true;
}

pub fn parse(arena: std.mem.Allocator, gpa: std.mem.Allocator, text: []const u8) Error![]Server {
    const toml = @import("toml");
    var doc = toml.Document.parse(gpa, text, .{}, null) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidConfig,
    };
    defer doc.deinit();
    const v = doc.root.get("mcp") orelse return &.{};
    if (v != .array) return error.InvalidConfig;
    var out: std.ArrayList(Server) = .empty;
    for (v.array.items.items) |item| {
        if (item != .table) return error.InvalidConfig;
        const t = item.table;
        const id = t.getString("id") orelse return error.InvalidConfig;
        if (!validId(id)) return error.InvalidConfig;
        for (out.items) |o| if (std.mem.eql(u8, o.id, id)) return error.InvalidConfig;
        const cmd = try strList(arena, t, "command") orelse return error.InvalidConfig;
        if (cmd.len == 0 or cmd[0].len == 0) return error.InvalidConfig;
        const ro = try strList(arena, t, "read_only_tools") orelse &.{};
        try out.append(arena, .{ .id = try arena.dupe(u8, id), .command = cmd, .read_only_tools = ro });
    }
    return out.toOwnedSlice(arena);
}

fn strList(arena: std.mem.Allocator, t: anytype, key: []const u8) Error!?[]const []const u8 {
    const v = t.get(key) orelse return null;
    if (v != .array) return error.InvalidConfig;
    var out: std.ArrayList([]const u8) = .empty;
    for (v.array.items.items) |it| {
        if (it != .string) return error.InvalidConfig;
        try out.append(arena, try arena.dupe(u8, it.string));
    }
    return try out.toOwnedSlice(arena);
}

/// Servers from mcp.toml; absent or unreadable file => none (a broken file is reported by the caller).
pub fn load(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, path: []const u8) Error![]Server {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch return &.{};
    return parse(arena, gpa, text);
}

pub fn isReadOnly(s: Server, tool: []const u8) bool {
    for (s.read_only_tools) |t| if (std.mem.eql(u8, t, tool)) return true;
    return false;
}

/// "mcp__<server>__<tool>" -> its two parts (views into `name`).
pub fn splitName(name: []const u8) ?struct { server: []const u8, tool: []const u8 } {
    if (!std.mem.startsWith(u8, name, "mcp__")) return null;
    const rest = name[5..];
    const i = std.mem.indexOf(u8, rest, "__") orelse return null;
    if (i == 0 or i + 2 >= rest.len) return null;
    return .{ .server = rest[0..i], .tool = rest[i + 2 ..] };
}

const init_msgs =
    \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"aimgr","version":"0.1"}}}
    \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    \\
;

/// Run the server once with `request_line` (one JSON-RPC request with id 2) after the handshake and return
/// the `result` object's JSON text of the id-2 response.
fn exchange(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, tmp_dir: []const u8, srv: Server, request_line: []const u8, timeout_s: u32) ![]const u8 {
    try std.Io.Dir.cwd().createDirPath(io, tmp_dir);
    const inp = try std.fmt.allocPrint(arena, "{s}/mcp-in-{s}.jsonl", .{ tmp_dir, srv.id });
    const data = try std.fmt.allocPrint(arena, "{s}{s}\n", .{ init_msgs, request_line });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = inp, .data = data });
    defer std.Io.Dir.cwd().deleteFile(io, inp) catch {};
    // sh feeds the file to the server's stdin; the server's argv is passed as separate arguments (no quoting).
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "/bin/sh", "-c", "f=$1; shift; exec \"$@\" < \"$f\"", "sh", inp });
    try argv.appendSlice(arena, srv.command);
    const r = process.runIn(gpa, io, argv.items, timeout_s, null, 1024 * 1024);
    defer r.deinit(gpa);
    switch (r.outcome) {
        .not_found => return error.ServerNotFound,
        .spawn_failed => return error.ServerFailed,
        .timed_out => return error.Timeout,
        .output_too_large => return error.TooLarge,
        else => {},
    }
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    while (lines.next()) |l| {
        const t = std.mem.trim(u8, l, " \r\t");
        if (t.len == 0 or t[0] != '{') continue;
        const p = std.json.parseFromSlice(std.json.Value, arena, t, .{}) catch continue;
        if (p.value != .object) continue;
        const id = p.value.object.get("id") orelse continue;
        if (id != .integer or id.integer != 2) continue;
        if (p.value.object.get("error")) |e| {
            const msg = if (e == .object) (if (e.object.get("message")) |m| (if (m == .string) m.string else "error") else "error") else "error";
            return std.fmt.allocPrint(arena, "{{\"__error\":{f}}}", .{std.json.fmt(msg, .{})});
        }
        const res = p.value.object.get("result") orelse return error.BadReply;
        return std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(res, .{})});
    }
    return error.NoReply;
}

pub fn errorText(e: anyerror) []const u8 {
    return switch (e) {
        error.ServerNotFound => "the MCP server program was not found",
        error.ServerFailed => "the MCP server could not be started",
        error.Timeout => "the MCP server did not answer in time and was stopped",
        error.TooLarge => "the MCP server's output was too large",
        error.BadReply, error.NoReply => "the MCP server gave no usable answer",
        else => "the MCP call failed",
    };
}

/// Ask a server for its tools. Failures are returned as an empty list (the server is simply unavailable).
pub fn listTools(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, tmp_dir: []const u8, idx: usize, srv: Server) []Tool {
    const res = exchange(arena, gpa, io, tmp_dir, srv, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}", 20) catch return &.{};
    const p = std.json.parseFromSlice(std.json.Value, arena, res, .{}) catch return &.{};
    if (p.value != .object) return &.{};
    const arr = p.value.object.get("tools") orelse return &.{};
    if (arr != .array) return &.{};
    var out: std.ArrayList(Tool) = .empty;
    for (arr.array.items) |t| {
        if (t != .object) continue;
        const name = t.object.get("name") orelse continue;
        if (name != .string or !validId(name.string)) continue;
        const desc = if (t.object.get("description")) |d| (if (d == .string) d.string else "") else "";
        const schema = if (t.object.get("inputSchema")) |s| std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(s, .{})}) catch continue else "{\"type\":\"object\",\"properties\":{}}";
        out.append(arena, .{ .server = idx, .name = arena.dupe(u8, name.string) catch continue, .description = arena.dupe(u8, desc) catch continue, .schema = schema }) catch break;
    }
    return out.toOwnedSlice(arena) catch &.{};
}

/// Function schema in the same shape as the built-in tools.
pub fn schemaJson(arena: std.mem.Allocator, srv: Server, t: Tool) ![]const u8 {
    const full = try std.fmt.allocPrint(arena, "mcp__{s}__{s}", .{ srv.id, t.name });
    const desc = try std.fmt.allocPrint(arena, "[MCP server {s}] {s}", .{ srv.id, t.description[0..@min(t.description.len, 600)] });
    return std.fmt.allocPrint(arena, "{{\"type\":\"function\",\"function\":{{\"name\":{f},\"description\":{f},\"parameters\":{s}}}}}", .{ std.json.fmt(full, .{}), std.json.fmt(desc, .{}), t.schema });
}

/// Call one tool; returns the text to show the model (errors included, prefixed).
pub fn callTool(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, tmp_dir: []const u8, srv: Server, tool: []const u8, args_json: []const u8, timeout_s: u32) []const u8 {
    const args = if (args_json.len == 0) "{}" else args_json;
    const req = std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{{\"name\":{f},\"arguments\":{s}}}}}", .{ std.json.fmt(tool, .{}), args }) catch return "out of memory";
    const res = exchange(arena, gpa, io, tmp_dir, srv, req, timeout_s) catch |e| return std.fmt.allocPrint(arena, "ERROR: {s}", .{errorText(e)}) catch "ERROR";
    const p = std.json.parseFromSlice(std.json.Value, arena, res, .{}) catch return "ERROR: unreadable reply";
    if (p.value != .object) return "ERROR: unreadable reply";
    if (p.value.object.get("__error")) |m| return std.fmt.allocPrint(arena, "ERROR: {s}", .{if (m == .string) m.string else "error"}) catch "ERROR";
    var out: std.ArrayList(u8) = .empty;
    if (p.value.object.get("isError")) |ie| if (ie == .bool and ie.bool) out.appendSlice(arena, "ERROR (reported by the tool):\n") catch {};
    if (p.value.object.get("content")) |c| if (c == .array) for (c.array.items) |it| {
        if (it != .object) continue;
        const ty = it.object.get("type") orelse continue;
        if (ty == .string and std.mem.eql(u8, ty.string, "text")) {
            if (it.object.get("text")) |tx| if (tx == .string) {
                out.appendSlice(arena, tx.string) catch {};
                out.append(arena, '\n') catch {};
            };
        } else out.appendSlice(arena, "[non-text content omitted]\n") catch {};
    };
    if (out.items.len == 0) return res;
    return out.items;
}

test "parse servers" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const s = try parse(a.allocator(), std.testing.allocator,
        \\[[mcp]]
        \\id = "files"
        \\command = ["python3", "x.py"]
        \\read_only_tools = ["search"]
    );
    try std.testing.expectEqual(@as(usize, 1), s.len);
    try std.testing.expect(isReadOnly(s[0], "search"));
    try std.testing.expect(!isReadOnly(s[0], "write"));
    try std.testing.expectError(error.InvalidConfig, parse(a.allocator(), std.testing.allocator, "[[mcp]]\nid = \"a b\"\ncommand = [\"x\"]\n"));
    try std.testing.expectError(error.InvalidConfig, parse(a.allocator(), std.testing.allocator, "[[mcp]]\nid = \"a\"\n"));
}

test "split name" {
    const r = splitName("mcp__files__read_it").?;
    try std.testing.expectEqualStrings("files", r.server);
    try std.testing.expectEqualStrings("read_it", r.tool);
    try std.testing.expect(splitName("read_file") == null);
}
