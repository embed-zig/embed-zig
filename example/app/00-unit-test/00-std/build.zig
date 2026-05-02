const std = @import("std");

const BuildAppModuleOptions = struct {
    module_name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub fn register(registry: anytype) void {
    registry.add("unit-test_std", buildAppModule(registry.b, .{
        .module_name = "unit-test_std",
        .target = registry.target,
        .optimize = registry.optimize,
    }));
}

pub fn buildAppModule(
    b: *std.Build,
    options: BuildAppModuleOptions,
) *std.Build.Module {
    const glib = b.dependency("glib", .{
        .target = options.target,
        .optimize = options.optimize,
    }).module("glib");
    const gstd = b.dependency("gstd", .{
        .target = options.target,
        .optimize = options.optimize,
    }).module("gstd");
    const embed = b.dependency("embed", .{
        .target = options.target,
        .optimize = options.optimize,
    }).module("embed");

    return b.addModule(options.module_name, .{
        .root_source_file = b.path("app/00-unit-test/00-std/src/app.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .imports = &.{
            .{ .name = "glib", .module = glib },
            .{ .name = "gstd", .module = gstd },
            .{ .name = "embed", .module = embed },
        },
    });
}
