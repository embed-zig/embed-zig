const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("pkg/core_bluetooth.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("core_bluetooth", mod) catch @panic("OOM");
}

pub fn link(b: *std.Build) void {
    const bt = b.modules.get("bt") orelse @panic("core_bluetooth requires bt");
    const embed_std = b.modules.get("embed_std") orelse @panic("core_bluetooth requires embed_std");
    const testing = b.modules.get("testing") orelse @panic("core_bluetooth requires testing");
    const mod = b.modules.get("core_bluetooth") orelse @panic("core_bluetooth module missing");
    mod.addImport("bt", bt);
    mod.addImport("embed_std", embed_std);
    mod.addImport("testing", testing);
    mod.linkFramework("CoreBluetooth", .{});
    mod.linkFramework("Foundation", .{});
    mod.linkSystemLibrary("objc", .{});
}
