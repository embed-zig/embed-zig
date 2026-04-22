const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("lib/ledstrip.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("ledstrip", mod) catch @panic("OOM");
}

pub fn link(b: *std.Build) void {
    const stdz = b.modules.get("stdz") orelse @panic("ledstrip requires stdz");
    const testing = b.modules.get("testing") orelse @panic("ledstrip requires testing");
    const mod = b.modules.get("ledstrip") orelse @panic("ledstrip module missing");
    mod.addImport("stdz", stdz);
    mod.addImport("testing", testing);
}
