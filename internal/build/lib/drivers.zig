const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("lib/drivers.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("drivers", mod) catch @panic("OOM");
}

pub fn link(b: *std.Build) void {
    const stdz = b.modules.get("stdz") orelse @panic("drivers requires stdz");
    const net = b.modules.get("net") orelse @panic("drivers requires net");
    const testing = b.modules.get("testing") orelse @panic("drivers requires testing");
    const mod = b.modules.get("drivers") orelse @panic("drivers module missing");
    mod.addImport("stdz", stdz);
    mod.addImport("net", net);
    mod.addImport("testing", testing);
}
