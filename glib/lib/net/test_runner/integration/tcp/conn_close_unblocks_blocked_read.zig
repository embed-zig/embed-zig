const stdz = @import("stdz");
const testing_api = @import("testing");
const test_utils = @import("test_utils.zig");

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
                fn waitUntilReadWaiting(conn: *net.TcpConn, comptime thread_lib: type) void {
                    while (true) {
                        conn.read_mu.lock();
                        const waiting = conn.read_waiting;
                        conn.read_mu.unlock();
                        if (waiting) return;
                        thread_lib.Thread.sleep(@intCast(net.time.duration.MilliSecond));
                    }
                }

                fn call(a: std.mem.Allocator) !void {
                    const ReadyCounter = test_utils.ReadyCounter(std);
                    const Thread = std.Thread;

                    const ReadCtx = struct {
                        ready: *ReadyCounter,
                        conn: *net.TcpConn,
                        err: ?anyerror = null,
                    };

                    const Worker = struct {
                        fn read(ctx: *ReadCtx) void {
                            var buf: [16]u8 = undefined;
                            ctx.ready.markReady();
                            _ = ctx.conn.read(&buf) catch |err| {
                                if (err == error.EndOfStream) return;
                                ctx.err = err;
                                return;
                            };
                            ctx.err = error.ExpectedTcpReadToWakeEndOfStream;
                        }
                    };

                    var ln = try net.listen(a, .{ .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0) });
                    defer ln.deinit();

                    const port = try test_utils.listenerPort(ln, net);

                    var cc = try net.dial(a, .tcp, test_utils.addr4(.{ 127, 0, 0, 1 }, port));
                    defer cc.deinit();

                    var ac = try ln.accept();
                    defer ac.deinit();

                    const client = try cc.as(net.TcpConn);

                    var ready = ReadyCounter.init(1);
                    var read_ctx = ReadCtx{
                        .ready = &ready,
                        .conn = client,
                    };
                    var read_thread = try Thread.spawn(.{}, Worker.read, .{&read_ctx});

                    ready.waitUntilReady();
                    waitUntilReadWaiting(client, std);
                    cc.close();
                    read_thread.join();

                    if (read_ctx.err) |err| return err;
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
