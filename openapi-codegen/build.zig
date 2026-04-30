const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const glib_dep = b.dependency("glib", .{
        .target = target,
        .optimize = optimize,
    });
    const glib_mod = glib_dep.module("glib");
    const gstd_dep = b.dependency("gstd", .{
        .target = target,
        .optimize = optimize,
    });
    const gstd_mod = gstd_dep.module("gstd");

    const openapi_mod = b.addModule("openapi", .{
        .root_source_file = b.path("lib/openapi.zig"),
        .target = target,
        .optimize = optimize,
    });

    _ = b.addModule("codegen", .{
        .root_source_file = b.path("lib/codegen.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "openapi", .module = openapi_mod },
            .{ .name = "glib", .module = glib_mod },
            .{ .name = "gstd", .module = gstd_mod },
        },
    });
}
