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
        .root_source_file = glib_dep.path("lib/context.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("context", mod) catch @panic("OOM");
}

pub fn link(b: *std.Build) void {
    const mod = b.modules.get("context") orelse @panic("context module missing");
    const stdz = b.modules.get("stdz") orelse @panic("context requires stdz");
    mod.addImport("stdz", stdz);
}
