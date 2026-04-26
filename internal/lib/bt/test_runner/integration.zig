const glib = @import("glib");

pub const central = @import("integration/central.zig");
pub const peripheral = @import("integration/peripheral.zig");
pub const pair = @import("integration/pair.zig");
pub const xfer = @import("integration/xfer.zig");

pub fn make(comptime gz: type) glib.testing.TestRunner {
    const lib = gz.std;
    const Channel = gz.sync.Channel;

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            t.parallel();
            t.run("central", central.make(lib, Channel));
            t.run("peripheral", peripheral.make(lib, Channel));
            t.run("pair", pair.make(lib, Channel));
            t.run("xfer", xfer.make(gz));
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
