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

pub fn link(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const glib_dep = b.dependency("glib", .{
        .target = target,
        .optimize = optimize,
    });
    const motion = b.modules.get("motion") orelse @panic("zux requires motion");
    const bt = b.modules.get("bt") orelse @panic("zux requires bt");
    const drivers = b.modules.get("drivers") orelse @panic("zux requires drivers");
    const ledstrip = b.modules.get("ledstrip") orelse @panic("zux requires ledstrip");
    const mod = b.modules.get("zux") orelse @panic("zux module missing");
    mod.addImport("glib", glib_dep.module("glib"));
    mod.addImport("motion", motion);
    mod.addImport("bt", bt);
    mod.addImport("drivers", drivers);
    mod.addImport("ledstrip", ledstrip);
}

pub fn linkTest(b: *std.Build, compile: *std.Build.Step.Compile) void {
    _ = b;
    _ = compile;
}
