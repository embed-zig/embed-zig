const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const embed_dep = b.dependency("embed", .{
        .target = target,
        .optimize = optimize,
    });
    const glib_dep = b.dependency("glib", .{
        .target = target,
        .optimize = optimize,
    });
    const gstd_dep = b.dependency("gstd", .{
        .target = target,
        .optimize = optimize,
    });
    const thirdparty_dep = b.dependency("thirdparty", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "embed", .module = embed_dep.module("embed") },
            .{ .name = "glib", .module = glib_dep.module("glib") },
            .{ .name = "gstd", .module = gstd_dep.module("gstd") },
            .{ .name = "core_bluetooth", .module = thirdparty_dep.module("core_bluetooth") },
            .{ .name = "kcp", .module = thirdparty_dep.module("kcp") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "cmdctl",
        .root_module = mod,
    });
    exe.linkLibC();
    const install = b.addInstallArtifact(exe, .{});

    const cmdctl_step = b.step("cmdctl", "Build the cmdctl host command tool");
    cmdctl_step.dependOn(&install.step);

    const unit_mod = b.createModule(.{
        .root_source_file = b.path("test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "cmdctl", .module = mod },
        },
    });
    const unit = b.addTest(.{
        .root_module = unit_mod,
    });
    unit.linkLibC();
    const run_unit = b.addRunArtifact(unit);
    const test_step = b.step("cmdctl-test", "Run cmdctl unit tests");
    test_step.dependOn(&run_unit.step);
}
