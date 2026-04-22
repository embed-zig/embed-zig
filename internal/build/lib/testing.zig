const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("lib/testing.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("testing", mod) catch @panic("OOM");
}

pub fn link(b: *std.Build) void {
    const context = b.modules.get("context") orelse @panic("testing requires context");
    const embed = b.modules.get("embed") orelse @panic("testing requires embed");
    const mod = b.modules.get("testing") orelse @panic("testing module missing");
    mod.addImport("context", context);
    mod.addImport("embed", embed);
}
