const glib = @import("glib");
const glib_empty_zux_app = @import("glib_empty_zux_app");
const io = @import("glib").io;
const launcher = @import("launcher");
const testing = @import("glib").testing;

pub fn make(comptime platform_grt: type) type {
    return launcher.make(struct {
        const Self = @This();

        pub const ZuxApp = glib_empty_zux_app.make(platform_grt);

        allocator: ZuxApp.Allocator,
        zux_app: ZuxApp,

        pub fn init(allocator: ZuxApp.Allocator, init_config: ZuxApp.InitConfig) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.* = .{
                .allocator = allocator,
                .zux_app = try ZuxApp.init(init_config),
            };
            return self;
        }

        pub fn deinit(self: *Self) void {
            const allocator = self.allocator;
            self.zux_app.deinit();
            self.* = undefined;
            allocator.destroy(self);
        }

        pub fn createTestRunner() glib.testing.TestRunner {
            const Runner = struct {
                pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
                    _ = self;
                    _ = allocator;
                }

                pub fn run(self: *@This(), t: *testing.T, allocator: glib.std.mem.Allocator) bool {
                    _ = self;
                    _ = allocator;

                    t.timeout(240 * glib.time.duration.Second);
                    t.run("io/unit", io.test_runner.unit.make(platform_grt.std));
                    return t.wait();
                }

                pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
                    _ = self;
                    _ = allocator;
                }
            };

            const Holder = struct {
                var runner: Runner = .{};
            };
            return testing.TestRunner.make(Runner).new(&Holder.runner);
        }
    });
}

pub fn run(comptime platform_ctx: type, comptime platform_grt: type) !void {
    const Launcher = make(platform_grt);
    const log = platform_grt.std.log.scoped(.compat_tests);

    try platform_ctx.setup();
    defer platform_ctx.teardown();

    log.info("starting io unit runner", .{});

    var runner = testing.T.new(platform_grt.std, platform_grt.time, .compat_tests);
    defer runner.deinit();

    runner.run("io/unit", Launcher.createTestRunner());
    const passed = runner.wait();
    log.info("io unit runner finished", .{});
    if (!passed) return error.TestsFailed;
}
