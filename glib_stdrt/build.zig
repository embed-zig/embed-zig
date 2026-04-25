const std = @import("std");
const lib_glib_stdrt = @import("build/lib/glib_stdrt.zig");
const build_tests = @import("build/tests.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const glib_dep = b.dependency("glib", .{
        .target = target,
        .optimize = optimize,
    });

    const glib_stdrt_mod = lib_glib_stdrt.create(b, target, optimize);
    lib_glib_stdrt.link(glib_stdrt_mod, .{
        .glib = glib_dep.module("glib"),
    });
    b.modules.put("glib_stdrt", glib_stdrt_mod) catch @panic("OOM");

    build_tests.create(b, target, optimize, glib_dep, glib_stdrt_mod);
}
