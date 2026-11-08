//! md-zig build script. `zig build test` runs all tests.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library module, importable by consumers as @import("md").
    const mod = b.addModule("md", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The specification's examples, compared byte for byte (src/tests.zig).
    mod.addAnonymousImport("spec-0.31.2.json", .{ .root_source_file = b.path("test/fixtures/spec-0.31.2.json") });

    mod.addAnonymousImport("gfm-extensions.json", .{ .root_source_file = b.path("test/fixtures/gfm-extensions.json") });

    // A small renderer for trying the library out: `zig build` then `zig-out/bin/mdcat FILE`.
    const mdcat = b.addExecutable(.{
        .name = "mdcat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/mdcat.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "md", .module = mod }},
        }),
    });
    b.installArtifact(mdcat);

    const test_step = b.step("test", "Run unit and conformance tests");
    const unit = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(unit).step);

    // Optional, experimental C interface (include/md.h): `zig build c-api`
    // installs libmd.a, libmd.so and md.h. The native module does not use it.
    const capi_mod = b.createModule(.{
        .root_source_file = b.path("src/capi.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "md", .module = mod }},
    });
    const static_lib = b.addLibrary(.{ .name = "md", .linkage = .static, .root_module = capi_mod });
    const shared_lib = b.addLibrary(.{ .name = "md", .linkage = .dynamic, .root_module = capi_mod });
    const c_api_step = b.step("c-api", "Build the experimental C library and header");
    c_api_step.dependOn(&b.addInstallArtifact(static_lib, .{}).step);
    c_api_step.dependOn(&b.addInstallArtifact(shared_lib, .{}).step);
    c_api_step.dependOn(&b.addInstallFileWithDir(b.path("include/md.h"), .header, "md.h").step);

    // A C program that uses the static library: part of `zig build test`.
    const smoke = b.addExecutable(.{
        .name = "c-smoke",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    smoke.root_module.addCSourceFile(.{ .file = b.path("test/c/smoke.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra" } });
    smoke.root_module.addIncludePath(b.path("include"));
    smoke.root_module.linkLibrary(static_lib);
    test_step.dependOn(&b.addRunArtifact(smoke).step);
}
