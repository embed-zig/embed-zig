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

    registry.add("zux_colorbar-adc", registry.b.addModule("zux_colorbar-adc", .{
        .root_source_file = registry.b.path("zux/colorbar-adc/src/app.zig"),
        .target = registry.target,
        .optimize = registry.optimize,
        .imports = &.{
            .{ .name = "embed", .module = embed },
            .{ .name = "glib", .module = glib },
            .{ .name = "launcher", .module = registry.launcher },
            .{ .name = "lvgl", .module = lvgl },
        },
    }));
}
