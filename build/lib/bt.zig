const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("lib/bt.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("bt", mod) catch @panic("OOM");
}

pub fn link(b: *std.Build) void {
    const embed = b.modules.get("embed") orelse @panic("bt requires embed");
    const embed_std = b.modules.get("embed_std") orelse @panic("bt requires embed_std");
    const testing = b.modules.get("testing") orelse @panic("bt requires testing");
    const mod = b.modules.get("bt") orelse @panic("bt module missing");
    mod.addImport("embed", embed);
    mod.addImport("embed_std", embed_std);
    mod.addImport("testing", testing);
}
