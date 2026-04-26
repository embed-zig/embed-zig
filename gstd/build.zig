const std = @import("std");
const lib_gstd = @import("build/lib/gstd.zig");
const build_tests = @import("build/tests.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const glib_dep = b.dependency("glib", .{
        .target = target,
        .optimize = optimize,
    });

    const gstd_mod = lib_gstd.create(b, target, optimize);
    lib_gstd.link(gstd_mod, .{
        .glib = glib_dep.module("glib"),
    });
    b.modules.put("gstd", gstd_mod) catch @panic("OOM");

    build_tests.create(b, target, optimize, glib_dep, gstd_mod);
}
