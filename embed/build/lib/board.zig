const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("lib/board.zig"),
        .target = target,
        .optimize = optimize,
    });
}

pub fn link(
    b: *std.Build,
    mod: *std.Build.Module,
    deps: struct {
        audio: *std.Build.Module,
        bt: *std.Build.Module,
        drivers: *std.Build.Module,
        ledstrip: *std.Build.Module,
    },
) void {
    _ = b;
    mod.addImport("audio", deps.audio);
    mod.addImport("bt", deps.bt);
    mod.addImport("drivers", deps.drivers);
    mod.addImport("ledstrip", deps.ledstrip);
}
