pub fn register(registry: anytype) void {
    const glib = registry.b.dependency("glib", .{
        .target = registry.target,
        .optimize = registry.optimize,
    }).module("glib");
    const kcp = registry.thirdpartyModule("kcp");

    registry.add("zux_kcp-test", registry.b.addModule("zux_kcp-test", .{
        .root_source_file = registry.b.path("zux/kcp-test/src/app.zig"),
        .target = registry.target,
        .optimize = registry.optimize,
        .imports = &.{
            .{ .name = "glib", .module = glib },
            .{ .name = "kcp", .module = kcp },
            .{ .name = "launcher", .module = registry.launcher },
        },
    }));
}
