const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("lib/embed_std.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("embed_std", mod) catch @panic("OOM");
}

pub fn link(b: *std.Build) void {
    const stdz = b.modules.get("stdz") orelse @panic("embed_std requires stdz");
    const sync = b.modules.get("sync") orelse @panic("embed_std requires sync");
    const mod = b.modules.get("embed_std") orelse @panic("embed_std module missing");
    mod.addImport("stdz", stdz);
    mod.addImport("sync", sync);
}
