//! Hardware inspection (Linux) and an ADVISORY memory-fit estimate.
//! Sources: /proc/meminfo; AMD/Intel/other GPUs via /sys/class/drm (amdgpu
//! exposes mem_info_vram_*); NVIDIA via `nvidia-smi` when installed. Nothing
//! here is a promise: architectures differ (GQA, MoE, sliding windows) and
//! quantization sizes are approximate, so estimates are ranges.
const std = @import("std");
const netstat = @import("netstat.zig");
const process = @import("process.zig");
const builtin = @import("builtin");

const MEMORYSTATUSEX = extern struct {
    length: u32 = @sizeOf(MEMORYSTATUSEX),
    load: u32 = 0,
    total_phys: u64 = 0,
    avail_phys: u64 = 0,
    total_page: u64 = 0,
    avail_page: u64 = 0,
    total_virtual: u64 = 0,
    avail_virtual: u64 = 0,
    avail_ext: u64 = 0,
};
extern "kernel32" fn GlobalMemoryStatusEx(*MEMORYSTATUSEX) callconv(.winapi) c_int;

fn containsFold(h: []const u8, n: []const u8) bool {
    if (n.len > h.len) return false;
    var i: usize = 0;
    while (i + n.len <= h.len) : (i += 1) if (std.ascii.eqlIgnoreCase(h[i .. i + n.len], n)) return true;
    return false;
}

/// "Name|bytes" lines (as printed by the PowerShell query in detectWindows) -> GPUs.
pub fn parseWindowsGpus(arena: std.mem.Allocator, text: []const u8, gpus: *std.ArrayList(Gpu)) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        const t = std.mem.trim(u8, l, " \r\t");
        const bar = std.mem.lastIndexOfScalar(u8, t, '|') orelse continue;
        const name = std.mem.trim(u8, t[0..bar], " ");
        const bytes = std.fmt.parseInt(u64, std.mem.trim(u8, t[bar + 1 ..], " "), 10) catch continue;
        if (name.len == 0 or bytes == 0) continue;
        if (containsFold(name, "basic")) continue; // Microsoft Basic Display Adapter
        const vendor: Vendor = if (containsFold(name, "nvidia")) .nvidia else if (containsFold(name, "amd") or containsFold(name, "radeon")) .amd else if (containsFold(name, "intel")) .intel else .other;
        try gpus.append(arena, .{ .vendor = vendor, .label = try arena.dupe(u8, name), .vram_total = bytes, .integrated = bytes < (1 << 30), .source = "windows registry" });
    }
}

fn detectWindows(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io) !Info {
    var info: Info = .{ .mem = .{}, .gpus = &.{} };
    var ms: MEMORYSTATUSEX = .{};
    if (GlobalMemoryStatusEx(&ms) != 0) info.mem = .{ .total = ms.total_phys, .available = ms.avail_phys };
    var gpus: std.ArrayList(Gpu) = .empty;
    const nv = process.run(gpa, io, &.{ "nvidia-smi", "--query-gpu=name,memory.total,memory.used", "--format=csv,noheader,nounits" }, 10);
    defer nv.deinit(gpa);
    if (nv.ok()) try parseNvidiaSmi(arena, nv.stdout, &gpus);
    if (gpus.items.len == 0) {
        const ps =
            "Get-ItemProperty 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Class\\{4d36e968-e325-11cd-bfc1-08002be10318}\\0*' -ErrorAction SilentlyContinue | " ++
            "ForEach-Object { $_.DriverDesc + '|' + $_.'HardwareInformation.qwMemorySize' }";
        const r = process.run(gpa, io, &.{ "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", ps }, 15);
        defer r.deinit(gpa);
        if (r.ok()) try parseWindowsGpus(arena, r.stdout, &gpus);
    }
    info.gpus = try gpus.toOwnedSlice(arena);
    return info;
}

pub const Memory = struct { total: u64 = 0, available: u64 = 0 };

pub const Vendor = enum { amd, nvidia, intel, other };

pub const Gpu = struct {
    vendor: Vendor,
    /// Vendor/device ids from sysfs ("0x1002:0x747e") or the nvidia-smi name.
    label: []const u8,
    vram_total: u64,
    vram_used: ?u64 = null,
    /// Integrated GPUs share system RAM; a tiny carve-out is not usable VRAM for models.
    integrated: bool = false,
    source: []const u8,

    pub fn free(self: Gpu) u64 {
        const used = self.vram_used orelse 0;
        return if (self.vram_total > used) self.vram_total - used else 0;
    }
};

pub const Info = struct {
    mem: Memory,
    gpus: []Gpu,
    /// Largest discrete GPU, if any.
    pub fn bestGpu(self: Info) ?Gpu {
        var best: ?Gpu = null;
        for (self.gpus) |g| {
            if (g.integrated) continue;
            if (best == null or g.vram_total > best.?.vram_total) best = g;
        }
        return best;
    }
};

pub fn parseMeminfo(text: []const u8) Memory {
    var m: Memory = .{};
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |line| {
        const target: *u64 = if (std.mem.startsWith(u8, line, "MemTotal:")) &m.total else if (std.mem.startsWith(u8, line, "MemAvailable:")) &m.available else continue;
        var f = std.mem.tokenizeAny(u8, line, " \t");
        _ = f.next();
        const kb = std.fmt.parseInt(u64, f.next() orelse continue, 10) catch continue;
        target.* = kb * 1024;
    }
    return m;
}

/// `nvidia-smi --query-gpu=name,memory.total,memory.used --format=csv,noheader,nounits` (MiB).
pub fn parseNvidiaSmi(arena: std.mem.Allocator, text: []const u8, out: *std.ArrayList(Gpu)) !void {
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |line| {
        var f = std.mem.splitSequence(u8, line, ", ");
        const name = std.mem.trim(u8, f.next() orelse continue, " \r");
        const total = std.fmt.parseInt(u64, std.mem.trim(u8, f.next() orelse continue, " \r"), 10) catch continue;
        const used = std.fmt.parseInt(u64, std.mem.trim(u8, f.next() orelse continue, " \r"), 10) catch null;
        try out.append(arena, .{
            .vendor = .nvidia,
            .label = try arena.dupe(u8, name),
            .vram_total = total * 1024 * 1024,
            .vram_used = if (used) |u| u * 1024 * 1024 else null,
            .source = "nvidia-smi",
        });
    }
}

fn vendorOf(id: []const u8) Vendor {
    if (std.mem.eql(u8, id, "0x1002")) return .amd;
    if (std.mem.eql(u8, id, "0x10de")) return .nvidia;
    if (std.mem.eql(u8, id, "0x8086")) return .intel;
    return .other;
}

fn readSys(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?[]u8 {
    const t = netstat.readProc(gpa, io, path, 4096) catch return null;
    return t;
}

fn readU64(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?u64 {
    const t = readSys(gpa, io, path) orelse return null;
    defer gpa.free(t);
    return std.fmt.parseInt(u64, std.mem.trim(u8, t, " \r\n"), 10) catch null;
}

pub fn detect(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io) !Info {
    if (builtin.os.tag == .windows) return detectWindows(arena, gpa, io);
    var info: Info = .{ .mem = .{}, .gpus = &.{} };
    if (netstat.readProc(gpa, io, "/proc/meminfo", 1 << 16)) |t| {
        defer gpa.free(t);
        info.mem = parseMeminfo(t);
    } else |_| {}

    var gpus: std.ArrayList(Gpu) = .empty;
    // NVIDIA proprietary driver exposes no VRAM in sysfs: ask nvidia-smi if present.
    const r = process.run(gpa, io, &.{ "nvidia-smi", "--query-gpu=name,memory.total,memory.used", "--format=csv,noheader,nounits" }, 10);
    defer r.deinit(gpa);
    if (r.ok()) try parseNvidiaSmi(arena, r.stdout, &gpus);

    // amdgpu (and others that implement mem_info_vram_total) via sysfs.
    var dir = std.Io.Dir.cwd().openDir(io, "/sys/class/drm", .{ .iterate = true }) catch {
        info.gpus = try gpus.toOwnedSlice(arena);
        return info;
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const n = entry.name;
        if (!std.mem.startsWith(u8, n, "card") or std.mem.indexOfScalar(u8, n, '-') != null) continue;
        const base = try std.fmt.allocPrint(arena, "/sys/class/drm/{s}/device", .{n});
        const vendor_txt = readSys(gpa, io, try std.fmt.allocPrint(arena, "{s}/vendor", .{base})) orelse continue;
        defer gpa.free(vendor_txt);
        const vendor_id = std.mem.trim(u8, vendor_txt, " \r\n");
        const vendor = vendorOf(vendor_id);
        if (vendor == .nvidia and gpus.items.len > 0) continue; // already reported by nvidia-smi
        const total = readU64(gpa, io, try std.fmt.allocPrint(arena, "{s}/mem_info_vram_total", .{base})) orelse continue;
        const used = readU64(gpa, io, try std.fmt.allocPrint(arena, "{s}/mem_info_vram_used", .{base}));
        const dev_txt = readSys(gpa, io, try std.fmt.allocPrint(arena, "{s}/device", .{base}));
        defer if (dev_txt) |d| gpa.free(d);
        const dev_id = if (dev_txt) |d| std.mem.trim(u8, d, " \r\n") else "?";
        try gpus.append(arena, .{
            .vendor = vendor,
            .label = try std.fmt.allocPrint(arena, "{s}:{s} ({s})", .{ vendor_id, dev_id, n }),
            .vram_total = total,
            .vram_used = used,
            // A 512 MiB carve-out is an iGPU frame buffer, not usable model memory.
            .integrated = total < (1 << 30),
            .source = "/sys/class/drm",
        });
    }
    info.gpus = try gpus.toOwnedSlice(arena);
    return info;
}

// ---- estimation -----------------------------------------------------------

/// "Qwen2.5-Coder-14B-Instruct", "llama3.2:3b", "gemma4:12b", "tiny-0.5b" -> billions of parameters.
/// Null for unclear names (including "8x7b" mixtures, which are not guessed).
pub fn parseParamsB(id: []const u8) ?f64 {
    var best: ?f64 = null;
    var i: usize = 0;
    while (i < id.len) : (i += 1) {
        if (!std.ascii.isDigit(id[i])) continue;
        if (i > 0 and (std.ascii.isAlphabetic(id[i - 1]))) {
            // digits glued to a preceding letter ("a3b", "q4") are not a size
            while (i < id.len and (std.ascii.isDigit(id[i]) or id[i] == '.')) i += 1;
            continue;
        }
        var j = i;
        while (j < id.len and (std.ascii.isDigit(id[j]) or id[j] == '.')) j += 1;
        if (j < id.len and (id[j] == 'b' or id[j] == 'B') and (j + 1 >= id.len or !std.ascii.isAlphabetic(id[j + 1]))) {
            if (i >= 1 and id[i - 1] == 'x') return null; // MoE like 8x7b
            if (j + 1 < id.len or true) {
                const v = std.fmt.parseFloat(f64, id[i..j]) catch {
                    i = j;
                    continue;
                };
                if (v >= 0.1 and v <= 2000) {
                    if (best == null or v > best.?) best = v;
                }
            }
        }
        i = j;
    }
    return best;
}

/// Approximate bytes per parameter by quantization label (llama.cpp bits-per-weight / 8).
pub fn bytesPerParam(quant: []const u8) ?f64 {
    const table = [_]struct { []const u8, f64 }{
        .{ "F32", 4.0 },       .{ "F16", 2.0 },       .{ "BF16", 2.0 },      .{ "Q8_0", 1.0625 },
        .{ "Q6_K", 0.8203 },   .{ "Q5_K_M", 0.7109 }, .{ "Q5_K_S", 0.6914 }, .{ "Q5_0", 0.6875 },
        .{ "Q4_K_M", 0.6055 }, .{ "Q4_K_S", 0.5703 }, .{ "Q4_0", 0.5625 },   .{ "MXFP4", 0.5313 },
        .{ "Q3_K_M", 0.4766 }, .{ "Q2_K", 0.3359 },
    };
    for (table) |e| if (std.ascii.eqlIgnoreCase(e[0], quant)) return e[1];
    return null;
}

pub const Verdict = enum {
    fits_gpu,
    maybe_fits_gpu,
    needs_offload,
    cpu_ok,
    unlikely,
    unknown,

    pub fn text(self: Verdict) []const u8 {
        return switch (self) {
            .fits_gpu => "likely fits in GPU memory",
            .maybe_fits_gpu => "may fit in GPU memory (depends on architecture and context)",
            .needs_offload => "too big for GPU memory alone; would need CPU/RAM offload (slower)",
            .cpu_ok => "no usable GPU found; fits in system RAM (CPU speed)",
            .unlikely => "unlikely to fit in GPU + system memory",
            .unknown => "cannot estimate (size unknown)",
        };
    }
};

pub const Fit = struct {
    verdict: Verdict,
    weights: u64 = 0,
    weights_estimated: bool = false,
    need_low: u64 = 0,
    need_high: u64 = 0,
    ctx: u32,
};

const mib: f64 = 1024 * 1024;

/// `reported_bytes`: size the backend reported (preferred). Otherwise weights are
/// estimated from parameter count (name) x quantization, flagged as estimated.
pub fn estimate(id: []const u8, quant: ?[]const u8, reported_bytes: ?u64, ctx: u32, hw: Info) Fit {
    return estimateWith(id, quant, reported_bytes, null, ctx, hw);
}

/// Like `estimate`, preferring an exact parameter count (from `ollama show` or the catalog) over
/// one parsed from the name.
pub fn estimateWith(id: []const u8, quant: ?[]const u8, reported_bytes: ?u64, params_override: ?f64, ctx: u32, hw: Info) Fit {
    var f: Fit = .{ .verdict = .unknown, .ctx = ctx };
    const params_b = params_override orelse parseParamsB(id);
    if (reported_bytes) |b| {
        f.weights = b;
    } else if (params_b != null and quant != null and bytesPerParam(quant.?) != null) {
        f.weights = @intFromFloat(params_b.? * 1e9 * bytesPerParam(quant.?).?);
        f.weights_estimated = true;
    } else return f;

    // KV cache per token per billion parameters spans roughly 0.01 MiB (strong GQA)
    // to 0.075 MiB (full multi-head) across common dense models: a range, not a guess.
    const pb = params_b orelse (@as(f64, @floatFromInt(f.weights)) / 0.6 / 1e9); // rough B-params from bytes
    const kv_low = pb * 0.01 * mib * @as(f64, @floatFromInt(ctx));
    const kv_high = pb * 0.075 * mib * @as(f64, @floatFromInt(ctx));
    const w: f64 = @floatFromInt(f.weights);
    f.need_low = @intFromFloat(w * 1.03 + kv_low + 0.3 * 1024 * mib);
    f.need_high = @intFromFloat(w * 1.10 + kv_high + 0.8 * 1024 * mib);

    if (hw.bestGpu()) |g| {
        const free = g.free();
        if (f.need_high <= free) {
            f.verdict = .fits_gpu;
        } else if (f.need_low <= free) {
            f.verdict = .maybe_fits_gpu;
        } else if (f.need_low <= free + hw.mem.available) {
            f.verdict = .needs_offload;
        } else f.verdict = .unlikely;
    } else {
        f.verdict = if (f.need_high <= hw.mem.available) .cpu_ok else if (f.need_low <= hw.mem.available) .cpu_ok else .unlikely;
    }
    return f;
}

pub fn gb(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / 1e9;
}

test "windows gpu lines" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    var g: std.ArrayList(Gpu) = .empty;
    try parseWindowsGpus(a.allocator(), "AMD Radeon RX 7800 XT|17163091968\r\nMicrosoft Basic Display Adapter|1\r\nIntel(R) UHD Graphics|134217728\r\n", &g);
    try std.testing.expectEqual(@as(usize, 2), g.items.len);
    try std.testing.expect(g.items[0].vendor == .amd);
    try std.testing.expect(g.items[1].integrated);
}

test "meminfo" {
    const m = parseMeminfo("MemTotal:       31407724 kB\nMemFree: 1 kB\nMemAvailable:   25611384 kB\n");
    try std.testing.expectEqual(@as(u64, 31407724 * 1024), m.total);
    try std.testing.expectEqual(@as(u64, 25611384 * 1024), m.available);
}

test "nvidia-smi parse" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    var l: std.ArrayList(Gpu) = .empty;
    try parseNvidiaSmi(a.allocator(), "NVIDIA GeForce RTX 4070, 12282, 1024\n", &l);
    try std.testing.expectEqual(@as(usize, 1), l.items.len);
    try std.testing.expectEqual(@as(u64, 12282 * 1024 * 1024), l.items[0].vram_total);
    try std.testing.expectEqual(@as(u64, 1024 * 1024 * 1024), l.items[0].vram_used.?);
}

test "parse parameter counts from names" {
    try std.testing.expectEqual(@as(?f64, 14.0), parseParamsB("Qwen/Qwen2.5-Coder-14B-Instruct-GGUF:Q4_K_M"));
    try std.testing.expectEqual(@as(?f64, 27.0), parseParamsB("qwen3.8:27b"));
    try std.testing.expectEqual(@as(?f64, 0.8), parseParamsB("ggml-org/Qwen3.5-0.8B-GGUF:Q8_0"));
    try std.testing.expectEqual(@as(?f64, 30.0), parseParamsB("ggml-org/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q4_K_M"));
    try std.testing.expectEqual(@as(?f64, 20.0), parseParamsB("ggml-org/gpt-oss-20b-GGUF:MXFP4"));
    try std.testing.expectEqual(@as(?f64, null), parseParamsB("mistral-8x7b"));
    try std.testing.expectEqual(@as(?f64, null), parseParamsB("some-model:latest"));
    try std.testing.expectEqual(@as(?f64, 12.0), parseParamsB("inflatebot/MN-12B-Mag-Mell-R1-GGUF:Q4_K_M"));
}

fn testHw(storage: *[1]Gpu, vram: u64, ram: u64) Info {
    storage[0] = .{ .vendor = .amd, .label = "t", .vram_total = vram, .vram_used = 0, .source = "t" };
    return .{ .mem = .{ .total = ram, .available = ram }, .gpus = storage };
}

test "fit verdicts" {
    var storage: [1]Gpu = undefined;
    const hw = testHw(&storage, 12 * 1000 * 1000 * 1000, 25 * 1000 * 1000 * 1000);
    // 0.8B Q8_0 -> tiny
    try std.testing.expectEqual(Verdict.fits_gpu, estimate("Qwen3.5-0.8B", "Q8_0", null, 4096, hw).verdict);
    // 14B Q4_K_M ~8.5 GB + kv: in the uncertain band for 12 GB
    const mid = estimate("Qwen2.5-Coder-14B", "Q4_K_M", null, 4096, hw);
    try std.testing.expect(mid.verdict == .fits_gpu or mid.verdict == .maybe_fits_gpu);
    try std.testing.expect(mid.weights_estimated);
    // 27B reported 17 GB: too big for 12 GB VRAM but fits with RAM offload
    try std.testing.expectEqual(Verdict.needs_offload, estimate("qwen3.8:27b", null, 17_000_000_000, 4096, hw).verdict);
    // 70B Q8 is ~74 GB: beyond VRAM + RAM
    try std.testing.expectEqual(Verdict.unlikely, estimate("llama-70b", "Q8_0", null, 4096, hw).verdict);
    // unknown size
    try std.testing.expectEqual(Verdict.unknown, estimate("mystery", null, null, 4096, hw).verdict);
    // no GPU -> cpu
    const cpu: Info = .{ .mem = .{ .total = 31e9, .available = 25e9 }, .gpus = &.{} };
    try std.testing.expectEqual(Verdict.cpu_ok, estimate("Qwen3.5-0.8B", "Q8_0", null, 4096, cpu).verdict);
}
