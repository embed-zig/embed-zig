pub fn register(registry: anytype) void {
    const embed = registry.b.dependency("embed", .{
        .target = registry.target,
        .optimize = registry.optimize,
    }).module("embed");
    const glib = registry.b.dependency("glib", .{
        .target = registry.target,
        .optimize = registry.optimize,
    }).module("glib");
    const gstd = registry.b.dependency("gstd", .{
        .target = registry.target,
        .optimize = registry.optimize,
    }).module("gstd");

    registry.add("zux_button-ledstrip", registry.b.addModule("zux_button-ledstrip", .{
        .root_source_file = registry.b.path("zux/button-ledstrip/src/app.zig"),
        .target = registry.target,
        .optimize = registry.optimize,
        .imports = &.{
            .{ .name = "embed", .module = embed },
            .{ .name = "glib", .module = glib },
            .{ .name = "gstd", .module = gstd },
        },
    }));
}
