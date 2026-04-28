const stdz = @import("stdz");
const io = @import("io");
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

                    const State = struct {
                        fill: []u8,
                    };

                    const fill = try testing.allocator.alloc(u8, 32 * 1024);
                    defer testing.allocator.free(fill);
                    @memset(fill, 'h');

                    try Utils.withServerState(
                        testing.allocator,
                        State{ .fill = fill },
                        struct {
                            fn run(conn: net.Conn, state: *State) !void {
                                var c = conn;
                                var req_buf: [4096]u8 = undefined;
                                const req_head = try Utils.readRequestHead(conn, &req_buf);
                                try testing.expect(Utils.hasRequestLine(req_head, "GET /large-header-default HTTP/1.1"));

                                var head = try std.ArrayList(u8).initCapacity(testing.allocator, 0);
                                defer head.deinit(testing.allocator);
                                try head.appendSlice(testing.allocator, "HTTP/1.1 200 OK\r\nX-Fill: ");
                                try head.appendSlice(testing.allocator, state.fill);
                                try head.appendSlice(testing.allocator, "\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
                                try io.writeAll(@TypeOf(c), &c, head.items);
                            }
                        }.run,
                        struct {
                            fn run(_: std.mem.Allocator, port: u16, _: *State) !void {
                                var transport = try Http.Transport.init(testing.allocator, .{
                                    .max_header_bytes = 64 * 1024,
                                });
                                defer transport.deinit();

                                const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/large-header-default", .{port});
                                defer testing.allocator.free(url);

                                var req = try Http.Request.init(testing.allocator, "GET", url);
                                var resp = try transport.roundTrip(&req);
                                defer resp.deinit();

                                const body = try Utils.readBody(testing.allocator, resp);
                                defer testing.allocator.free(body);
                                try testing.expectEqualStrings("ok", body);
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
