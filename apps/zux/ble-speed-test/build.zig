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
    const common = registry.b.addModule("zux_ble_speed_test_common", .{
        .root_source_file = registry.b.path("zux/ble-speed-test/src/app.zig"),
        .target = registry.target,
        .optimize = registry.optimize,
        .imports = &.{
            .{ .name = "embed", .module = embed },
            .{ .name = "glib", .module = glib },
            .{ .name = "launcher", .module = registry.launcher },
            .{ .name = "lvgl", .module = lvgl },
        },
    });

    addModule(registry, "zux_ble-speed-test-client", "zux/ble-speed-test/src/app_client.zig", common);
    addModule(registry, "zux_ble-speed-test-server", "zux/ble-speed-test/src/app_server.zig", common);
}

fn addModule(
    registry: anytype,
    comptime name: []const u8,
    comptime root_source_file: []const u8,
    common: *std.Build.Module,
) void {
    const module = registry.b.addModule(name, .{
        .root_source_file = registry.b.path(root_source_file),
        .target = registry.target,
        .optimize = registry.optimize,
        .imports = &.{
            .{ .name = "zux_ble_speed_test_common", .module = common },
        },
    });

    registry.add(name, module);
}
