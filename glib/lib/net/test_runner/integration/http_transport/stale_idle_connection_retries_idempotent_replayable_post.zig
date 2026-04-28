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

                    const OwnedBodySource = struct {
                        allocator: std.mem.Allocator,
                        payload: []const u8,
                        offset: usize = 0,

                        pub fn read(self: *@This(), buf: []u8) anyerror!usize {
                            const remaining = self.payload[self.offset..];
                            if (remaining.len == 0) return 0;
                            const n = @min(buf.len, remaining.len);
                            @memcpy(buf[0..n], remaining[0..n]);
                            self.offset += n;
                            return n;
                        }

                        pub fn close(self: *@This()) void {
                            self.allocator.destroy(self);
                        }
                    };

                    const ReplayBodyFactory = struct {
                        allocator: std.mem.Allocator,
                        payload: []const u8,
                        calls: usize = 0,

                        pub fn getBody(self: *@This()) anyerror!Http.ReadCloser {
                            self.calls += 1;
                            const body = try self.allocator.create(OwnedBodySource);
                            body.* = .{
                                .allocator = self.allocator,
                                .payload = self.payload,
                            };
                            return Http.ReadCloser.init(body);
                        }
                    };
                    const payload = "retry payload";
                    const accept_count = try Utils.withStaleIdleRetryServer(testing.allocator, .{
                        .warmup_request_line = "GET /warm-post HTTP/1.1",
                        .warmup_body = "warm",
                        .retry_request_line = "POST /retry-post HTTP/1.1",
                        .retry_request_body = payload,
                        .retry_response_body = "posted",
                    }, struct {
                        fn run(_: std.mem.Allocator, port: u16) !void {
                            var transport = try Http.Transport.init(testing.allocator, .{});
                            defer transport.deinit();

                            const warm_url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/warm-post", .{port});
                            defer testing.allocator.free(warm_url);
                            const retry_url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/retry-post", .{port});
                            defer testing.allocator.free(retry_url);

                            var warm_req = try Http.Request.init(testing.allocator, "GET", warm_url);
                            var warm_resp = try transport.roundTrip(&warm_req);
                            const warm_body = try Utils.readBody(testing.allocator, warm_resp);
                            defer testing.allocator.free(warm_body);
                            try testing.expectEqualStrings("warm", warm_body);
                            warm_resp.deinit();

                            var body_factory = ReplayBodyFactory{
                                .allocator = testing.allocator,
                                .payload = payload,
                            };
                            const initial_body_source = try testing.allocator.create(OwnedBodySource);
                            initial_body_source.* = .{
                                .allocator = testing.allocator,
                                .payload = payload,
                            };
                            const initial_body = Http.ReadCloser.init(initial_body_source);

                            var req = try Http.Request.init(testing.allocator, "POST", retry_url);
                            req = req.withBody(initial_body);
                            req = req.withGetBody(Http.Request.GetBody.init(&body_factory));
                            req.header = &.{Http.Header.init("Idempotency-Key", "abc123")};
                            req.content_length = payload.len;

                            var resp = try transport.roundTrip(&req);
                            defer resp.deinit();

                            const body = try Utils.readBody(testing.allocator, resp);
                            defer testing.allocator.free(body);
                            try testing.expectEqualStrings("posted", body);
                            try testing.expectEqual(@as(usize, 1), body_factory.calls);
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
