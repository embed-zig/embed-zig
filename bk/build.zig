const std = @import("std");

pub const armino = @import("lib/armino.zig");
pub const boards = @import("build_boards.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const glib_dep = b.dependency("glib", .{
        .target = target,
        .optimize = optimize,
    });
    const embed_dep = b.dependency("embed", .{
        .target = target,
        .optimize = optimize,
    });
    const glib_module = glib_dep.module("glib");
    const embed_module = embed_dep.module("embed");
    const armino_module = b.createModule(.{
        .root_source_file = b.path("lib/armino.zig"),
        .target = target,
        .optimize = optimize,
    });

    _ = rootBkModule(b, target, optimize, glib_module, embed_module, armino_module);
    const root_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("lib/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "glib", .module = glib_module },
                .{ .name = "embed_core", .module = embed_module },
                .{ .name = "bk_armino", .module = armino_module },
            },
        }),
    });
    const run_root_tests = b.addRunArtifact(root_tests);
    const test_step = b.step("test", "Run BK build-system tests");
    test_step.dependOn(&run_root_tests.step);
}

fn rootBkModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    glib_module: *std.Build.Module,
    embed_module: *std.Build.Module,
    armino_module: *std.Build.Module,
) *std.Build.Module {
    return b.addModule("bk", .{
        .root_source_file = b.path("lib/bk.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "glib", .module = glib_module },
            .{ .name = "embed_core", .module = embed_module },
            .{ .name = "bk_armino", .module = armino_module },
        },
    });
}
