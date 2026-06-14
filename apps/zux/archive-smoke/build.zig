pub fn register(registry: anytype) void {
    const glib = registry.b.dependency("glib", .{
        .target = registry.target,
        .optimize = registry.optimize,
    }).module("glib");

    registry.add("zux_archive-smoke", registry.b.addModule("zux_archive-smoke", .{
        .root_source_file = registry.b.path("zux/archive-smoke/src/app.zig"),
        .target = registry.target,
        .optimize = registry.optimize,
        .imports = &.{
            .{ .name = "glib", .module = glib },
            .{ .name = "launcher", .module = registry.launcher },
        },
    }));
}
