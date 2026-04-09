const embed = @import("embed");
const testing_api = @import("testing");

pub const central = @import("integration/central.zig");
pub const peripheral = @import("integration/peripheral.zig");
pub const pair = @import("integration/pair.zig");
pub const xfer = @import("integration/xfer.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            t.parallel();
            t.run("central", central.make(lib));
            t.run("peripheral", peripheral.make(lib));
            t.run("pair", pair.make(lib));
            t.run("xfer", xfer.make(lib));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
