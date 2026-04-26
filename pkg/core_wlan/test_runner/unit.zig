const glib = @import("glib");
const core_wlan = @import("../../core_wlan.zig");
const CWApUnsupported = @import("../../core_wlan/src/CWApUnsupported.zig");
const CWSta = @import("../../core_wlan/src/CWSta.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("core_wlan", core_wlan.TestRunner(grt));
            t.run("src/CWSta", CWSta.TestRunner(grt));
            t.run("src/CWApUnsupported", CWApUnsupported.TestRunner(grt));
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
