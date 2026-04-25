const stdz = @import("stdz");
const testing_api = @import("testing");
const test_utils = @import("test_utils.zig");

pub fn make(comptime lib: type, comptime net: type) testing_api.TestRunner {
    const Runner = struct {
        spawn_config: stdz.Thread.SpawnConfig = .{ .stack_size = 192 * 1024 },

        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            const Body = struct {
                fn waitUntilReadWaiting(conn: *net.TcpConn, comptime thread_lib: type) void {
                    while (true) {
                        conn.read_mu.lock();
                        const waiting = conn.read_waiting;
                        conn.read_mu.unlock();
                        if (waiting) return;
                        thread_lib.Thread.sleep(thread_lib.time.ns_per_ms);
                    }
                }

                fn call(a: lib.mem.Allocator) !void {
                    const Net = net;
                    const Thread = lib.Thread;
                    const ReadyCounter = test_utils.ReadyCounter(lib);

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
                            thread_lib.Thread.sleep(200 * thread_lib.time.ns_per_ms);
                            conn.close();
                        }
                    };

                    var ln = try Net.listen(a, .{ .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0) });
                    defer ln.deinit();

                    const port = try test_utils.listenerPort(ln, Net);

                    var client = try Net.dial(a, .tcp, test_utils.addr4(.{ 127, 0, 0, 1 }, port));
                    defer client.deinit();

                    var server = try ln.accept();
                    defer server.deinit();

                    const server_impl = try server.as(Net.TcpConn);

                    var ready = ReadyCounter.init(1);
                    var read_ctx = ReadCtx{
                        .ready = &ready,
                        .conn = server,
                    };
                    var read_thread = try Thread.spawn(.{}, Worker.read, .{&read_ctx});
                    var close_thread = try Thread.spawn(.{}, Worker.closeLater, .{ server, lib });

                    ready.waitUntilReady();
                    waitUntilReadWaiting(server_impl, lib);
                    server.setReadTimeout(30);

                    read_thread.join();
                    close_thread.join();

                    try lib.testing.expect(read_ctx.err != null);
                    try lib.testing.expect(read_ctx.err.? == error.TimedOut);
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
