const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("lib/mime.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("mime", mod) catch @panic("OOM");
}

pub fn link(b: *std.Build) void {
    const embed = b.modules.get("embed") orelse @panic("mime requires embed");
    const testing = b.modules.get("testing") orelse @panic("mime requires testing");
    const mod = b.modules.get("mime") orelse @panic("mime module missing");
    mod.addImport("embed", embed);
    mod.addImport("testing", testing);
}
