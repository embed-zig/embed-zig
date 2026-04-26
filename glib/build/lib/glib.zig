const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("glib.zig"),
        .target = target,
        .optimize = optimize,
    });
}

pub fn link(mod: *std.Build.Module, deps: anytype) void {
    mod.addImport("stdz", deps.stdz);
    mod.addImport("testing", deps.testing);
    mod.addImport("context", deps.context);
    mod.addImport("time", deps.time);
    mod.addImport("sync", deps.sync);
    mod.addImport("io", deps.io);
    mod.addImport("mime", deps.mime);
    mod.addImport("net", deps.net);
}
