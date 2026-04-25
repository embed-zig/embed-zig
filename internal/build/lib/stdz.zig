const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const glib_dep = b.dependency("glib", .{
        .target = target,
        .optimize = optimize,
    });
    const mod = b.createModule(.{
        .root_source_file = glib_dep.path("lib/stdz.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("stdz", mod) catch @panic("OOM");
}

pub fn link(_: *std.Build) void {}
