//! "Which package provides this tool, and how do I install it here?" Used when a tool the agent needs is
//! missing, so the model can tell the user the exact command (the user runs it themselves, e.g. with `!`).
const std = @import("std");
const builtin = @import("builtin");

pub const Need = enum { tesseract, pdftotext };

pub const Family = enum { debian, fedora, arch, suse, alpine, windows, unknown };

/// From /etc/os-release text: ID and ID_LIKE decide the family.
pub fn familyFromOsRelease(text: []const u8) Family {
    var it = std.mem.splitScalar(u8, text, '\n');
    var ids: [2][]const u8 = .{ "", "" };
    while (it.next()) |l| {
        const t = std.mem.trim(u8, l, " \r");
        if (std.mem.startsWith(u8, t, "ID=")) ids[0] = std.mem.trim(u8, t[3..], "\"");
        if (std.mem.startsWith(u8, t, "ID_LIKE=")) ids[1] = std.mem.trim(u8, t[8..], "\"");
    }
    for (ids) |v| {
        var words = std.mem.tokenizeScalar(u8, v, ' ');
        while (words.next()) |w| {
            if (eq(w, "debian") or eq(w, "ubuntu")) return .debian;
            if (eq(w, "fedora") or eq(w, "rhel") or eq(w, "centos")) return .fedora;
            if (eq(w, "arch")) return .arch;
            if (eq(w, "suse") or eq(w, "opensuse") or std.mem.startsWith(u8, w, "opensuse")) return .suse;
            if (eq(w, "alpine")) return .alpine;
        }
    }
    return .unknown;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn family(io: std.Io) Family {
    if (builtin.os.tag == .windows) return .windows;
    var buf: [4096]u8 = undefined;
    const text = std.Io.Dir.cwd().readFile(io, "/etc/os-release", &buf) catch return .unknown;
    return familyFromOsRelease(text);
}

/// The install command for `need` on `fam`, or null when there is no well-known one.
pub fn command(need: Need, fam: Family) ?[]const u8 {
    return switch (need) {
        .tesseract => switch (fam) {
            .debian => "sudo apt install tesseract-ocr",
            .fedora => "sudo dnf install tesseract",
            .arch => "sudo pacman -S tesseract tesseract-data-eng",
            .suse => "sudo zypper install tesseract-ocr",
            .alpine => "sudo apk add tesseract-ocr",
            .windows => "winget install UB-Mannheim.TesseractOCR",
            .unknown => null,
        },
        .pdftotext => switch (fam) {
            .debian => "sudo apt install poppler-utils",
            .fedora => "sudo dnf install poppler-utils",
            .alpine => "sudo apk add poppler-utils",
            .arch => "sudo pacman -S poppler",
            .suse => "sudo zypper install poppler-tools",
            .windows, .unknown => null,
        },
    };
}

/// A sentence for the model to pass on to the user.
pub fn advice(arena: std.mem.Allocator, io: std.Io, need: Need) ![]const u8 {
    const fam = family(io);
    const pkg: []const u8 = switch (need) {
        .tesseract => "Tesseract OCR",
        .pdftotext => "Poppler (pdftotext)",
    };
    if (command(need, fam)) |c| {
        return std.fmt.allocPrint(arena, "{s} is not installed. Tell the user to install it with:  {s}   (they can type it with a leading '!' in this session, e.g. !{s}, or run it in another terminal), then ask again.", .{ pkg, c, c });
    }
    return std.fmt.allocPrint(arena, "{s} is not installed. Tell the user to install {s} with their system's package manager, then ask again.", .{ pkg, pkg });
}

test "families and commands" {
    try std.testing.expectEqual(Family.debian, familyFromOsRelease("NAME=\"Ubuntu\"\nID=ubuntu\nID_LIKE=debian\n"));
    try std.testing.expectEqual(Family.fedora, familyFromOsRelease("ID=\"rocky\"\nID_LIKE=\"rhel centos fedora\"\n"));
    try std.testing.expectEqual(Family.arch, familyFromOsRelease("ID=endeavouros\nID_LIKE=arch\n"));
    try std.testing.expectEqual(Family.suse, familyFromOsRelease("ID=\"opensuse-tumbleweed\"\nID_LIKE=\"opensuse suse\"\n"));
    try std.testing.expectEqual(Family.unknown, familyFromOsRelease("ID=plan9\n"));
    try std.testing.expectEqualStrings("sudo apt install tesseract-ocr", command(.tesseract, .debian).?);
}
