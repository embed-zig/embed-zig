pub fn register(registry: anytype) void {
    const embed = registry.b.dependency("embed", .{
        .target = registry.target,
        .optimize = registry.optimize,
    }).module("embed");
    const glib = registry.b.dependency("glib", .{
        .target = registry.target,
        .optimize = registry.optimize,
    }).module("glib");

    registry.add("zux_gpio-smoke", registry.b.addModule("zux_gpio-smoke", .{
        .root_source_file = registry.b.path("zux/gpio-smoke/src/app.zig"),
        .target = registry.target,
        .optimize = registry.optimize,
        .imports = &.{
            .{ .name = "embed", .module = embed },
            .{ .name = "glib", .module = glib },
            .{ .name = "launcher", .module = registry.launcher },
        },
    }));
}
