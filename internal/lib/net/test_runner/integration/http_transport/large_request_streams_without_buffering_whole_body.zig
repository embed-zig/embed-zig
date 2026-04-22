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


                    const payload = [_]u8{'q'} ** 8192;

                    const BodySource = struct {
                        payload: []const u8,
                        offset: usize = 0,

                        pub fn read(self: *@This(), buf: []u8) anyerror!usize {
                            const remaining = self.payload[self.offset..];
                            const n = @min(buf.len, remaining.len);
                            @memcpy(buf[0..n], remaining[0..n]);
                            self.offset += n;
                            return n;
                        }

                        pub fn close(_: *@This()) void {}
                    };

                    try Utils.withOneShotServer(testing.allocator, .{
                        .expected_request_line = "POST /large-request HTTP/1.1",
                        .expected_request_body = &payload,
                        .status_code = Http.status.ok,
                        .body = "uploaded",
                    }, struct {
                        fn run(_: lib.mem.Allocator, port: u16) !void {
                            var transport = try Http.Transport.init(testing.allocator, .{ .max_body_bytes = payload.len });
                            defer transport.deinit();

                            const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/large-request", .{port});
                            defer testing.allocator.free(url);

                            var source = BodySource{ .payload = &payload };
                            var req = try Http.Request.init(testing.allocator, "POST", url);
                            req = req.withBody(Http.ReadCloser.init(&source));
                            req.content_length = payload.len;

                            var resp = try transport.roundTrip(&req);
                            defer resp.deinit();

                            const body = try Utils.readBody(testing.allocator, resp);
                            defer testing.allocator.free(body);
                            try testing.expectEqualStrings("uploaded", body);
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
