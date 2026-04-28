const stdz = @import("stdz");
const context_mod = @import("context");
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

                    const EmptyState = struct {};
                    try Utils.withServerState(
                        testing.allocator,
                        EmptyState{},
                        struct {
                            fn run(conn: net.Conn, _: *EmptyState) !void {
                                var c = conn;
                                var req_buf: [4096]u8 = undefined;
                                const req_head = try Utils.readRequestHead(conn, &req_buf);
                                try testing.expect(Utils.hasRequestLine(req_head, "GET /body-cancel HTTP/1.1"));

                                io.writeAll(
                                    @TypeOf(c),
                                    &c,
                                    "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\n",
                                ) catch {};
                                // Keep the server-side close comfortably behind the
                                // client-side cancel so this remains a cancellation
                                // test even on slower ARM runners under heavy load.
                                std.Thread.sleep(@intCast(300 * net.time.duration.MilliSecond));
                                io.writeAll(@TypeOf(c), &c, "late") catch {};
                            }
                        }.run,
                        struct {
                            fn run(_: std.mem.Allocator, port: u16, _: *EmptyState) !void {
                                const Context = context_mod.make(std, net.time);
                                var ctx_api = try Context.init(testing.allocator);
                                defer ctx_api.deinit();
                                var ctx = try ctx_api.withCancel(ctx_api.background());
                                defer ctx.deinit();

                                var transport = try Http.Transport.init(testing.allocator, .{});
                                defer transport.deinit();

                                const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/body-cancel", .{port});
                                defer testing.allocator.free(url);

                                var req = try Http.Request.init(testing.allocator, "GET", url);
                                req = req.withContext(ctx);

                                var resp = try transport.roundTrip(&req);
                                defer resp.deinit();

                                const cancel_thread = try std.Thread.spawn(.{}, struct {
                                    fn run(cancel_ctx: context_mod.Context, comptime thread_lib: type) void {
                                        thread_lib.Thread.sleep(@intCast(30 * net.time.duration.MilliSecond));
                                        cancel_ctx.cancel();
                                    }
                                }.run, .{ ctx, std });
                                defer cancel_thread.join();

                                try testing.expectError(error.Canceled, Utils.readBody(testing.allocator, resp));
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
