const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("lib/motion.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("motion", mod) catch @panic("OOM");
}

pub fn link(b: *std.Build) void {
    const mod = b.modules.get("motion") orelse @panic("motion module missing");
    _ = mod;
}
