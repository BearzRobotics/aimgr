//! Ollama /api/chat with tools (non-streaming), over loopback HTTP.
//! Request: {model, messages[], tools[], stream:false, options:{num_ctx}}
//! Reply:   {message:{role, content, thinking?, tool_calls:[{function:{name, arguments:{...}}}]}}  or  {error:"..."}
const std = @import("std");
const http = @import("../http.zig");

pub const Role = enum { system, user, assistant, tool };

/// Which wire format the server speaks.
pub const Api = enum {
    /// Ollama /api/chat (tool arguments are JSON objects).
    ollama,
    /// OpenAI-style /v1/chat/completions as served by llama-server (arguments are JSON strings, calls have ids).
    openai,
};

pub const Call = struct {
    /// OpenAI-style call id (empty for Ollama).
    id: []const u8 = "",
    name: []const u8,
    /// The arguments object, re-serialized as JSON text.
    args_json: []const u8,
};

pub const Msg = struct {
    role: Role,
    content: []const u8 = "",
    /// For role=tool: which tool produced this result.
    tool_name: ?[]const u8 = null,
    /// For role=tool (OpenAI style): the id of the call this answers.
    tool_call_id: []const u8 = "",
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

/// Upper bound for one reply (thinking included), so a looping model ends instead of running for hours.
pub const max_reply_tokens: u32 = 4096;

pub fn requestBody(arena: std.mem.Allocator, api: Api, model: []const u8, msgs: []const Msg, tools_json: []const u8, num_ctx: u32) ![]u8 {
    if (api == .openai) return requestBodyOpenai(arena, model, msgs, tools_json);
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
    // A model that never stops (small "thinking" models can loop) must not generate forever.
    try s.objectField("num_predict");
    try s.write(max_reply_tokens);
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

/// OpenAI-style body. Tool-call arguments travel as JSON *strings*; results as role=tool with tool_call_id.
fn requestBodyOpenai(arena: std.mem.Allocator, model: []const u8, msgs: []const Msg, tools_json: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("model");
    try s.write(model);
    try s.objectField("max_tokens");
    try s.write(max_reply_tokens);
    try s.objectField("stream");
    try s.write(false);
    try s.objectField("messages");
    try s.beginArray();
    for (msgs) |m| {
        try s.beginObject();
        try s.objectField("role");
        try s.write(@tagName(m.role));
        try s.objectField("content");
        try s.write(m.content);
        if (m.role == .tool and m.tool_call_id.len > 0) {
            try s.objectField("tool_call_id");
            try s.write(m.tool_call_id);
        }
        if (m.calls.len > 0) {
            try s.objectField("tool_calls");
            try s.beginArray();
            for (m.calls) |c| {
                try s.beginObject();
                try s.objectField("id");
                try s.write(c.id);
                try s.objectField("type");
                try s.write("function");
                try s.objectField("function");
                try s.beginObject();
                try s.objectField("name");
                try s.write(c.name);
                try s.objectField("arguments");
                try s.write(c.args_json); // a string, escaped by the writer
                try s.endObject();
                try s.endObject();
            }
            try s.endArray();
        }
        try s.endObject();
    }
    try s.endArray();
    if (tools_json.len > 2) { // "[]" means no tools
        try s.objectField("tools");
        try s.beginWriteRaw();
        try s.writer.writeAll(tools_json);
        s.endWriteRaw();
    }
    try s.endObject();
    return aw.toOwnedSlice();
}

pub fn parseReply(arena: std.mem.Allocator, api: Api, body: []const u8) Error!Reply {
    if (api == .openai) return parseReplyOpenai(arena, body);
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

fn parseReplyOpenai(arena: std.mem.Allocator, body: []const u8) Error!Reply {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch return error.BadReply;
    const root = parsed.value;
    if (root != .object) return error.BadReply;
    if (root.object.get("error")) |e| {
        var text: []const u8 = "api error";
        if (e == .object) {
            if (e.object.get("message")) |m| if (m == .string) {
                text = m.string;
            };
        } else if (e == .string) text = e.string;
        last_error = arena.dupe(u8, text) catch "api error";
        return error.ApiError;
    }
    const choices = root.object.get("choices") orelse return error.BadReply;
    if (choices != .array or choices.array.items.len == 0) return error.BadReply;
    const first = choices.array.items[0];
    if (first != .object) return error.BadReply;
    const msg = first.object.get("message") orelse return error.BadReply;
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
            const args_v = f.object.get("arguments") orelse std.json.Value{ .string = "{}" };
            const args_json: []const u8 = switch (args_v) {
                .string => |sv| sv,
                else => std.json.Stringify.valueAlloc(arena, args_v, .{}) catch return error.OutOfMemory,
            };
            const id: []const u8 = if (item.object.get("id")) |iv| (if (iv == .string) iv.string else "") else "";
            try calls.append(arena, .{ .id = id, .name = name_v.string, .args_json = args_json });
        }
    };
    return .{ .content = content, .calls = try calls.toOwnedSlice(arena) };
}

pub fn send(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, api: Api, host_port: []const u8, request: []const u8) Error!Reply {
    const url = try std.fmt.allocPrint(arena, "http://{s}{s}", .{ host_port, if (api == .ollama) "/api/chat" else "/v1/chat/completions" });
    const body = http.postJson(gpa, io, url, request, 32 << 20) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Unreachable,
    };
    defer gpa.free(body);
    return parseReply(arena, api, body);
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
    const body = try requestBody(a.allocator(), .ollama, "m:1b", &msgs, "[{\"type\":\"function\"}]", 8192);
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
    const r1 = try parseReply(a.allocator(), .ollama, "{\"message\":{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"function\":{\"name\":\"read_file\",\"arguments\":{\"path\":\"/a\",\"limit\":10}}}]},\"done\":true}");
    try std.testing.expectEqual(@as(usize, 1), r1.calls.len);
    try std.testing.expectEqualStrings("read_file", r1.calls[0].name);
    try std.testing.expect(std.mem.indexOf(u8, r1.calls[0].args_json, "\"limit\":10") != null);
    const r2 = try parseReply(a.allocator(), .ollama, "{\"message\":{\"role\":\"assistant\",\"content\":\"hello\"}}");
    try std.testing.expectEqualStrings("hello", r2.content);
    try std.testing.expectEqual(@as(usize, 0), r2.calls.len);
    const r3 = try parseReply(a.allocator(), .ollama, "{\"message\":{\"content\":\"\",\"tool_calls\":[{\"function\":{\"name\":\"run_command\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}}]}}");
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", r3.calls[0].args_json);
    try std.testing.expectError(error.ApiError, parseReply(a.allocator(), .ollama, "{\"error\":\"model does not support tools\"}"));
    try std.testing.expect(std.mem.indexOf(u8, last_error, "support tools") != null);
    try std.testing.expectError(error.BadReply, parseReply(a.allocator(), .ollama, "not json"));
    try std.testing.expectError(error.BadReply, parseReply(a.allocator(), .ollama, "{\"x\":1}"));
}

test "openai request: arguments are strings, results carry tool_call_id" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const msgs = [_]Msg{
        .{ .role = .user, .content = "list" },
        .{ .role = .assistant, .calls = &.{.{ .id = "call_1", .name = "list_dir", .args_json = "{\"path\":\"/x\"}" }} },
        .{ .role = .tool, .content = "a\nb", .tool_name = "list_dir", .tool_call_id = "call_1" },
    };
    const body = try requestBody(a.allocator(), .openai, "m", &msgs, "[{\"type\":\"function\"}]", 8192);
    const root = (try std.json.parseFromSlice(std.json.Value, a.allocator(), body, .{})).value.object;
    const ms = root.get("messages").?.array.items;
    const call = ms[1].object.get("tool_calls").?.array.items[0].object;
    try std.testing.expectEqualStrings("call_1", call.get("id").?.string);
    try std.testing.expectEqualStrings("function", call.get("type").?.string);
    const args = call.get("function").?.object.get("arguments").?;
    try std.testing.expect(args == .string); // a JSON string, not an object
    try std.testing.expectEqualStrings("{\"path\":\"/x\"}", args.string);
    try std.testing.expectEqualStrings("call_1", ms[2].object.get("tool_call_id").?.string);
    try std.testing.expectEqual(@as(usize, 1), root.get("tools").?.array.items.len);
    const none = try requestBody(a.allocator(), .openai, "m", &msgs, "[]", 8192);
    try std.testing.expect(std.mem.indexOf(u8, none, "\"tools\"") == null);
}

test "openai reply: real llama-server shape, plain text, errors" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const r1 = try parseReply(a.allocator(), .openai, "{\"choices\":[{\"finish_reason\":\"tool_calls\",\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"type\":\"function\",\"function\":{\"name\":\"list_dir\",\"arguments\":\"{\\\"path\\\":\\\"stuff/Books\\\"}\"},\"id\":\"b0PfvVDP\"}]}}]}");
    try std.testing.expectEqual(@as(usize, 1), r1.calls.len);
    try std.testing.expectEqualStrings("b0PfvVDP", r1.calls[0].id);
    try std.testing.expectEqualStrings("list_dir", r1.calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"stuff/Books\"}", r1.calls[0].args_json);
    const r2 = try parseReply(a.allocator(), .openai, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"hi\",\"reasoning_content\":\"...\"}}]}");
    try std.testing.expectEqualStrings("hi", r2.content);
    const r3 = try parseReply(a.allocator(), .openai, "{\"choices\":[{\"message\":{\"content\":null,\"tool_calls\":[{\"id\":\"1\",\"function\":{\"name\":\"x\",\"arguments\":{\"a\":1}}}]}}]}");
    try std.testing.expectEqualStrings("{\"a\":1}", r3.calls[0].args_json); // object arguments tolerated
    try std.testing.expectError(error.ApiError, parseReply(a.allocator(), .openai, "{\"error\":{\"message\":\"model does not support tools\",\"code\":500}}"));
    try std.testing.expect(std.mem.indexOf(u8, last_error, "support tools") != null);
    try std.testing.expectError(error.BadReply, parseReply(a.allocator(), .openai, "{\"choices\":[]}"));
}

test "every request caps the reply length" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const msgs = [_]Msg{.{ .role = .user, .content = "hi" }};
    const o = try requestBody(a.allocator(), .ollama, "m", &msgs, "", 8192);
    try std.testing.expect(std.mem.indexOf(u8, o, "\"num_predict\":4096") != null);
    const p = try requestBody(a.allocator(), .openai, "m", &msgs, "", 8192);
    try std.testing.expect(std.mem.indexOf(u8, p, "\"max_tokens\":4096") != null);
}
