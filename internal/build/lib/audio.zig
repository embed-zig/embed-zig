const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("lib/audio.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("audio", mod) catch @panic("OOM");
}

pub fn link(b: *std.Build) void {
    const stdz = b.modules.get("stdz") orelse @panic("audio requires stdz");
    const testing = b.modules.get("testing") orelse @panic("audio requires testing");
    const mod = b.modules.get("audio") orelse @panic("audio module missing");
    mod.addImport("stdz", stdz);
    mod.addImport("testing", testing);
}
