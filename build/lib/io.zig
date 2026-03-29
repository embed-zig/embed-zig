const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("lib/io.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("io", mod) catch @panic("OOM");
}

pub fn link(b: *std.Build) void {
    const embed = b.modules.get("embed") orelse @panic("io requires embed");
    const mod = b.modules.get("io") orelse @panic("io module missing");
    mod.addImport("embed", embed);
}
