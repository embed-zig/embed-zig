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
        .root_source_file = glib_dep.path("lib/io.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("io", mod) catch @panic("OOM");
}

pub fn link(b: *std.Build) void {
    const mod = b.modules.get("io") orelse @panic("io module missing");
    const stdz = b.modules.get("stdz") orelse @panic("io requires stdz");
    const testing = b.modules.get("testing") orelse @panic("io requires testing");
    mod.addImport("stdz", stdz);
    mod.addImport("testing", testing);
}
