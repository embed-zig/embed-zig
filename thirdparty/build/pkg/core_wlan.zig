const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("pkg/core_wlan.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.modules.put("core_wlan", mod) catch @panic("OOM");
}

pub fn link(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const glib_dep = b.dependency("glib", .{
        .target = target,
        .optimize = optimize,
    });
    const embed_dep = b.dependency("embed", .{
        .target = target,
        .optimize = optimize,
    });
    const mod = b.modules.get("core_wlan") orelse @panic("core_wlan module missing");
    mod.addImport("glib", glib_dep.module("glib"));
    mod.addImport("embed", embed_dep.module("embed"));

    if (target.result.os.tag == .macos) {
        mod.linkFramework("CoreWLAN", .{});
        mod.linkFramework("Foundation", .{});
        mod.linkSystemLibrary("objc", .{});
    }
}

pub fn testSupported(_: *std.Build, target: std.Build.ResolvedTarget) bool {
    _ = target;
    return false;
}
