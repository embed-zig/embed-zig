const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const embed_dep = b.dependency("embed_zig", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "bleterm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "embed", .module = embed_dep.module("embed") },
            },
        }),
    });

    if (target.result.os.tag == .macos) {
        exe.linkFramework("CoreBluetooth");
        exe.linkFramework("Foundation");
    }

    const run_exe = b.addRunArtifact(exe);
    if (b.args) |args| run_exe.addArgs(args);

    b.step("run", "Run bleterm CLI").dependOn(&run_exe.step);
    b.step("build-app", "Build bleterm CLI").dependOn(&exe.step);
}
