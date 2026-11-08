//! `aimgr pull|update|remove <backend> <id> [--yes] [--dry-run]`.
const std = @import("std");
const backend = @import("backend.zig");
const inventory = @import("inventory.zig");
const manage = @import("manage.zig");
const supervise = @import("supervise.zig");
const catalog_io = @import("catalog_io.zig");

const Opts = struct { kind: backend.Kind, id: []const u8, yes: bool = false, dry_run: bool = false };

fn parse(args: []const [:0]const u8) ?Opts {
    var kind: ?backend.Kind = null;
    var id: ?[]const u8 = null;
    var o: Opts = undefined;
    o.yes = false;
    o.dry_run = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--yes")) {
            o.yes = true;
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            o.dry_run = true;
        } else if (kind == null) {
            kind = std.meta.stringToEnum(backend.Kind, a) orelse return null;
        } else if (id == null) {
            id = a;
        } else return null;
    }
    o.kind = kind orelse return null;
    o.id = id orelse return null;
    return o;
}

fn collect(arena: std.mem.Allocator, report: inventory.Inventory) ![]backend.Model {
    var all: std.ArrayList(backend.Model) = .empty;
    for (report.reports) |r| try all.appendSlice(arena, r.models orelse &.{});
    return all.toOwnedSlice(arena);
}

pub fn run(e: supervise.Env, report: inventory.Inventory, arena: std.mem.Allocator, action: manage.Action, args: []const [:0]const u8) !u8 {
    const o = parse(args) orelse {
        try e.err.print("usage: aimgr {s} <ollama|llama> <id> [--yes] [--dry-run]\n", .{@tagName(action)});
        return 2;
    };
    if (manage.unsupportedReason(o.kind, action)) |why| {
        try e.err.print("aimgr: {s} is disabled for {s}: {s}\n", .{ @tagName(action), o.kind.name(), why });
        return 1;
    }
    const argv = manage.plan(arena, o.kind, action, o.id) catch |err| {
        try e.err.print("aimgr: {s}\n", .{manage.errorText(err)});
        return 2;
    };
    for (report.reports) |r| if (r.kind == o.kind and r.probe != .available) {
        try e.err.print("aimgr: {s} is unavailable\n", .{o.kind.name()});
        return 1;
    };

    const all = try collect(arena, report);
    var is_installed = false;
    for (all) |m| if (m.backend == o.kind and std.mem.eql(u8, m.id, o.id)) {
        is_installed = true;
    };
    if ((action == .update or action == .remove) and !is_installed) {
        try e.err.print("aimgr: '{s}' is not installed in {s} (exact id required; see 'aimgr list')\n", .{ o.id, o.kind.name() });
        return 1;
    }
    if (action == .pull and is_installed) {
        try e.err.print("aimgr: '{s}' is already installed in {s}; use 'aimgr update' to re-pull it\n", .{ o.id, o.kind.name() });
        return 1;
    }

    // Explain exactly what will happen.
    try e.out.print("backend: {s}\nmodel:   {s}\ncommand:", .{ o.kind.name(), o.id });
    for (argv) |a| try e.out.print(" {s}", .{a});
    try e.out.writeAll("\n");
    if (action != .remove) if (catalog_io.loadAll(arena, e.gpa, e.io, e.environ) catch null) |l| if (l.cat.find(o.kind, o.id)) |ent| if (ent.access) |ac| {
        try e.out.print("access:  {s}: {s}\n", .{ ac.label(), ac.explain() });
        if (ac == .signin and e.environ.get("HF_TOKEN") == null) try e.out.writeAll("warning: HF_TOKEN is not set; a gated download will fail until you accept the license on the model page and set it.\n");
        if (ac == .cloud) try e.out.writeAll("warning: this only registers a remote model; it will not run offline and aimgr will not launch it.\n");
    };
    switch (action) {
        .pull => try e.out.writeAll("this uses the network and downloads model files.\n"),
        .update => try e.out.print("this uses the network.\n{s}\n", .{manage.mutable_tag_warning}),
        .remove => {
            for (try manage.duplicates(arena, all, o.kind, o.id)) |d| {
                if (d.exact_id) {
                    try e.out.print("note: the same id also exists in {s} (it will NOT be touched)\n", .{d.model.backend.name()});
                } else {
                    try e.out.print("note: similar model remains/exists: {s} {s}\n", .{ d.model.backend.name(), d.model.id });
                }
            }
            try e.out.writeAll("this permanently deletes the model from this backend.\n");
        },
    }
    try e.out.flush();
    if (o.dry_run) {
        try e.out.writeAll("dry run: nothing executed.\n");
        return 0;
    }

    if (!o.yes) {
        const q = try std.fmt.allocPrint(arena, "{s} '{s}' in {s}?", .{ @tagName(action), o.id, o.kind.name() });
        if (!supervise.confirm(e, q)) {
            try e.err.writeAll("aimgr: cancelled\n");
            return 1;
        }
    }
    const code = try supervise.runTransfer(e, argv, @tagName(action));
    if (code == 0) try e.out.print("{s}: done ({s} {s})\n", .{ @tagName(action), o.kind.name(), o.id }) else try e.err.print("aimgr: {s} failed with exit code {d}\n", .{ @tagName(action), code });
    return code;
}
