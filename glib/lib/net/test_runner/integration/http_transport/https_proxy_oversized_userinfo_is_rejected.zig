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

                    const EmptyState = struct {};
                    try Utils.withServerState(
                        testing.allocator,
                        EmptyState{},
                        struct {
                            fn run(conn: net.Conn, _: *EmptyState) !void {
                                var c = conn;
                                c.setReadDeadline(net.time.instant.add(net.time.instant.now(), 100 * net.time.duration.MilliSecond));
                                var buf: [64]u8 = undefined;
                                const n = c.read(&buf) catch |err| switch (err) {
                                    error.EndOfStream,
                                    error.TimedOut,
                                    => 0,
                                    else => return err,
                                };
                                try testing.expectEqual(@as(usize, 0), n);
                            }
                        }.run,
                        struct {
                            fn run(_: std.mem.Allocator, port: u16, _: *EmptyState) !void {
                                const oversized_user = try testing.allocator.alloc(u8, 32 * 1024);
                                defer testing.allocator.free(oversized_user);
                                @memset(oversized_user, 'u');

                                const proxy_raw_url = try std.fmt.allocPrint(testing.allocator, "http://{s}:pass@127.0.0.1:{d}", .{ oversized_user, port });
                                defer testing.allocator.free(proxy_raw_url);

                                var transport = try Http.Transport.init(testing.allocator, .{
                                    .https_proxy = .{
                                        .url = try net.url.parse(proxy_raw_url),
                                    },
                                });
                                defer transport.deinit();

                                var req = try Http.Request.init(testing.allocator, "GET", "https://example.com/oversized-userinfo");
                                try testing.expectError(error.InvalidProxy, transport.roundTrip(&req));
                            }
                        }.run,
                    );
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
