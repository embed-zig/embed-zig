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
        .root_source_file = glib_dep.path("lib/mime.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("mime", mod) catch @panic("OOM");
}

pub fn link(b: *std.Build) void {
    const mod = b.modules.get("mime") orelse @panic("mime module missing");
    const stdz = b.modules.get("stdz") orelse @panic("mime requires stdz");
    const testing = b.modules.get("testing") orelse @panic("mime requires testing");
    mod.addImport("stdz", stdz);
    mod.addImport("testing", testing);
}
