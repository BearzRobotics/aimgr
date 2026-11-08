//! Linux listening-port check via /proc/net/tcp{,6} (state 0A = LISTEN).
//! Used to report "listening" accurately and to detect an existing daemon.
const std = @import("std");

/// True if `text` (contents of /proc/net/tcp or tcp6) has a LISTEN socket on `port`.
pub fn hasListener(text: []const u8, port: u16) bool {
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    _ = it.next(); // header
    while (it.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        _ = f.next() orelse continue; // sl
        const local = f.next() orelse continue;
        _ = f.next() orelse continue; // rem_address
        const st = f.next() orelse continue;
        if (!std.mem.eql(u8, st, "0A")) continue;
        const colon = std.mem.lastIndexOfScalar(u8, local, ':') orelse continue;
        const p = std.fmt.parseInt(u16, local[colon + 1 ..], 16) catch continue;
        if (p == port) return true;
    }
    return false;
}

/// Read a (possibly size-0) /proc file by streaming; readFileAlloc cannot be used
/// because procfs files report a size of 0.
pub fn readProc(gpa: std.mem.Allocator, io: std.Io, path: []const u8, limit: usize) ![]u8 {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    var r = f.readerStreaming(io, &buf);
    return r.interface.allocRemaining(gpa, .limited(limit));
}

pub fn isListening(gpa: std.mem.Allocator, io: std.Io, port: u16) bool {
    if (@import("builtin").os.tag == .windows) {
        // No /proc: try to connect to the loopback port.
        const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch return false;
        var stream = addr.connect(io, .{ .mode = .stream, .timeout = .{ .duration = .{ .raw = .fromMilliseconds(500), .clock = .awake } } }) catch return false;
        stream.close(io);
        return true;
    }
    for ([_][]const u8{ "/proc/net/tcp", "/proc/net/tcp6" }) |path| {
        const text = readProc(gpa, io, path, 8 << 20) catch continue;
        defer gpa.free(text);
        if (hasListener(text, port)) return true;
    }
    return false;
}

test "detects listener" {
    const t =
        \\  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
        \\   0: 0100007F:2CAA 00000000:0000 0A 00000000:00000000 00:00000000 00000000   110        0 1 1 0
        \\   1: 0100007F:1F90 0100007F:9999 01 00000000:00000000 00:00000000 00000000   110        0 1 1 0
        \\
    ;
    try std.testing.expect(hasListener(t, 0x2CAA)); // 11434
    try std.testing.expect(!hasListener(t, 0x1F90)); // established, not listening
    try std.testing.expect(!hasListener(t, 9931));
}

test "readProc reads real procfs" {
    const t = try readProc(std.testing.allocator, std.testing.io, "/proc/net/tcp", 8 << 20);
    defer std.testing.allocator.free(t);
    try std.testing.expect(t.len > 100);
}
