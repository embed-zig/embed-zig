const glib = @import("glib");

pub const central = @import("integration/central.zig");
pub const peripheral = @import("integration/peripheral.zig");
pub const pair = @import("integration/pair.zig");
pub const xfer = @import("integration/xfer.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            t.parallel();
            t.run("central", central.make(grt));
            t.run("peripheral", peripheral.make(grt));
            t.run("pair", pair.make(grt));
            t.run("xfer", xfer.make(grt));
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
