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
    const options = registry.b.addOptions();
    const transport = registry.b.option([]const u8, "ble_speed_transport", "BLE speed transport: raw-gatt or kcp-stream") orelse "raw-gatt";
    options.addOption([]const u8, "transport", transport);

    const common = registry.b.addModule("zux_ble_speed_test_common", .{
        .root_source_file = registry.b.path("zux/ble-speed-test/src/app.zig"),
        .target = registry.target,
        .optimize = registry.optimize,
        .imports = if (isKcpTransport(transport)) &.{
            .{ .name = "embed", .module = embed },
            .{ .name = "glib", .module = glib },
            .{ .name = "kcp", .module = registry.thirdpartyModule("kcp") },
            .{ .name = "launcher", .module = registry.launcher },
            .{ .name = "lvgl", .module = lvgl },
        } else &.{
            .{ .name = "embed", .module = embed },
            .{ .name = "glib", .module = glib },
            .{ .name = "launcher", .module = registry.launcher },
            .{ .name = "lvgl", .module = lvgl },
        },
    });
    common.addOptions("ble_speed_test_config", options);

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

fn isKcpTransport(transport: []const u8) bool {
    return std.mem.eql(u8, transport, "kcp-stream") or std.mem.eql(u8, transport, "kcp_stream");
}
