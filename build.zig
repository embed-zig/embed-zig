const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const internal_dep = b.dependency("internal", .{
        .target = target,
        .optimize = optimize,
    });
    const glib_dep = b.dependency("glib", .{
        .target = target,
        .optimize = optimize,
    });
    const glib_stdrt_dep = b.dependency("glib_stdrt", .{
        .target = target,
        .optimize = optimize,
    });
    const glib_mod = glib_dep.module("glib");
    const glib_stdrt_mod = glib_stdrt_dep.module("glib_stdrt");
    const drivers_mod = internal_dep.module("drivers");
    const bt_mod = internal_dep.module("bt");
    const motion_mod = internal_dep.module("motion");
    const audio_mod = internal_dep.module("audio");
    const ledstrip_mod = internal_dep.module("ledstrip");
    const zux_mod = internal_dep.module("zux");

    b.modules.put("glib", glib_mod) catch @panic("OOM");
    b.modules.put("glib_stdrt", glib_stdrt_mod) catch @panic("OOM");
    b.modules.put("drivers", drivers_mod) catch @panic("OOM");
    b.modules.put("bt", bt_mod) catch @panic("OOM");
    b.modules.put("motion", motion_mod) catch @panic("OOM");
    b.modules.put("audio", audio_mod) catch @panic("OOM");
    b.modules.put("ledstrip", ledstrip_mod) catch @panic("OOM");
    b.modules.put("zux", zux_mod) catch @panic("OOM");
}
