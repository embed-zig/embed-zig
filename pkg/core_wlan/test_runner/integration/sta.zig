const core_wlan = @import("../../../core_wlan.zig");
const drivers = @import("drivers");
const testing_api = @import("testing");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;

            if (@hasDecl(lib.testing, "log_level")) {
                lib.testing.log_level = .info;
            }

            var device = core_wlan.Wifi.init(.{
                .allocator = allocator,
            }) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            defer device.deinit();

            // std.testing has `log_level`; sealed embed testing does not. Run at most one
            // real CoreWLAN scan per `zig build test` to avoid back-to-back scan failures.
            const probe_scan = @hasDecl(lib.testing, "log_level");
            t.run("sta", drivers.wifi.test_runner.integration.sta.makeWithOptions(lib, &device, .{
                .probe_scan = probe_scan,
            }));
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
