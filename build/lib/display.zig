const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("lib/display.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("display", mod) catch @panic("OOM");
}

pub fn link(b: *std.Build) void {
    const testing = b.modules.get("testing") orelse @panic("display requires testing");
    const mod = b.modules.get("display") orelse @panic("display module missing");
    mod.addImport("testing", testing);
}
