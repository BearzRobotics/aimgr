const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Vendored, pinned TOML library (path dependency; no network at build time).
    const toml_dep = b.dependency("toml", .{ .target = target, .optimize = optimize });

    const mod = b.addModule("aimgr", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "toml", .module = toml_dep.module("toml") },
        },
    });
    // Bundled seed catalog, embedded at build time.
    mod.addAnonymousImport("models_toml", .{ .root_source_file = b.path("config/models.toml") });

    // libvaxis (pure Zig terminal UI), vendored and pinned. Its one dependency
    // (uucode) is vendored too and referenced by path from its build.zig.zon.
    const vaxis_dep = b.dependency("vaxis", .{ .target = target, .optimize = optimize });
    mod.addImport("vaxis", vaxis_dep.module("vaxis"));
    // md-zig (BearzRobotics/md-zig v0.3.0, vendored): renders the model's Markdown replies in the terminal.
    const md_dep = b.dependency("md", .{ .target = target, .optimize = optimize });
    mod.addImport("md", md_dep.module("md"));

    const exe = b.addExecutable(.{
        .name = "aimgr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aimgr", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);
    // Resources for `aimgr abliterate` (helper script, pinned llama.cpp converter).
    b.installDirectory(.{ .source_dir = b.path("tools/abliterate"), .install_dir = .prefix, .install_subdir = "share/aimgr/abliterate" });
    b.installDirectory(.{ .source_dir = b.path("docs/manpages"), .install_dir = .prefix, .install_subdir = "share/doc/aimgr" });
    b.installDirectory(.{ .source_dir = b.path("vendor/llama-convert"), .install_dir = .prefix, .install_subdir = "share/aimgr/llama-convert" });

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module })).step);
}
