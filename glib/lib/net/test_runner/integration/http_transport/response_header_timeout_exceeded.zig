const stdz = @import("stdz");
const testing_api = @import("testing");
const test_utils = @import("test_utils.zig");

pub fn make(comptime std: type, comptime net: type) testing_api.TestRunner {
    const Utils = test_utils.make2(std, net);

    const Runner = struct {
        spawn_config: stdz.Thread.SpawnConfig = .{ .stack_size = 1024 * 1024 },

        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(runner: *@This(), t: *testing_api.T, run_allocator: std.mem.Allocator) bool {
            _ = runner;
            const Body = struct {
                fn call(a: std.mem.Allocator) !void {
                    const Http = Utils.Http;
                    const testing = struct {
                        pub var allocator: std.mem.Allocator = undefined;
                        pub const expect = std.testing.expect;
                        pub const expectEqual = std.testing.expectEqual;
                        pub const expectEqualStrings = std.testing.expectEqualStrings;
                        pub const expectError = std.testing.expectError;
                    };
                    testing.allocator = a;

                    try Utils.withOneShotServer(testing.allocator, .{
                        .expected_request_line = "GET /header-timeout HTTP/1.1",
                        .status_code = Http.status.ok,
                        .body = "slow",
                        .delay_ms = 80,
                    }, struct {
                        fn run(_: std.mem.Allocator, port: u16) !void {
                            var transport = try Http.Transport.init(testing.allocator, .{
                                .response_header_timeout = 20 * net.time.duration.MilliSecond,
                            });
                            defer transport.deinit();

                            const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/header-timeout", .{port});
                            defer testing.allocator.free(url);

                            var req = try Http.Request.init(testing.allocator, "GET", url);
                            try testing.expectError(error.TimedOut, transport.roundTrip(&req));
                        }
                    }.run);
                }
            };
            Body.call(run_allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
