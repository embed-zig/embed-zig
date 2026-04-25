const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("lib/stdz.zig"),
        .target = target,
        .optimize = optimize,
    });
}

pub fn link(_: *std.Build.Module) void {}
