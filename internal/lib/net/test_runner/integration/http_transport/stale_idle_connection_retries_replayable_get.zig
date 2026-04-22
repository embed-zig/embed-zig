const stdz = @import("stdz");
const testing_api = @import("testing");
const test_utils = @import("test_utils.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Utils = test_utils.make(lib);

    const Runner = struct {
        spawn_config: stdz.Thread.SpawnConfig = .{ .stack_size = 1024 * 1024 },

        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(runner: *@This(), t: *testing_api.T, run_allocator: lib.mem.Allocator) bool {
            _ = runner;
            const Body = struct {
                fn call(a: lib.mem.Allocator) !void {
                    const Http = Utils.Http;
                    const testing = struct {
                        pub var allocator: lib.mem.Allocator = undefined;
                        pub const expect = lib.testing.expect;
                        pub const expectEqual = lib.testing.expectEqual;
                        pub const expectEqualStrings = lib.testing.expectEqualStrings;
                        pub const expectError = lib.testing.expectError;
                    };
                    testing.allocator = a;


                    const accept_count = try Utils.withStaleIdleRetryServer(testing.allocator, .{
                        .warmup_request_line = "GET /warm HTTP/1.1",
                        .warmup_body = "warm",
                        .retry_request_line = "GET /retry-get HTTP/1.1",
                        .retry_response_body = "retried",
                    }, struct {
                        fn run(_: lib.mem.Allocator, port: u16) !void {
                            var transport = try Http.Transport.init(testing.allocator, .{});
                            defer transport.deinit();

                            const warm_url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/warm", .{port});
                            defer testing.allocator.free(warm_url);
                            const retry_url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/retry-get", .{port});
                            defer testing.allocator.free(retry_url);

                            var warm_req = try Http.Request.init(testing.allocator, "GET", warm_url);
                            var warm_resp = try transport.roundTrip(&warm_req);
                            const warm_body = try Utils.readBody(testing.allocator, warm_resp);
                            defer testing.allocator.free(warm_body);
                            try testing.expectEqualStrings("warm", warm_body);
                            warm_resp.deinit();

                            var retry_req = try Http.Request.init(testing.allocator, "GET", retry_url);
                            var retry_resp = try transport.roundTrip(&retry_req);
                            defer retry_resp.deinit();

                            const body = try Utils.readBody(testing.allocator, retry_resp);
                            defer testing.allocator.free(body);
                            try testing.expectEqualStrings("retried", body);
                        }
                    }.run);

                    try testing.expectEqual(@as(usize, 2), accept_count);
                            
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
