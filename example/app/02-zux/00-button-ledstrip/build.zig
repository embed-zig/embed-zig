const std = @import("std");

const BuildAppModuleOptions = struct {
    module_name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub fn register(registry: anytype) void {
    registry.add("zux_button-ledstrip", buildAppModule(registry.b, .{
        .module_name = "zux_button-ledstrip",
        .target = registry.target,
        .optimize = registry.optimize,
    }));
}

pub fn buildAppModule(
    b: *std.Build,
    options: BuildAppModuleOptions,
) *std.Build.Module {
    const embed = b.dependency("embed", .{
        .target = options.target,
        .optimize = options.optimize,
    }).module("embed");
    const glib = b.dependency("glib", .{
        .target = options.target,
        .optimize = options.optimize,
    }).module("glib");
    const gstd = b.dependency("gstd", .{
        .target = options.target,
        .optimize = options.optimize,
    }).module("gstd");

    return b.addModule(options.module_name, .{
        .root_source_file = b.path("app/02-zux/00-button-ledstrip/src/app.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .imports = &.{
            .{ .name = "embed", .module = embed },
            .{ .name = "glib", .module = glib },
            .{ .name = "gstd", .module = gstd },
        },
    });
}
