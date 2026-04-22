const embed = @import("embed");
const io = @import("io");
const testing_api = @import("testing");
const net_mod = @import("../../../../net.zig");
const test_utils = @import("test_utils.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Utils = test_utils.make(lib);

    const Runner = struct {
        spawn_config: embed.Thread.SpawnConfig = .{ .stack_size = 1024 * 1024 },

        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
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
                            fn run(conn: net_mod.Conn, _: *EmptyState) !void {
                                var c = conn;
                                var req_buf: [4096]u8 = undefined;
                                const req_head = try Utils.readRequestHead(conn, &req_buf);
                                try testing.expect(Utils.hasRequestLine(req_head, "GET /header-timeout-body HTTP/1.1"));

                                io.writeAll(
                                    @TypeOf(c),
                                    &c,
                                    "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\n",
                                ) catch {};
                                lib.Thread.sleep(50 * lib.time.ns_per_ms);
                                io.writeAll(@TypeOf(c), &c, "hello") catch {};
                            }
                        }.run,
                        struct {
                            fn run(_: lib.mem.Allocator, port: u16, _: *EmptyState) !void {
                                var transport = try Http.Transport.init(testing.allocator, .{
                                    .response_header_timeout_ms = 10,
                                });
                                defer transport.deinit();

                                const url = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/header-timeout-body", .{port});
                                defer testing.allocator.free(url);

                                var req = try Http.Request.init(testing.allocator, "GET", url);
                                var resp = try transport.roundTrip(&req);
                                defer resp.deinit();

                                const body = try Utils.readBody(testing.allocator, resp);
                                defer testing.allocator.free(body);
                                try testing.expectEqualStrings("hello", body);
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

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
