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
        .root_source_file = glib_dep.path("lib/testing.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("testing", mod) catch @panic("OOM");
}

pub fn link(b: *std.Build) void {
    const mod = b.modules.get("testing") orelse @panic("testing module missing");
    const context = b.modules.get("context") orelse @panic("testing requires context");
    const stdz = b.modules.get("stdz") orelse @panic("testing requires stdz");
    mod.addImport("context", context);
    mod.addImport("stdz", stdz);
}
