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

pub fn link(b: *std.Build) void {
    const embed = b.modules.get("embed") orelse @panic("core_wlan requires embed");
    const drivers = b.modules.get("drivers") orelse @panic("core_wlan requires drivers");
    const testing = b.modules.get("testing") orelse @panic("core_wlan requires testing");
    const mod = b.modules.get("core_wlan") orelse @panic("core_wlan module missing");
    mod.addImport("embed", embed);
    mod.addImport("drivers", drivers);
    mod.addImport("testing", testing);
    mod.linkFramework("CoreWLAN", .{});
    mod.linkFramework("Foundation", .{});
    mod.linkSystemLibrary("objc", .{});
}

pub fn linkTest(_: *std.Build, _: *std.Build.Step.Compile) void {}
