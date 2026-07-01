const builtin = @import("builtin");

pub fn register(registry: anytype) void {
    const embed = registry.b.dependency("embed", .{
        .target = registry.target,
        .optimize = registry.optimize,
    }).module("embed");
    const glib = registry.b.dependency("glib", .{
        .target = registry.target,
        .optimize = registry.optimize,
    }).module("glib");
    const enable_bt_kcp = registry.b.option(
        bool,
        "command_console_bt_kcp",
        "Enable command-console BT/KCP endpoint",
    ) orelse !isNativeTarget(registry.target);
    const options = registry.b.addOptions();
    options.addOption(bool, "enable_bt_kcp", enable_bt_kcp);

    const module = registry.b.addModule("zux_command-console", .{
        .root_source_file = registry.b.path("zux/command-console/src/app.zig"),
        .target = registry.target,
        .optimize = registry.optimize,
        .imports = &.{
            .{ .name = "embed", .module = embed },
            .{ .name = "glib", .module = glib },
            .{ .name = "glib_empty_zux_app", .module = registry.glib_empty_zux_app },
            .{ .name = "launcher", .module = registry.launcher },
        },
    });
    if (enable_bt_kcp) {
        module.addImport("kcp", registry.thirdpartyModule("kcp"));
    }
    module.addOptions("command_console_config", options);
    registry.add("zux_command-console", module);
}

fn isNativeTarget(target: anytype) bool {
    return target.result.cpu.arch == builtin.cpu.arch and target.result.os.tag == builtin.os.tag;
}
