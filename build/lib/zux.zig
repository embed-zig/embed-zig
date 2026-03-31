const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("lib/zux.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("zux", mod) catch @panic("OOM");
}

pub fn link(_: *std.Build) void {}
