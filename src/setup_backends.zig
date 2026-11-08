//! `aimgr setup-backends`: Windows only. Downloads Ollama from its official GitHub release into aimgr's own
//! data folder (no installer, no admin rights, nothing outside that folder), after showing what it will fetch and
//! asking. Every archive is checked against a SHA-256 pinned in this file before it is unpacked.
//! Nothing here runs unless the user ran the command.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const hardware = @import("hardware.zig");
const supervise = @import("supervise.zig");
const platform = @import("platform.zig");

const version = "v0.40.15";
const base_url = "https://github.com/ollama/ollama/releases/download/" ++ version ++ "/";

pub const Asset = struct { name: []const u8, size: u64, sha256: []const u8, why: []const u8 };

const amd64 = Asset{ .name = "ollama-windows-amd64.zip", .size = 1614941966, .sha256 = "9ca74a7ab66ec86870b1eecac7df160df08dc4e3a291ab5d2d59bcf9310221c6", .why = "Ollama (CPU and NVIDIA GPUs)" };
const rocm = Asset{ .name = "ollama-windows-amd64-rocm.zip", .size = 258790357, .sha256 = "2f5e81675329a5de2477a4a25823d55d5c3ead8d59522e92eac1664ab492faeb", .why = "AMD GPU support (added to the same folder)" };
const arm64 = Asset{ .name = "ollama-windows-arm64.zip", .size = 217149782, .sha256 = "35ce5195b57496dbc9ecbaa6593807e6ac26cbb53cf1f8bb57ac58daafa58574", .why = "Ollama for ARM64" };

/// What to download for this machine. ROCm is an add-on for a discrete AMD GPU.
pub fn plan(arena: std.mem.Allocator, arch: std.Target.Cpu.Arch, gpus: []const hardware.Gpu) ![]const Asset {
    var out: std.ArrayList(Asset) = .empty;
    if (arch == .aarch64) {
        try out.append(arena, arm64);
        return out.toOwnedSlice(arena);
    }
    try out.append(arena, amd64);
    for (gpus) |g| if (g.vendor == .amd and !g.integrated) {
        try out.append(arena, rocm);
        break;
    };
    return out.toOwnedSlice(arena);
}

/// <data dir>/backends/ollama
pub fn ollamaDir(arena: std.mem.Allocator, env: *const std.process.Environ.Map) !?[]const u8 {
    const d = (try config.dataDir(arena, env)) orelse return null;
    return try std.fs.path.join(arena, &.{ d, "backends", "ollama" });
}

const usage =
    \\usage: aimgr setup-backends [--yes] [--dry-run]
    \\  Windows only: downloads Ollama (official release, SHA-256 checked) into aimgr's data folder.
    \\
;

pub fn main(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, out: *std.Io.Writer, err: *std.Io.Writer, args: []const [:0]const u8) !u8 {
    if (builtin.os.tag != .windows) {
        try out.writeAll("setup-backends is only for Windows. On Linux install ollama / llama.cpp with your package manager.\n");
        return 0;
    }
    var yes = false;
    var dry = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--yes")) yes = true else if (std.mem.eql(u8, a, "--dry-run")) dry = true else {
            try err.writeAll(usage);
            return 2;
        }
    }
    const dir = (try ollamaDir(arena, env)) orelse {
        try err.writeAll("aimgr: cannot determine a data folder (USERPROFILE / LOCALAPPDATA not set)\n");
        return 1;
    };
    const exe = try std.fs.path.join(arena, &.{ dir, "ollama.exe" });
    if (std.Io.Dir.cwd().access(io, exe, .{})) |_| {
        try out.print("Ollama is already installed: {s}\nTo reinstall, delete that folder yourself and run this again.\n", .{dir});
        return 0;
    } else |_| {}

    const hw = try hardware.detect(arena, gpa, io);
    const assets = try plan(arena, builtin.cpu.arch, hw.gpus);
    var total: u64 = 0;
    try out.print("Ollama {s} will be downloaded from github.com/ollama/ollama into:\n  {s}\n", .{ version, dir });
    for (assets) |a| {
        total += a.size;
        try out.print("  {s}  ({d:.1} GB)  {s}\n", .{ a.name, @as(f64, @floatFromInt(a.size)) / 1e9, a.why });
    }
    try out.print("Total {d:.1} GB; unpacked it takes a few GB more. Each file is checked against a pinned SHA-256.\n", .{@as(f64, @floatFromInt(total)) / 1e9});
    if (dry) return 0;
    try out.flush();
    if (!yes and !supervise.confirm(.{ .gpa = gpa, .io = io, .environ = env, .out = out, .err = err, .log_dir = null }, "Download and install?")) {
        try out.writeAll("cancelled; nothing was downloaded\n");
        return 1;
    }

    const parent = std.fs.path.dirname(dir).?;
    try std.Io.Dir.cwd().createDirPath(io, parent);
    const staging = try std.fmt.allocPrint(arena, "{s}.new", .{dir});
    std.Io.Dir.cwd().createDirPath(io, staging) catch {};
    for (assets) |a| {
        const zip_path = try std.fs.path.join(arena, &.{ parent, a.name });
        try out.print("\nDownloading {s} ...\n", .{a.name});
        try out.flush();
        download(gpa, io, out, try std.fmt.allocPrint(arena, "{s}{s}", .{ base_url, a.name }), zip_path, a.size) catch |e| {
            try err.print("aimgr: download failed ({s}); the partial file {s} can be deleted\n", .{ @errorName(e), zip_path });
            return 1;
        };
        try out.writeAll("Checking SHA-256 ... ");
        try out.flush();
        const ok = checkSha(io, zip_path, a.sha256) catch false;
        if (!ok) {
            try err.print("MISMATCH\naimgr: {s} does not match the pinned checksum, so it was NOT unpacked. Delete it and try again.\n", .{zip_path});
            return 1;
        }
        try out.writeAll("ok\nUnpacking ...\n");
        try out.flush();
        unpack(io, zip_path, staging) catch |e| {
            try err.print("aimgr: unpacking failed ({s}); {s} may be partly filled and can be deleted\n", .{ @errorName(e), staging });
            return 1;
        };
        std.Io.Dir.cwd().deleteFile(io, zip_path) catch {};
    }
    try std.Io.Dir.rename(std.Io.Dir.cwd(), staging, std.Io.Dir.cwd(), dir, io);
    try out.print("\nInstalled. aimgr will find ollama.exe in {s} automatically.\nStart it with: aimgr serve ollama\n", .{dir});
    return 0;
}

const Progress = struct {
    io: std.Io,
    path: []const u8,
    total: u64,
    out: *std.Io.Writer,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *Progress) void {
        var last: u64 = 0;
        while (!self.done.load(.acquire)) {
            self.io.sleep(.fromMilliseconds(1000), .awake) catch {};
            const f = std.Io.Dir.cwd().openFile(self.io, self.path, .{}) catch continue;
            defer f.close(self.io);
            const st = f.stat(self.io) catch continue;
            if (st.size == last) continue;
            last = st.size;
            self.out.print("\r  {d} MB of {d} MB ({d}%)   ", .{ st.size >> 20, self.total >> 20, if (self.total > 0) st.size * 100 / self.total else 0 }) catch {};
            self.out.flush() catch {};
        }
    }
};

fn download(gpa: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, url: []const u8, path: []const u8, size: u64) !void {
    if (!std.mem.startsWith(u8, url, "https://github.com/ollama/ollama/releases/download/")) return error.NetworkFailed;
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var wbuf: [64 * 1024]u8 = undefined;
    var fw: std.Io.File.Writer = .initStreaming(file, io, &wbuf);
    var prog: Progress = .{ .io = io, .path = path, .total = size, .out = out };
    const th = std.Thread.spawn(.{}, Progress.run, .{&prog}) catch null;
    defer if (th) |t| {
        prog.done.store(true, .release);
        t.join();
    };
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &fw.interface,
        .extra_headers = &.{.{ .name = "user-agent", .value = "aimgr (local model manager)" }},
    });
    try fw.interface.flush();
    if (res.status != .ok) return error.BadStatus;
    try out.writeAll("\r  download finished                         \n");
}

fn checkSha(io: std.Io, path: []const u8, want_hex: []const u8) !bool {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var r = f.readerStreaming(io, &buf);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = r.interface.readSliceShort(&chunk) catch return error.ReadFailed;
        if (n == 0) break;
        h.update(chunk[0..n]);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    const got = std.fmt.bytesToHex(digest, .lower);
    return std.mem.eql(u8, &got, want_hex);
}

fn unpack(io: std.Io, zip_path: []const u8, dest: []const u8) !void {
    var f = try std.Io.Dir.cwd().openFile(io, zip_path, .{});
    defer f.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fr = f.reader(io, &buf);
    var d = try std.Io.Dir.cwd().openDir(io, dest, .{});
    defer d.close(io);
    try std.zip.extract(d, &fr, .{});
}

test "plan picks rocm only for a discrete AMD GPU" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const amd = hardware.Gpu{ .vendor = .amd, .label = "x", .vram_total = 12 << 30, .source = "t" };
    const igpu = hardware.Gpu{ .vendor = .amd, .label = "x", .vram_total = 1 << 28, .integrated = true, .source = "t" };
    try std.testing.expectEqual(@as(usize, 2), (try plan(a.allocator(), .x86_64, &.{amd})).len);
    try std.testing.expectEqual(@as(usize, 1), (try plan(a.allocator(), .x86_64, &.{igpu})).len);
    try std.testing.expectEqual(@as(usize, 1), (try plan(a.allocator(), .aarch64, &.{amd})).len);
}
