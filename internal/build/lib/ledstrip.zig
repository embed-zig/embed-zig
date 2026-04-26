const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("lib/ledstrip.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("ledstrip", mod) catch @panic("OOM");
}

pub fn link(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const glib_dep = b.dependency("glib", .{
        .target = target,
        .optimize = optimize,
    });
    const mod = b.modules.get("ledstrip") orelse @panic("ledstrip module missing");
    mod.addImport("glib", glib_dep.module("glib"));
}
