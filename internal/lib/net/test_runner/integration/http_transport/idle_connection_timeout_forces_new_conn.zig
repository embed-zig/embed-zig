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


                    const accept_count = try Utils.withTwoRequestKeepAliveServer(testing.allocator, .{
                        .first_request_line = "GET /idle-timeout-1 HTTP/1.1",
                        .second_request_line = "GET /idle-timeout-2 HTTP/1.1",
                        .first_body = "one",
                        .second_body = "two",
                        .reuse_wait_timeout_ms = 150,
                    }, struct {
                        fn run(_: lib.mem.Allocator, port: u16) !void {
                            var transport = try Http.Transport.init(testing.allocator, .{
                                .idle_conn_timeout_ms = 10,
                            });
                            defer transport.deinit();

                            const url1 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/idle-timeout-1", .{port});
                            defer testing.allocator.free(url1);
                            const url2 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/idle-timeout-2", .{port});
                            defer testing.allocator.free(url2);

                            var req1 = try Http.Request.init(testing.allocator, "GET", url1);
                            var resp1 = try transport.roundTrip(&req1);
                            const body1 = try Utils.readBody(testing.allocator, resp1);
                            defer testing.allocator.free(body1);
                            try testing.expectEqualStrings("one", body1);
                            resp1.deinit();

                            lib.Thread.sleep(80 * lib.time.ns_per_ms);

                            var req2 = try Http.Request.init(testing.allocator, "GET", url2);
                            var resp2 = try transport.roundTrip(&req2);
                            defer resp2.deinit();
                            const body2 = try Utils.readBody(testing.allocator, resp2);
                            defer testing.allocator.free(body2);
                            try testing.expectEqualStrings("two", body2);
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
