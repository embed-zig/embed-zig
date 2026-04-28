const glib = @import("glib");
const core_wlan = @import("../../../core_wlan.zig");
const drivers = @import("embed").drivers;

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;

            if (@hasDecl(grt.std.testing, "log_level")) {
                grt.std.testing.log_level = .info;
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
            const probe_scan = @hasDecl(grt.std.testing, "log_level");
            t.run("sta", drivers.wifi.test_runner.integration.sta.makeWithOptions(grt, &device, .{
                .probe_scan = probe_scan,
            }));
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
