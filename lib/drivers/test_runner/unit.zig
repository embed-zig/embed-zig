const testing_api = @import("testing");

const I2c = @import("../io/I2c.zig");
const Delay = @import("../io/Delay.zig");
const Spi = @import("../io/Spi.zig");
const Es7210 = @import("../audio/es7210.zig");
const Es8311 = @import("../audio/es8311.zig");
const Qmi8658 = @import("../imu/qmi8658.zig");
const Tca9554 = @import("../gpio/tca9554.zig");
const TypeA = @import("../nfc/io/TypeA.zig");
const type_a = @import("../nfc/fm175xx/type_a.zig");
const ntag = @import("../nfc/fm175xx/ntag.zig");
const Fm175xx = @import("../nfc/fm175xx.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.parallel();
            t.run("I2c", I2c.TestRunner(lib));
            t.run("Delay", Delay.TestRunner(lib));
            t.run("Spi", Spi.TestRunner(lib));
            t.run("Es7210", Es7210.TestRunner(lib));
            t.run("Es8311", Es8311.TestRunner(lib));
            t.run("Qmi8658", Qmi8658.TestRunner(lib));
            t.run("Tca9554", Tca9554.TestRunner(lib));
            t.run("TypeA", TypeA.TestRunner(lib));
            t.run("type_a", type_a.TestRunner(lib));
            t.run("ntag", ntag.TestRunner(lib));
            t.run("Fm175xx", Fm175xx.TestRunner(lib));
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
