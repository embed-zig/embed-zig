const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const embed_dep = b.dependency("embed_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const embed_mod = embed_dep.module("embed");

    const platform_mod = b.createModule(.{
        .root_source_file = b.path("platform.zig"),
        .target = target,
        .optimize = optimize,
    });
    platform_mod.addImport("embed", embed_mod);

    const tests = b.addTest(.{
        .name = "fake_platform_test",
        .root_module = platform_mod,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run fake_platform integration tests");
    test_step.dependOn(&run_tests.step);
}
