const std = @import("std");

const LinkOptions = struct {
    drivers: *std.Build.Module,
};

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("lib/audio.zig"),
        .target = target,
        .optimize = optimize,
    });
}

pub fn link(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mod: *std.Build.Module,
    options: LinkOptions,
) void {
    const glib_dep = b.dependency("glib", .{
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("glib", glib_dep.module("glib"));
    mod.addImport("drivers", options.drivers);
}
