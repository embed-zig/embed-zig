pub fn register(registry: anytype) void {
    const glib = registry.b.dependency("glib", .{
        .target = registry.target,
        .optimize = registry.optimize,
    }).module("glib");
    registry.add("glib_unit-test", registry.b.addModule("glib_unit-test", .{
        .root_source_file = registry.b.path("glib/unit-test/src/app.zig"),
        .target = registry.target,
        .optimize = registry.optimize,
        .imports = &.{
            .{ .name = "glib", .module = glib },
        },
    }));
}
