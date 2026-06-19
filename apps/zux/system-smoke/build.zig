pub fn register(registry: anytype) void {
    const glib = registry.b.dependency("glib", .{
        .target = registry.target,
        .optimize = registry.optimize,
    }).module("glib");

    registry.add("zux_system-smoke", registry.b.addModule("zux_system-smoke", .{
        .root_source_file = registry.b.path("zux/system-smoke/src/app.zig"),
        .target = registry.target,
        .optimize = registry.optimize,
        .imports = &.{
            .{ .name = "glib", .module = glib },
            .{ .name = "glib_empty_zux_app", .module = registry.glib_empty_zux_app },
            .{ .name = "launcher", .module = registry.launcher },
        },
    }));
}
