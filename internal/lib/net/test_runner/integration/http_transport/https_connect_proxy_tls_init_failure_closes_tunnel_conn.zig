const stdz = @import("stdz");
const io = @import("io");
const testing_api = @import("testing");
const test_utils = @import("test_utils.zig");

pub fn make(comptime lib: type, comptime net: type) testing_api.TestRunner {
    const Utils = test_utils.make2(lib, net);

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

                    const EmptyState = struct {};
                    try Utils.withServerState(testing.allocator, 
                        EmptyState{},
                        struct {
                            fn run(conn: net.Conn, _: *EmptyState) !void {
                                var c = conn;
                                var req_buf: [4096]u8 = undefined;
                                const req_head = try Utils.readRequestHead(conn, &req_buf);
                                try testing.expect(Utils.hasRequestLine(req_head, "CONNECT example.com:443 HTTP/1.1"));
                                try io.writeAll(@TypeOf(c), &c, "HTTP/1.1 200 Connection Established\r\nContent-Length: 0\r\n\r\n");

                                c.setReadTimeout(200);
                                var buf: [64]u8 = undefined;
                                const n = c.read(&buf) catch |err| switch (err) {
                                    error.EndOfStream => return,
                                    else => return err,
                                };
                                try testing.expectEqual(@as(usize, 0), n);
                            }
                        }.run,
                        struct {
                            fn run(_: lib.mem.Allocator, port: u16, _: *EmptyState) !void {
                                const proxy_raw_url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}", .{port});
                                defer testing.allocator.free(proxy_raw_url);

                                var transport = try Http.Transport.init(testing.allocator, .{
                                    .https_proxy = .{
                                        .url = try net.url.parse(proxy_raw_url),
                                    },
                                    .tls_client_config = .{
                                        .server_name = "example.com",
                                        .min_version = .tls_1_3,
                                        .max_version = .tls_1_2,
                                    },
                                });
                                defer transport.deinit();

                                var req = try Http.Request.init(testing.allocator, "GET", "https://example.com/tls-init-cleanup");
                                try testing.expectError(error.Unexpected, transport.roundTrip(&req));
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
