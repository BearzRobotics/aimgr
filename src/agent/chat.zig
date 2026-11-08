//! Ollama /api/chat with tools (non-streaming), over loopback HTTP.
//! Request: {model, messages[], tools[], stream:false, options:{num_ctx}}
//! Reply:   {message:{role, content, thinking?, tool_calls:[{function:{name, arguments:{...}}}]}}  or  {error:"..."}
const std = @import("std");
const http = @import("../http.zig");

pub const Role = enum { system, user, assistant, tool };

pub const Call = struct {
    name: []const u8,
    /// The arguments object, re-serialized as JSON text.
    args_json: []const u8,
};

pub const Msg = struct {
    role: Role,
    content: []const u8 = "",
    /// For role=tool: which tool produced this result.
    tool_name: ?[]const u8 = null,
    /// For role=assistant: the tool calls it made.
    calls: []const Call = &.{},
};

pub const Reply = struct {
    content: []const u8,
    calls: []const Call,
};

pub const Error = error{ ApiError, BadReply, Unreachable, OutOfMemory };

/// Message of the last API error (valid until the next call).
pub var last_error: []const u8 = "";

pub fn requestBody(arena: std.mem.Allocator, model: []const u8, msgs: []const Msg, tools_json: []const u8, num_ctx: u32) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("model");
    try s.write(model);
    try s.objectField("stream");
    try s.write(false);
    try s.objectField("options");
    try s.beginObject();
    try s.objectField("num_ctx");
    try s.write(num_ctx);
    try s.endObject();
    try s.objectField("messages");
    try s.beginArray();
    for (msgs) |m| {
        try s.beginObject();
        try s.objectField("role");
        try s.write(@tagName(m.role));
        try s.objectField("content");
        try s.write(m.content);
        if (m.tool_name) |tn| {
            try s.objectField("tool_name");
            try s.write(tn);
        }
        if (m.calls.len > 0) {
            try s.objectField("tool_calls");
            try s.beginArray();
            for (m.calls) |c| {
                try s.beginObject();
                try s.objectField("function");
                try s.beginObject();
                try s.objectField("name");
                try s.write(c.name);
                try s.objectField("arguments");
                try s.beginWriteRaw();
                try s.writer.writeAll(c.args_json);
                s.endWriteRaw();
                try s.endObject();
                try s.endObject();
            }
            try s.endArray();
        }
        try s.endObject();
    }
    try s.endArray();
    if (tools_json.len > 0) {
        try s.objectField("tools");
        try s.beginWriteRaw();
        try s.writer.writeAll(tools_json);
        s.endWriteRaw();
    }
    try s.endObject();
    return aw.toOwnedSlice();
}

pub fn parseReply(arena: std.mem.Allocator, body: []const u8) Error!Reply {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch return error.BadReply;
    const root = parsed.value;
    if (root != .object) return error.BadReply;
    if (root.object.get("error")) |e| {
        last_error = if (e == .string) (arena.dupe(u8, e.string) catch "api error") else "api error";
        return error.ApiError;
    }
    const msg = root.object.get("message") orelse return error.BadReply;
    if (msg != .object) return error.BadReply;
    const content: []const u8 = if (msg.object.get("content")) |c| (if (c == .string) c.string else "") else "";
    var calls: std.ArrayList(Call) = .empty;
    if (msg.object.get("tool_calls")) |tc| if (tc == .array) {
        for (tc.array.items) |item| {
            if (item != .object) continue;
            const f = item.object.get("function") orelse continue;
            if (f != .object) continue;
            const name_v = f.object.get("name") orelse continue;
            if (name_v != .string) continue;
            const args_v = f.object.get("arguments") orelse std.json.Value{ .object = std.json.ObjectMap.empty };
            // Some models send arguments as a JSON string; accept that too.
            const args_json: []const u8 = switch (args_v) {
                .string => |sv| sv,
                else => std.json.Stringify.valueAlloc(arena, args_v, .{}) catch return error.OutOfMemory,
            };
            try calls.append(arena, .{ .name = name_v.string, .args_json = args_json });
        }
    };
    return .{ .content = content, .calls = try calls.toOwnedSlice(arena) };
}

pub fn send(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, host_port: []const u8, request: []const u8) Error!Reply {
    const url = try std.fmt.allocPrint(arena, "http://{s}/api/chat", .{host_port});
    const body = http.postJson(gpa, io, url, request, 32 << 20) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Unreachable,
    };
    defer gpa.free(body);
    return parseReply(arena, body);
}

test "request body shape, including tool calls and tool results" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const msgs = [_]Msg{
        .{ .role = .system, .content = "sys" },
        .{ .role = .user, .content = "list \"it\"" },
        .{ .role = .assistant, .calls = &.{.{ .name = "list_dir", .args_json = "{\"path\":\"/x\"}" }} },
        .{ .role = .tool, .content = "a\nb", .tool_name = "list_dir" },
    };
    const body = try requestBody(a.allocator(), "m:1b", &msgs, "[{\"type\":\"function\"}]", 8192);
    const parsed = try std.json.parseFromSlice(std.json.Value, a.allocator(), body, .{});
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("m:1b", root.get("model").?.string);
    try std.testing.expect(root.get("stream").?.bool == false);
    try std.testing.expectEqual(@as(i64, 8192), root.get("options").?.object.get("num_ctx").?.integer);
    const ms = root.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), ms.len);
    try std.testing.expectEqualStrings("list \"it\"", ms[1].object.get("content").?.string);
    const fc = ms[2].object.get("tool_calls").?.array.items[0].object.get("function").?.object;
    try std.testing.expectEqualStrings("list_dir", fc.get("name").?.string);
    try std.testing.expectEqualStrings("/x", fc.get("arguments").?.object.get("path").?.string);
    try std.testing.expectEqualStrings("list_dir", ms[3].object.get("tool_name").?.string);
    try std.testing.expectEqual(@as(usize, 1), root.get("tools").?.array.items.len);
}

test "reply parsing: calls, plain text, string arguments, errors" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const r1 = try parseReply(a.allocator(), "{\"message\":{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"function\":{\"name\":\"read_file\",\"arguments\":{\"path\":\"/a\",\"limit\":10}}}]},\"done\":true}");
    try std.testing.expectEqual(@as(usize, 1), r1.calls.len);
    try std.testing.expectEqualStrings("read_file", r1.calls[0].name);
    try std.testing.expect(std.mem.indexOf(u8, r1.calls[0].args_json, "\"limit\":10") != null);
    const r2 = try parseReply(a.allocator(), "{\"message\":{\"role\":\"assistant\",\"content\":\"hello\"}}");
    try std.testing.expectEqualStrings("hello", r2.content);
    try std.testing.expectEqual(@as(usize, 0), r2.calls.len);
    const r3 = try parseReply(a.allocator(), "{\"message\":{\"content\":\"\",\"tool_calls\":[{\"function\":{\"name\":\"run_command\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}}]}}");
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", r3.calls[0].args_json);
    try std.testing.expectError(error.ApiError, parseReply(a.allocator(), "{\"error\":\"model does not support tools\"}"));
    try std.testing.expect(std.mem.indexOf(u8, last_error, "support tools") != null);
    try std.testing.expectError(error.BadReply, parseReply(a.allocator(), "not json"));
    try std.testing.expectError(error.BadReply, parseReply(a.allocator(), "{\"x\":1}"));
}
