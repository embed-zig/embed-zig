const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("glib_stdrt.zig"),
        .target = target,
        .optimize = optimize,
    });
}

pub fn link(mod: *std.Build.Module, deps: anytype) void {
    mod.addImport("glib", deps.glib);
}
