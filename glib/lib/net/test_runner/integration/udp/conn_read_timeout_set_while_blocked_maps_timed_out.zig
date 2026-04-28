const stdz = @import("stdz");
const testing_api = @import("testing");
const test_utils = @import("../tcp/test_utils.zig");

pub fn make(comptime std: type, comptime net: type) testing_api.TestRunner {
    const Runner = struct {
        spawn_config: stdz.Thread.SpawnConfig = .{ .stack_size = 192 * 1024 },

        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            const Body = struct {
                fn waitUntilReadWaiting(impl: *net.UdpConn, comptime thread_lib: type) void {
                    while (true) {
                        impl.read_mu.lock();
                        const waiting = impl.read_waiting;
                        impl.read_mu.unlock();
                        if (waiting) return;
                        thread_lib.Thread.sleep(@intCast(net.time.duration.MilliSecond));
                    }
                }

                fn call(a: std.mem.Allocator) !void {
                    const ReadyCounter = test_utils.ReadyCounter(std);
                    const Thread = std.Thread;

                    const ReadCtx = struct {
                        ready: *ReadyCounter,
                        conn: net.Conn,
                        err: ?anyerror = null,
                    };

                    const Worker = struct {
                        fn read(ctx: *ReadCtx) void {
                            var buf: [8]u8 = undefined;
                            ctx.ready.markReady();
                            _ = ctx.conn.read(&buf) catch |err| {
                                ctx.err = err;
                                return;
                            };
                            ctx.err = error.ExpectedTimedOut;
                        }

                        fn closeLater(conn: net.Conn, comptime thread_lib: type) void {
                            thread_lib.Thread.sleep(@intCast(200 * net.time.duration.MilliSecond));
                            conn.close();
                        }
                    };

                    var server_pc = try net.listenPacket(.{
                        .allocator = a,
                        .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0),
                    });
                    defer server_pc.deinit();

                    const server_port = try (try server_pc.as(net.UdpConn)).boundPort();

                    var conn = try net.dial(a, .udp, test_utils.addr4(.{ 127, 0, 0, 1 }, server_port));
                    defer conn.deinit();
                    const conn_impl = try conn.as(net.UdpConn);

                    var ready = ReadyCounter.init(1);
                    var read_ctx = ReadCtx{
                        .ready = &ready,
                        .conn = conn,
                    };
                    var read_thread = try Thread.spawn(.{}, Worker.read, .{&read_ctx});
                    var close_thread = try Thread.spawn(.{}, Worker.closeLater, .{ conn, std });

                    ready.waitUntilReady();
                    waitUntilReadWaiting(conn_impl, std);
                    conn.setReadDeadline(net.time.instant.add(net.time.instant.now(), 30 * net.time.duration.MilliSecond));

                    read_thread.join();
                    close_thread.join();

                    try std.testing.expect(read_ctx.err != null);
                    try std.testing.expect(read_ctx.err.? == error.TimedOut);
                }
            };
            Body.call(allocator) catch |err| {
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
