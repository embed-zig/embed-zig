const embed = @import("embed");
const context_mod = @import("context");
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


                    const State = struct {};
                    try Utils.withServerState(testing.allocator, 
                        State{},
                        struct {
                            fn run(conn: net_mod.Conn, _: *State) !void {
                                var c = conn;
                                var req_buf: [4096]u8 = undefined;
                                const req_head = try Utils.readRequestHead(conn, &req_buf);
                                try testing.expect(Utils.hasRequestLine(req_head, "GET /max-deadline-1 HTTP/1.1"));
                                io.writeAll(@TypeOf(c), &c, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: keep-alive\r\n\r\nhello") catch {};
                                c.setReadTimeout(80);
                                _ = c.read(&req_buf) catch |err| switch (err) {
                                    error.TimedOut, error.EndOfStream => return,
                                    else => return err,
                                };
                            }
                        }.run,
                        struct {
                            fn run(_: lib.mem.Allocator, port: u16, _: *State) !void {
                                var transport = try Http.Transport.init(testing.allocator, .{
                                    .max_conns_per_host = 1,
                                });
                                defer transport.deinit();

                                const Context = context_mod.make(lib);
                                var ctx_api = try Context.init(testing.allocator);
                                defer ctx_api.deinit();

                                const url1 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/max-deadline-1", .{port});
                                defer testing.allocator.free(url1);
                                const url2 = try lib.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/max-deadline-2", .{port});
                                defer testing.allocator.free(url2);

                                var req1 = try Http.Request.init(testing.allocator, "GET", url1);
                                var resp1 = try transport.roundTrip(&req1);
                                defer resp1.deinit();

                                var timeout_ctx = try ctx_api.withTimeout(ctx_api.background(), 30 * lib.time.ns_per_ms);
                                defer timeout_ctx.deinit();
                                var req2 = try Http.Request.init(testing.allocator, "GET", url2);
                                req2 = req2.withContext(timeout_ctx);

                                try testing.expectError(error.DeadlineExceeded, transport.roundTrip(&req2));
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
