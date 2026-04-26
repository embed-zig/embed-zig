const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("lib/zux.zig"),
        .target = target,
        .optimize = optimize,
    });
}

pub fn link(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mod: *std.Build.Module,
    deps: struct {
        motion: *std.Build.Module,
        bt: *std.Build.Module,
        drivers: *std.Build.Module,
        ledstrip: *std.Build.Module,
    },
) void {
    const glib_dep = b.dependency("glib", .{
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("glib", glib_dep.module("glib"));
    mod.addImport("motion", deps.motion);
    mod.addImport("bt", deps.bt);
    mod.addImport("drivers", deps.drivers);
    mod.addImport("ledstrip", deps.ledstrip);
}
