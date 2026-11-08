//! Backend-neutral typed records. Backend IDs are preserved exactly.
const std = @import("std");

pub const Kind = enum {
    ollama,
    llama,

    pub fn name(self: Kind) []const u8 {
        return @tagName(self);
    }
};

/// One installed model as reported by a backend. All strings are owned by the
/// arena used for listing. Fields not reported by the backend stay null.
pub const Model = struct {
    backend: Kind,
    /// Exact backend identifier (ollama NAME, llama cache entry).
    id: []const u8,
    /// Backend-reported content ID, if any (ollama ID column).
    digest: ?[]const u8 = null,
    /// Size text exactly as reported (e.g. "4.7 GB").
    size_text: ?[]const u8 = null,
    modified: ?[]const u8 = null,
    /// Quantization only when explicit in the identifier (llama "repo:QUANT").
    quant: ?[]const u8 = null,
};

pub const ProbeStatus = union(enum) {
    available: []const u8, // version string
    missing,
    failed: []const u8, // reason
};

pub const ListError = error{
    BackendMissing,
    BackendFailed,
    UnsupportedFormat,
    OutOfMemory,
};

/// Operations a backend supports at this version. Unsupported ones are explicit.
pub const Capabilities = struct {
    list: bool,
    pull: bool,
    remove: bool,
    remove_reason: ?[]const u8 = null,
};

/// "17 GB", "4.7 GB", "512 MB" -> bytes (decimal units, as ollama prints). Null if unparseable.
pub fn parseSizeText(text: ?[]const u8) ?u64 {
    const t = std.mem.trim(u8, text orelse return null, " ");
    const sp = std.mem.indexOfScalar(u8, t, ' ') orelse return null;
    const num = std.fmt.parseFloat(f64, t[0..sp]) catch return null;
    const unit = std.mem.trim(u8, t[sp + 1 ..], " ");
    const mult: f64 = if (std.ascii.eqlIgnoreCase(unit, "B")) 1 else if (std.ascii.eqlIgnoreCase(unit, "KB")) 1e3 else if (std.ascii.eqlIgnoreCase(unit, "MB")) 1e6 else if (std.ascii.eqlIgnoreCase(unit, "GB")) 1e9 else if (std.ascii.eqlIgnoreCase(unit, "TB")) 1e12 else return null;
    if (num < 0) return null;
    return @intFromFloat(num * mult);
}
