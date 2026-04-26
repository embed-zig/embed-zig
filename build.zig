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
    b.modules.put("glib", glib_dep.module("glib")) catch @panic("OOM");
    b.modules.put("gstd", gstd_dep.module("gstd")) catch @panic("OOM");
    b.modules.put("embed", embed_dep.module("embed")) catch @panic("OOM");
}
