const std = @import("std");

pub fn register(registry: anytype) void {
    const embed = registry.b.dependency("embed", .{
        .target = registry.target,
        .optimize = registry.optimize,
    }).module("embed");
    const glib = registry.b.dependency("glib", .{
        .target = registry.target,
        .optimize = registry.optimize,
    }).module("glib");
    const lvgl = registry.thirdpartyModule("lvgl");
    const common = registry.b.addModule("zux_chant_common", .{
        .root_source_file = registry.b.path("zux/chant/src/app_common.zig"),
        .target = registry.target,
        .optimize = registry.optimize,
        .imports = &.{
            .{ .name = "embed", .module = embed },
            .{ .name = "glib", .module = glib },
            .{ .name = "launcher", .module = registry.launcher },
            .{ .name = "lvgl", .module = lvgl },
        },
    });

    addChantModule(registry, "zux_chant_touch", "zux/chant/src/app.zig", glib, common);
    addChantModule(registry, "zux_chant_adc", "zux/chant/src/app_adc.zig", glib, common);
}

fn addChantModule(
    registry: anytype,
    comptime name: []const u8,
    comptime root_source_file: []const u8,
    glib: *std.Build.Module,
    common: *std.Build.Module,
) void {
    registry.add(name, registry.b.addModule(name, .{
        .root_source_file = registry.b.path(root_source_file),
        .target = registry.target,
        .optimize = registry.optimize,
        .imports = &.{
            .{ .name = "glib", .module = glib },
            .{ .name = "zux_chant_common", .module = common },
        },
    }));
}
