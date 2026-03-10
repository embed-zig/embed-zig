const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const embed_dep = b.dependency("embed_zig", .{
        .target = target,
        .optimize = optimize,
    });
    const embed_mod = embed_dep.module("embed");

    const fw_mod = b.createModule(.{
        .root_source_file = embed_dep.path("test/firmware/100-button_led_cycle/app.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "embed", .module = embed_mod }},
    });

    const board_mod = b.createModule(.{
        .root_source_file = b.path("board/websim.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "embed", .module = embed_mod }},
    });

    const exe = b.addExecutable(.{
        .name = "websim-100",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "embed", .module = embed_mod },
                .{ .name = "firmware_app", .module = fw_mod },
                .{ .name = "board", .module = board_mod },
            },
        }),
    });

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run websim 100-button_led_cycle").dependOn(&run.step);
    b.getInstallStep().dependOn(&b.addInstallArtifact(exe, .{}).step);
}
