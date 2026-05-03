const glib = @import("glib");
const AssemblerConfig = @import("../../assembler/Config.zig");
const Builder = @import("../../spec/Builder.zig");
const bt = @import("component/bt.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const SpecType = comptime blk: {
        @setEvalBranchQuota(2_000_000);
        var builder = Builder.init();
        builder.addSpecSlices(&.{
            @embedFile("board.json"),
            @embedFile("component/button/single_button_click_sequence.json"),
            @embedFile("component/button/single_button_long_press_sequence.json"),
            @embedFile("component/button/grouped_button_click_sequence.json"),
            @embedFile("component/button/grouped_button_long_press_sequence.json"),
            @embedFile("component/led_strip/animated_sequence.json"),
            @embedFile("component/led_strip/flash_sequence.json"),
            @embedFile("component/led_strip/pingpong_sequence.json"),
            @embedFile("component/led_strip/rotate_sequence.json"),
            @embedFile("component/imu/free_fall.json"),
            @embedFile("component/imu/flip.json"),
            @embedFile("component/imu/flip_then_shake.json"),
            @embedFile("component/imu/shake.json"),
            @embedFile("component/imu/tilt.json"),
            @embedFile("component/modem/attach_sequence.json"),
            @embedFile("component/modem/signal_sequence.json"),
            @embedFile("component/modem/apn_sequence.json"),
            @embedFile("component/modem/call_sequence.json"),
            @embedFile("component/modem/sms_sequence.json"),
            @embedFile("component/modem/gnss_sequence.json"),
            @embedFile("component/modem/mixed_sequence.json"),
            @embedFile("component/nfc/found_read_sequence.json"),
            @embedFile("component/wifi/sta_sequence.json"),
            @embedFile("component/wifi/ap_sequence.json"),
            @embedFile("component/ui/flow/pairing_flow_sequence.json"),
            @embedFile("component/ui/overlay/loading_overlay_sequence.json"),
            @embedFile("component/ui/selection/menu_selection_sequence.json"),
            @embedFile("component/ui/route/route_sequence.json"),
        });
        break :blk builder.build();
    };

    const config: AssemblerConfig = .{
        .pipeline = .{
            .tick_interval = grt.time.duration.MilliSecond,
        },
    };
    const AppType = comptime blk: {
        var spec = SpecType.init();
        break :blk spec.buildApp(grt, config);
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            const InitConfigFactory = struct {
                fn make(init_config: AppType.InitConfig) AppType.InitConfig {
                    return init_config;
                }
            };
            const spec = SpecType.init();
            const story_runner = spec.testRunner(AppType, InitConfigFactory.make);

            t.run("bt", bt.make(grt));
            t.run("stories", story_runner);
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
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
