const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("lib/net.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("net", mod) catch @panic("OOM");
}

pub fn link(b: *std.Build) void {
    const stdz = b.modules.get("stdz") orelse @panic("net requires stdz");
    const sync = b.modules.get("sync") orelse @panic("net requires sync");
    const context = b.modules.get("context") orelse @panic("net requires context");
    const io = b.modules.get("io") orelse @panic("net requires io");
    const testing = b.modules.get("testing") orelse @panic("net requires testing");
    const mod = b.modules.get("net") orelse @panic("net module missing");
    mod.addImport("stdz", stdz);
    mod.addImport("sync", sync);
    mod.addImport("context", context);
    mod.addImport("io", io);
    mod.addImport("testing", testing);
}
