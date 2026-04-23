const testing_api = @import("testing");
const Builder = @import("../../spec/Builder.zig");
const bt = @import("component/bt.zig");
const imu = @import("component/imu.zig");

pub fn make(comptime lib: type, comptime Channel: fn (type) type) testing_api.TestRunner {
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

    const story_runner = comptime blk: {
        var spec = SpecType.init();
        break :blk spec.testRunner(lib, .{
            .pipeline = .{
                .tick_interval_ns = lib.time.ns_per_ms,
            },
        }, Channel);
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("bt", bt.make(lib, Channel));
            t.run("stories", story_runner);
            t.run("imu", imu.make(lib, Channel));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
