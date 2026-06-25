const std = @import("std");
const common = @import("lvgl_common.zig");

var osal_module: ?*std.Build.Module = null;

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const repo = common.getUpstreamArchive(b);
    const config_header = common.getConfigHeader(b);
    repo.dependOn(&config_header.step);

    const mod = b.createModule(.{
        .root_source_file = b.path("pkg/lvgl_osal.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    common.addCommonIncludes(b, mod, repo, config_header);
    mod.addImport("glib", b.dependency("glib", .{ .target = target, .optimize = optimize }).module("glib"));
    b.modules.put("lvgl_osal", mod) catch @panic("OOM");

    osal_module = mod;
}

pub fn link(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    _ = b;
    _ = target;
    _ = optimize;
    _ = osal_module orelse @panic("lvgl_osal module missing");
}
