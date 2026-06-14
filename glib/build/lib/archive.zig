const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("lib/archive.zig"),
        .target = target,
        .optimize = optimize,
    });
}

pub fn link(mod: *std.Build.Module, deps: anytype) void {
    mod.addImport("testing", deps.testing);
    mod.addImport("fs", deps.fs);
    mod.addImport("path", deps.path);
    mod.addImport("compress", deps.compress);
}
