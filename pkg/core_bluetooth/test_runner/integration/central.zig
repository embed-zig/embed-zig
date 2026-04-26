const bt = @import("bt");
const gstd = @import("gstd");
const testing_api = @import("testing");
const cb = @import("../../../core_bluetooth.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            const Bt = bt.make(gstd.runtime);
            const Host = Bt.makeHost(cb.Host);

            var host = Host.init(undefined, .{
                .allocator = lib.testing.allocator,
            }) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer host.deinit();

            t.run("central", bt.test_runner.integration.central.makeWithHost(lib, &host));
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
