//! `aimgr chat` / `aimgr serve`: argument parsing, installed-model check,
//! public-bind confirmation, then hand-off to supervise.zig.
const std = @import("std");
const backend = @import("backend.zig");
const inventory = @import("inventory.zig");
const launcher = @import("launcher.zig");
const netstat = @import("netstat.zig");
const supervise = @import("supervise.zig");
const catalog_io = @import("catalog_io.zig");

const Parsed = struct {
    kind: backend.Kind,
    model: ?[]const u8 = null,
    profile: launcher.Profile = .{},
};

const ParseError = error{ BadArgs, InvalidNumber };

fn parseArgs(args: []const [:0]const u8) ParseError!Parsed {
    if (args.len < 1) return error.BadArgs;
    var p: Parsed = .{ .kind = std.meta.stringToEnum(backend.Kind, args[0]) orelse return error.BadArgs };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.startsWith(u8, a, "--")) {
            i += 1;
            if (i >= args.len) return error.BadArgs;
            const v = args[i];
            if (std.mem.eql(u8, a, "--ctx")) {
                p.profile.ctx = std.fmt.parseInt(u32, v, 10) catch return error.InvalidNumber;
            } else if (std.mem.eql(u8, a, "--gpu-layers")) {
                p.profile.gpu_layers = launcher.parseGpuLayers(v) orelse return error.InvalidNumber;
            } else if (std.mem.eql(u8, a, "--host")) {
                p.profile.host = v;
            } else if (std.mem.eql(u8, a, "--port")) {
                p.profile.port = std.fmt.parseInt(u16, v, 10) catch return error.InvalidNumber;
            } else return error.BadArgs;
        } else {
            if (p.model != null) return error.BadArgs;
            p.model = a;
        }
    }
    return p;
}

fn installed(report: inventory.Inventory, kind: backend.Kind, id: []const u8) bool {
    for (report.reports) |r| {
        if (r.kind != kind) continue;
        for (r.models orelse &.{}) |m| if (std.mem.eql(u8, m.id, id)) return true;
    }
    return false;
}

pub fn run(e: supervise.Env, report: inventory.Inventory, arena: std.mem.Allocator, mode: launcher.Mode, args: []const [:0]const u8) !u8 {
    const parsed = parseArgs(args) catch |err| {
        try e.err.print("aimgr: bad arguments ({s})\n", .{@errorName(err)});
        return 2;
    };
    const plan = launcher.plan(arena, parsed.kind, mode, parsed.model, parsed.profile) catch |err| {
        try e.err.print("aimgr: {s}\n", .{launcher.errorText(err)});
        return 2;
    };

    // The backend must be usable and the model installed: launching is offline, never a download.
    for (report.reports) |r| if (r.kind == parsed.kind and r.probe != .available) {
        try e.err.print("aimgr: {s} is unavailable\n", .{parsed.kind.name()});
        return 1;
    };
    if (parsed.model) |m| if (!installed(report, parsed.kind, m)) {
        try e.err.print("aimgr: '{s}' is not installed in {s} (exact id required; see 'aimgr list'); nothing will be downloaded\n", .{ m, parsed.kind.name() });
        return 1;
    };

    // Cloud models run remotely (sign-in + API usage): not an offline launch, so aimgr refuses.
    if (parsed.model) |m| {
        const loaded = catalog_io.loadAll(arena, e.gpa, e.io, e.environ) catch null;
        if (loaded) |l| if (l.cat.find(parsed.kind, m)) |ent| if (ent.access == .cloud) {
            try e.err.print("aimgr: '{s}' is a cloud model: it runs on a remote service and needs sign-in and API usage, so aimgr (offline-first) will not launch it. Use {s} directly if you want that.\n", .{ m, parsed.kind.name() });
            return 1;
        };
    }

    if (mode == .chat) return supervise.runChat(e, plan);

    // Shared Ollama daemon: attach rather than start a second one.
    if (parsed.kind == .ollama and netstat.isListening(e.gpa, e.io, plan.listen_port.?)) {
        try e.out.print("ollama: daemon already listening on port {d}; using it (nothing started)\n", .{plan.listen_port.?});
        if (parsed.profile.ctx != null) try e.out.writeAll("note: --ctx ignored because the daemon is already running\n");
        return 0;
    }
    if (plan.public_bind) {
        const q = try std.fmt.allocPrint(arena, "WARNING: {s}:{d} is not a loopback address and would expose the {s} server to the network. Continue?", .{ plan.listen_host.?, plan.listen_port.?, parsed.kind.name() });
        if (!supervise.confirm(e, q)) {
            try e.err.writeAll("aimgr: cancelled (public bind not confirmed)\n");
            return 1;
        }
    }
    return supervise.runServer(e, plan, parsed.kind.name());
}

test "parse args" {
    const a = [_][:0]const u8{ "llama", "org/m:Q4", "--ctx", "4096", "--port", "9000" };
    const p = try parseArgs(&a);
    try std.testing.expectEqual(backend.Kind.llama, p.kind);
    try std.testing.expectEqual(@as(?u32, 4096), p.profile.ctx);
    try std.testing.expectEqual(@as(?u16, 9000), p.profile.port);
    const bad = [_][:0]const u8{ "llama", "m", "--ctx" };
    try std.testing.expectError(error.BadArgs, parseArgs(&bad));
    const bad2 = [_][:0]const u8{ "nope", "m" };
    try std.testing.expectError(error.BadArgs, parseArgs(&bad2));
}
