//! A small program that renders a Markdown file in the terminal:
//!
//!     zig build && zig-out/bin/mdcat README.md [width]

const std = @import("std");
const md = @import("md");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.debug.print("usage: mdcat FILE [WIDTH]\n", .{});
        std.process.exit(2);
    }
    const width: usize = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 80;

    var file = try std.Io.Dir.cwd().openFile(io, args[1], .{});
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);

    var doc = try md.Document.parseReader(gpa, &reader.interface, .{ .extensions = md.Extensions.all });
    defer doc.deinit();

    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    try doc.writeText(gpa, &stdout.interface, .{ .width = width, .color = true });
    try stdout.interface.flush();
}
