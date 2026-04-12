const testing_api = @import("testing");

pub const bt = @import("component/bt.zig");
pub const button = @import("component/button.zig");
pub const imu = @import("component/imu.zig");
pub const led_strip = @import("component/led_strip.zig");
pub const modem = @import("component/modem.zig");
pub const nfc = @import("component/nfc.zig");
pub const wifi = @import("component/wifi.zig");

pub fn make(comptime lib: type, comptime Channel: fn (type) type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("bt", bt.make(lib));
            t.run("button", button.make(lib, Channel));
            t.run("imu", imu.make(lib, Channel));
            t.run("led_strip", led_strip.make(lib, Channel));
            t.run("modem", modem.make(lib, Channel));
            t.run("nfc", nfc.make(lib, Channel));
            t.run("wifi", wifi.make(lib, Channel));
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
