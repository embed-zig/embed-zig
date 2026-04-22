const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("lib/stdz.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("stdz", mod) catch @panic("OOM");
}

pub fn link(_: *std.Build) void {}
