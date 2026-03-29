const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("lib/context.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("context", mod) catch @panic("OOM");
}

pub fn link(b: *std.Build) void {
    const embed = b.modules.get("embed") orelse @panic("context requires embed");
    const mod = b.modules.get("context") orelse @panic("context module missing");
    mod.addImport("embed", embed);
}
