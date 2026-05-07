pub fn register(registry: anytype) void {
    const glib = registry.b.dependency("glib", .{
        .target = registry.target,
        .optimize = registry.optimize,
    }).module("glib");
    registry.add("glib_unit-test-net", registry.b.addModule("glib_unit-test-net", .{
        .root_source_file = registry.b.path("glib/unit-test/net/src/app.zig"),
        .target = registry.target,
        .optimize = registry.optimize,
        .imports = &.{
            .{ .name = "glib", .module = glib },
            .{ .name = "glib_empty_zux_app", .module = registry.glib_empty_zux_app },
            .{ .name = "launcher", .module = registry.launcher },
        },
    }));
}
