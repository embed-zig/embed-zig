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

    const gstd_stub_mod = b.createModule(.{
        .root_source_file = b.path("src/gstd_stub.zig"),
        .target = target,
        .optimize = optimize,
    });
    const gpio_mod = b.createModule(.{
        .root_source_file = b.path("../../../desktop/lib/device/gpio.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "embed", .module = embed_dep.module("embed") },
            .{ .name = "glib", .module = glib_dep.module("glib") },
            .{ .name = "gstd", .module = gstd_stub_mod },
        },
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "embed", .module = embed_dep.module("embed") },
            .{ .name = "desktop_gpio", .module = gpio_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "desktop_gpio_smoke",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the desktop GPIO smoke example");
    run_step.dependOn(&run_cmd.step);

    const build_step = b.step("build", "Build the desktop GPIO smoke example");
    build_step.dependOn(&exe.step);
    b.default_step = build_step;
}
