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
                fn waitUntilWriteWaiting(conn: *net.TcpConn, comptime thread_lib: type) void {
                    while (true) {
                        conn.write_mu.lock();
                        const waiting = conn.write_waiting;
                        conn.write_mu.unlock();
                        if (waiting) return;
                        thread_lib.Thread.sleep(thread_lib.time.ns_per_ms);
                    }
                }

                fn call(a: lib.mem.Allocator) !void {
                    const Net = net;
                    const Thread = lib.Thread;
                    const ReadyCounter = test_utils.ReadyCounter(lib);

                    const WriteCtx = struct {
                        ready: *ReadyCounter,
                        conn: *Net.TcpConn,
                        err: ?anyerror = null,
                    };

                    const Worker = struct {
                        fn write(ctx: *WriteCtx) void {
                            var chunk: [65536]u8 = @splat(0x65);
                            ctx.ready.markReady();
                            while (true) {
                                _ = ctx.conn.write(&chunk) catch |err| {
                                    ctx.err = err;
                                    return;
                                };
                            }
                        }

                        fn closeLater(conn: *Net.TcpConn, comptime thread_lib: type) void {
                            thread_lib.Thread.sleep(200 * thread_lib.time.ns_per_ms);
                            conn.close();
                        }
                    };

                    var ln = try Net.listen(a, .{ .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0) });
                    defer ln.deinit();

                    const port = try test_utils.listenerPort(ln, Net);

                    var client_conn = try Net.dial(a, .tcp, test_utils.addr4(.{ 127, 0, 0, 1 }, port));
                    defer client_conn.deinit();

                    var server_conn = try ln.accept();
                    defer server_conn.deinit();

                    const client = try client_conn.as(Net.TcpConn);

                    var ready = ReadyCounter.init(1);
                    var write_ctx = WriteCtx{
                        .ready = &ready,
                        .conn = client,
                    };
                    var write_thread = try Thread.spawn(.{}, Worker.write, .{&write_ctx});
                    var close_thread = try Thread.spawn(.{}, Worker.closeLater, .{ client, lib });

                    ready.waitUntilReady();
                    waitUntilWriteWaiting(client, lib);
                    client_conn.setWriteTimeout(30);

                    write_thread.join();
                    close_thread.join();

                    try lib.testing.expect(write_ctx.err != null);
                    try lib.testing.expect(write_ctx.err.? == error.TimedOut);
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
