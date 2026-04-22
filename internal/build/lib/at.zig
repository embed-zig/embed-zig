const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("lib/at.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("at", mod) catch @panic("OOM");
}

pub fn link(b: *std.Build) void {
    const stdz = b.modules.get("stdz") orelse @panic("at requires stdz");
    const testing = b.modules.get("testing") orelse @panic("at requires testing");
    const mod = b.modules.get("at") orelse @panic("at module missing");
    mod.addImport("stdz", stdz);
    mod.addImport("testing", testing);
}
