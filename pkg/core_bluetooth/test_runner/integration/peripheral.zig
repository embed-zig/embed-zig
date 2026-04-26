const glib = @import("glib");
const bt = @import("bt");
const gstd = @import("gstd");
const cb = @import("../../../core_bluetooth.zig");

const five_seconds_ns: i64 = 5 * 1_000_000_000;

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            const Bt = bt.make(gstd.runtime);
            const Host = Bt.makeHost(cb.Host);

            var host = Host.init(undefined, .{
                .allocator = grt.std.testing.allocator,
            }) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer host.deinit();

            t.timeout(five_seconds_ns);
            t.run("peripheral", bt.test_runner.integration.peripheral.makeWithHost(grt, &host));
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
