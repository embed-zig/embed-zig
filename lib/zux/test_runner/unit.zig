const testing_api = @import("testing");

pub const assembler = @import("unit/assembler.zig");
pub const button = @import("unit/button.zig");
pub const bt = @import("unit/bt.zig");
pub const event = @import("unit/event.zig");
pub const imu = @import("unit/imu.zig");
pub const modem = @import("unit/modem.zig");
pub const netstack = @import("unit/netstack.zig");
pub const nfc = @import("unit/nfc.zig");
pub const pipeline = @import("unit/pipeline.zig");
pub const store = @import("unit/store.zig");
pub const ui = @import("unit/ui.zig");
pub const wifi = @import("unit/wifi.zig");

pub fn make(comptime lib: type, comptime Channel: fn (type) type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.parallel();
            t.run("assembler", assembler.make(lib, Channel));
            t.run("button", button.make(lib));
            t.run("bt", bt.make(lib));
            t.run("event", event.make(lib));
            t.run("imu", imu.make(lib));
            t.run("modem", modem.make(lib));
            t.run("netstack", netstack.make(lib));
            t.run("nfc", nfc.make(lib));
            t.run("pipeline", pipeline.make(lib, Channel));
            t.run("store", store.make(lib));
            t.run("ui", ui.make(lib));
            t.run("wifi", wifi.make(lib));
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
