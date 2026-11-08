//! Safe argv-only child process execution. No shell is ever involved.
const std = @import("std");

pub const Outcome = union(enum) {
    /// Process ran; exit code attached.
    exited: u8,
    /// Process terminated by a signal or otherwise abnormally.
    abnormal,
    /// Executable could not be found.
    not_found,
    /// Executable found but could not be started (permissions, etc).
    spawn_failed,
    timed_out,
};

pub const Result = struct {
    outcome: Outcome,
    stdout: []u8 = &.{},
    stderr: []u8 = &.{},

    pub fn ok(self: Result) bool {
        return self.outcome == .exited and self.outcome.exited == 0;
    }

    pub fn deinit(self: Result, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

const max_output = 4 * 1024 * 1024;

/// Run `argv` to completion, capturing output. stdin is closed.
pub fn run(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, timeout_s: u32) Result {
    const r = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(timeout_s), .clock = .awake } },
    }) catch |err| return .{ .outcome = switch (err) {
        error.FileNotFound => .not_found,
        error.Timeout => .timed_out,
        else => .spawn_failed,
    } };
    return .{
        .outcome = switch (r.term) {
            .exited => |c| .{ .exited = c },
            else => .abnormal,
        },
        .stdout = r.stdout,
        .stderr = r.stderr,
    };
}
