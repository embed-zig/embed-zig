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


                    const payload = [_]u8{'r'} ** 8192;

                    try Utils.withOneShotServer(testing.allocator, .{
                        .expected_request_line = "GET /large-response HTTP/1.1",
                        .status_code = Http.status.ok,
                        .body = &payload,
                    }, struct {
                        fn run(_: lib.mem.Allocator, port: u16) !void {
                            var transport = try Http.Transport.init(testing.allocator, .{ .max_body_bytes = payload.len });
                            defer transport.deinit();

                            const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/large-response", .{port});
                            defer testing.allocator.free(url);

                            var req = try Http.Request.init(testing.allocator, "GET", url);
                            var resp = try transport.roundTrip(&req);
                            defer resp.deinit();

                            const body = try Utils.readBody(testing.allocator, resp);
                            defer testing.allocator.free(body);
                            try testing.expectEqual(@as(usize, payload.len), body.len);
                            try testing.expectEqualStrings(&payload, body);
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
