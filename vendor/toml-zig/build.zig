//! toml-zig build script. `zig build test` runs all tests.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library module, importable by consumers as @import("toml").
    const mod = b.addModule("toml", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit and conformance tests");
    const unit = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(unit).step);

    // Checks that the code in docs/writing-toml.md parses.
    const guide_mod = b.createModule(.{
        .root_source_file = b.path("src/guide_tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "toml", .module = mod }},
    });
    guide_mod.addAnonymousImport("writing-toml.md", .{ .root_source_file = b.path("docs/writing-toml.md") });
    const guide_test = b.addTest(.{ .root_module = guide_mod });
    test_step.dependOn(&b.addRunArtifact(guide_test).step);

    // Baseline benchmark; always built ReleaseFast so numbers are comparable.
    const bench_step = b.step("bench", "Run the parse/write benchmark (ReleaseFast)");
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_mod.addImport("toml", b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    }));
    const bench_exe = b.addExecutable(.{ .name = "toml-bench", .root_module = bench_mod });
    bench_step.dependOn(&b.addRunArtifact(bench_exe).step);

    // A command line parser for comparing builds with `poop` (see the file).
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("bench/parse_file.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    cli_mod.addImport("toml", bench_mod.import_table.get("toml").?);
    const cli_exe = b.addExecutable(.{ .name = "toml-parse", .root_module = cli_mod });
    const cli_step = b.step("cli", "Build zig-out/bin/toml-parse for comparing with poop");
    cli_step.dependOn(&b.addInstallArtifact(cli_exe, .{}).step);
}
