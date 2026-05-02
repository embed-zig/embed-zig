const glib = @import("glib");
const testing = @import("glib").testing;

pub fn run(comptime platform_ctx: type, comptime platform_grt: type) !void {
    const log = platform_grt.std.log.scoped(.compat_tests);

    try platform_ctx.setup();
    defer platform_ctx.teardown();

    log.info("starting embed unit runner", .{});

    var runner = testing.T.new(platform_grt.std, platform_grt.time, .compat_tests);
    defer runner.deinit();

    runner.timeout(240 * glib.time.duration.Second);
    runner.run("std/unit", glib.std.test_runner.unit.make(platform_grt.std));

    const passed = runner.wait();
    log.info("embed unit runner finished", .{});
    if (!passed) return error.TestsFailed;
}
