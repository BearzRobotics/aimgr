//! `aimgr setup-backends [ollama|llama|all]`: Windows only. Downloads Ollama and/or llama.cpp from their official
//! GitHub releases into aimgr's own data folder (no installer, no admin rights, nothing outside that folder),
//! after showing what it will fetch and asking. Every archive is checked against a SHA-256 pinned in this file
//! before it is unpacked.
//! Nothing here runs unless the user ran the command.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const hardware = @import("hardware.zig");
const supervise = @import("supervise.zig");
const platform = @import("platform.zig");

pub const Backend = enum { ollama, llama };

const version = "v0.40.15";
const base_url = "https://github.com/ollama/ollama/releases/download/" ++ version ++ "/";
const llama_build = "b12211";
const llama_url = "https://github.com/ggml-org/llama.cpp/releases/download/" ++ llama_build ++ "/";

pub const Asset = struct { name: []const u8, size: u64, sha256: []const u8, why: []const u8, base: []const u8 = base_url };

const amd64 = Asset{ .name = "ollama-windows-amd64.zip", .size = 1614941966, .sha256 = "9ca74a7ab66ec86870b1eecac7df160df08dc4e3a291ab5d2d59bcf9310221c6", .why = "Ollama (CPU and NVIDIA GPUs)" };
const rocm = Asset{ .name = "ollama-windows-amd64-rocm.zip", .size = 258790357, .sha256 = "2f5e81675329a5de2477a4a25823d55d5c3ead8d59522e92eac1664ab492faeb", .why = "AMD GPU support (added to the same folder)" };
const arm64 = Asset{ .name = "ollama-windows-arm64.zip", .size = 217149782, .sha256 = "35ce5195b57496dbc9ecbaa6593807e6ac26cbb53cf1f8bb57ac58daafa58574", .why = "Ollama for ARM64" };

// llama.cpp: Vulkan runs on NVIDIA, AMD and Intel GPUs with their normal drivers (no CUDA toolkit), CPU otherwise.
const llama_vulkan_x64 = Asset{ .name = "llama-" ++ llama_build ++ "-bin-win-vulkan-x64.zip", .size = 37845757, .sha256 = "20954cbad1a4626436c6ebaed5e48477f68427b075934689f360301ac426a2f1", .why = "llama.cpp (GPU via Vulkan)", .base = llama_url };
const llama_cpu_x64 = Asset{ .name = "llama-" ++ llama_build ++ "-bin-win-cpu-x64.zip", .size = 24886431, .sha256 = "23729000408c6968faf5e322afc99319d3b8c576ba872ef7663d9b89810090f3", .why = "llama.cpp (CPU)", .base = llama_url };
const llama_vulkan_arm64 = Asset{ .name = "llama-" ++ llama_build ++ "-bin-win-vulkan-arm64.zip", .size = 25768892, .sha256 = "06c268aa8505a0ba71b8b6992df78af0b955c63d01a2417dd76279d00e5a3b4e", .why = "llama.cpp for ARM64 (GPU via Vulkan)", .base = llama_url };
const llama_cpu_arm64 = Asset{ .name = "llama-" ++ llama_build ++ "-bin-win-cpu-arm64.zip", .size = 13236751, .sha256 = "bf52f65602d713a4a13ed366a8ba8d924558bb43be04b7a37f4f5f506a6b6512", .why = "llama.cpp for ARM64 (CPU)", .base = llama_url };

/// llama.cpp: the Vulkan build when there is a real (not integrated) GPU, else the CPU build.
pub fn planLlama(arena: std.mem.Allocator, arch: std.Target.Cpu.Arch, gpus: []const hardware.Gpu, force_cpu: bool) ![]const Asset {
    var gpu = false;
    for (gpus) |g| if (!g.integrated) {
        gpu = true;
    };
    const a: Asset = if (arch == .aarch64) (if (gpu and !force_cpu) llama_vulkan_arm64 else llama_cpu_arm64) else (if (gpu and !force_cpu) llama_vulkan_x64 else llama_cpu_x64);
    return arena.dupe(Asset, &.{a});
}

/// <data dir>/backends/llama
pub fn llamaDir(arena: std.mem.Allocator, env: *const std.process.Environ.Map) !?[]const u8 {
    const d = (try config.dataDir(arena, env)) orelse return null;
    return try std.fs.path.join(arena, &.{ d, "backends", "llama" });
}

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
    \\usage: aimgr setup-backends [ollama|llama|all] [--cpu] [--yes] [--dry-run]
    \\  Windows only: downloads Ollama and/or llama.cpp (official releases, SHA-256 checked) into aimgr's data
    \\  folder. Without a name, whatever is missing. --cpu: the CPU build of llama.cpp even with a GPU.
    \\
;

const Job = struct { which: Backend, dir: []const u8, exe: []const u8, assets: []const Asset };

pub fn main(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, out: *std.Io.Writer, err: *std.Io.Writer, args: []const [:0]const u8) !u8 {
    if (builtin.os.tag != .windows) {
        try out.writeAll("setup-backends is only for Windows. On Linux install ollama / llama.cpp with your package manager.\n");
        return 0;
    }
    var yes = false;
    var dry = false;
    var force_cpu = false;
    var want_ollama = true;
    var want_llama = true;
    var named = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--yes")) {
            yes = true;
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            dry = true;
        } else if (std.mem.eql(u8, a, "--cpu")) {
            force_cpu = true;
        } else if (!named and (std.mem.eql(u8, a, "ollama") or std.mem.eql(u8, a, "llama") or std.mem.eql(u8, a, "all"))) {
            named = true;
            want_ollama = !std.mem.eql(u8, a, "llama");
            want_llama = !std.mem.eql(u8, a, "ollama");
        } else {
            try err.writeAll(usage);
            return 2;
        }
    }

    const hw = try hardware.detect(arena, gpa, io);
    var jobs: std.ArrayList(Job) = .empty;
    inline for (.{ Backend.ollama, Backend.llama }) |which| {
        const wanted = if (which == .ollama) want_ollama else want_llama;
        if (wanted) {
            const dir = (try (if (which == .ollama) ollamaDir(arena, env) else llamaDir(arena, env))) orelse {
                try err.writeAll("aimgr: cannot determine a data folder (USERPROFILE / LOCALAPPDATA not set)\n");
                return 1;
            };
            const exe = try std.fs.path.join(arena, &.{ dir, if (which == .ollama) "ollama.exe" else "llama.exe" });
            if (std.Io.Dir.cwd().access(io, exe, .{})) |_| {
                try out.print("{s} is already installed: {s}\n  (to reinstall, delete that folder yourself and run this again)\n", .{ if (which == .ollama) "Ollama" else "llama.cpp", dir });
            } else |_| {
                const assets = if (which == .ollama) try plan(arena, builtin.cpu.arch, hw.gpus) else try planLlama(arena, builtin.cpu.arch, hw.gpus, force_cpu);
                try jobs.append(arena, .{ .which = which, .dir = dir, .exe = exe, .assets = assets });
            }
        }
    }
    if (jobs.items.len == 0) return 0;

    var total: u64 = 0;
    for (jobs.items) |j| {
        if (j.which == .ollama) {
            try out.print("\nOllama {s} from github.com/ollama/ollama into:\n  {s}\n", .{ version, j.dir });
        } else try out.print("\nllama.cpp {s} from github.com/ggml-org/llama.cpp into:\n  {s}\n", .{ llama_build, j.dir });
        for (j.assets) |a| {
            total += a.size;
            try out.print("  {s}  ({d:.2} GB)  {s}\n", .{ a.name, @as(f64, @floatFromInt(a.size)) / 1e9, a.why });
        }
    }
    try out.print("\nTotal {d:.2} GB to download. Each file is checked against a pinned SHA-256.\n", .{@as(f64, @floatFromInt(total)) / 1e9});
    if (dry) return 0;
    try out.flush();
    if (!yes and !supervise.confirm(.{ .gpa = gpa, .io = io, .environ = env, .out = out, .err = err, .log_dir = null }, "Download and install?")) {
        try out.writeAll("cancelled; nothing was downloaded\n");
        return 1;
    }

    for (jobs.items) |j| {
        const parent = std.fs.path.dirname(j.dir).?;
        try std.Io.Dir.cwd().createDirPath(io, parent);
        const staging = try std.fmt.allocPrint(arena, "{s}.new", .{j.dir});
        std.Io.Dir.cwd().createDirPath(io, staging) catch {};
        for (j.assets) |a| {
            const zip_path = try std.fs.path.join(arena, &.{ parent, a.name });
            try out.print("\nDownloading {s} ...\n", .{a.name});
            try out.flush();
            download(gpa, io, out, try std.fmt.allocPrint(arena, "{s}{s}", .{ a.base, a.name }), zip_path, a.size) catch |e| {
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
        try std.Io.Dir.rename(std.Io.Dir.cwd(), staging, std.Io.Dir.cwd(), j.dir, io);
        if (j.which == .ollama) {
            try out.print("\nOllama installed in {s}. Start it with: aimgr serve ollama\n", .{j.dir});
        } else try out.print("\nllama.cpp installed in {s}. Download a model with 'aimgr pull llama OWNER/REPO:QUANT' or from the TUI.\n", .{j.dir});
    }
    try out.writeAll("aimgr finds the installed programs automatically.\n");
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
    if (!std.mem.startsWith(u8, url, "https://github.com/ollama/ollama/releases/download/") and !std.mem.startsWith(u8, url, "https://github.com/ggml-org/llama.cpp/releases/download/")) return error.NetworkFailed;
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

test "llama plan: Vulkan with a real GPU, CPU otherwise" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const amd = hardware.Gpu{ .vendor = .amd, .label = "x", .vram_total = 12 << 30, .source = "t" };
    const igpu = hardware.Gpu{ .vendor = .intel, .label = "x", .vram_total = 1 << 28, .integrated = true, .source = "t" };
    try std.testing.expect(std.mem.indexOf(u8, (try planLlama(a.allocator(), .x86_64, &.{amd}, false))[0].name, "vulkan-x64") != null);
    try std.testing.expect(std.mem.indexOf(u8, (try planLlama(a.allocator(), .x86_64, &.{igpu}, false))[0].name, "cpu-x64") != null);
    try std.testing.expect(std.mem.indexOf(u8, (try planLlama(a.allocator(), .x86_64, &.{amd}, true))[0].name, "cpu-x64") != null);
    try std.testing.expect(std.mem.indexOf(u8, (try planLlama(a.allocator(), .aarch64, &.{}, false))[0].name, "cpu-arm64") != null);
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
