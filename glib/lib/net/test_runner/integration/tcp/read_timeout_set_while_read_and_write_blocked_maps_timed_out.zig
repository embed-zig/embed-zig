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
                fn waitUntilReadWaiting(conn: *net.TcpConn, ctx: anytype, comptime thread_lib: type) !void {
                    const deadline = thread_lib.time.nanoTimestamp() + 2 * thread_lib.time.ns_per_s;
                    while (true) {
                        conn.read_mu.lock();
                        const waiting = conn.read_waiting;
                        conn.read_mu.unlock();
                        if (waiting) return;
                        if (ctx.err != null) return error.ReadWorkerExitedBeforeWait;
                        if (thread_lib.time.nanoTimestamp() >= deadline) return error.ExpectedReadWaiting;
                        thread_lib.Thread.sleep(thread_lib.time.ns_per_ms);
                    }
                }

                fn waitUntilWriteWaiting(conn: *net.TcpConn, ctx: anytype, comptime thread_lib: type) !void {
                    const deadline = thread_lib.time.nanoTimestamp() + 2 * thread_lib.time.ns_per_s;
                    while (true) {
                        conn.write_mu.lock();
                        const waiting = conn.write_waiting;
                        conn.write_mu.unlock();
                        if (waiting) return;
                        if (ctx.err != null) return error.WriteWorkerExitedBeforeWait;
                        if (thread_lib.time.nanoTimestamp() >= deadline) return error.ExpectedWriteWaiting;
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

                    const WriteCtx = struct {
                        ready: *ReadyCounter,
                        conn: *Net.TcpConn,
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

                        fn write(ctx: *WriteCtx) void {
                            var chunk: [65536]u8 = @splat(0x5a);
                            ctx.ready.markReady();
                            while (true) {
                                _ = ctx.conn.write(&chunk) catch |err| {
                                    ctx.err = err;
                                    return;
                                };
                            }
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

                    var read_ready = ReadyCounter.init(1);
                    var read_ctx = ReadCtx{
                        .ready = &read_ready,
                        .conn = client_conn,
                    };
                    var read_thread = try Thread.spawn(.{}, Worker.read, .{&read_ctx});

                    var write_ready = ReadyCounter.init(1);
                    var write_ctx = WriteCtx{
                        .ready = &write_ready,
                        .conn = client,
                    };
                    var write_thread = try Thread.spawn(.{}, Worker.write, .{&write_ctx});

                    read_ready.waitUntilReady();
                    write_ready.waitUntilReady();
                    try waitUntilReadWaiting(client, &read_ctx, lib);
                    try waitUntilWriteWaiting(client, &write_ctx, lib);

                    client_conn.setReadTimeout(30);

                    read_thread.join();
                    try lib.testing.expect(read_ctx.err != null);
                    try lib.testing.expect(read_ctx.err.? == error.TimedOut);

                    client.close();
                    write_thread.join();
                    try lib.testing.expect(write_ctx.err != null);
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
