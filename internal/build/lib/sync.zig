const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("lib/sync.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("sync", mod) catch @panic("OOM");
}

pub fn link(b: *std.Build) void {
    const context = b.modules.get("context") orelse @panic("sync requires context");
    const stdz = b.modules.get("stdz") orelse @panic("sync requires stdz");
    const testing = b.modules.get("testing") orelse @panic("sync requires testing");
    const mod = b.modules.get("sync") orelse @panic("sync module missing");
    mod.addImport("context", context);
    mod.addImport("stdz", stdz);
    mod.addImport("testing", testing);
}
