const std = @import("std");
const lib_gstd = @import("build/lib/gstd.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sysroot = b.option([]const u8, "sysroot", "C sysroot path for cross-target libc headers") orelse "";
    if (sysroot.len != 0) b.sysroot = sysroot;

    const glib_dep = b.dependency("glib", .{
        .target = target,
        .optimize = optimize,
    });
    const thirdparty_dep = b.dependency("thirdparty", .{
        .target = target,
        .optimize = optimize,
        .sysroot = sysroot,
    });

    const gstd_mod = lib_gstd.create(b, target, optimize);
    lib_gstd.link(gstd_mod, .{
        .glib = glib_dep.module("glib"),
        .mbedtls = thirdparty_dep.module("mbedtls"),
        .mbedtls_osal = thirdparty_dep.module("mbedtls_osal"),
    });
    b.modules.put("gstd", gstd_mod) catch @panic("OOM");
}
