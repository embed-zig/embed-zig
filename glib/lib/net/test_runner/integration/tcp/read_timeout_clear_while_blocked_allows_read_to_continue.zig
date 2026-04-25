const stdz = @import("stdz");
const io = @import("io");
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
                        buf: [8]u8 = undefined,
                        bytes_read: ?usize = null,
                        err: ?anyerror = null,
                    };

                    const WriteCtx = struct {
                        conn: net.Conn,
                        err: ?anyerror = null,
                    };

                    const Worker = struct {
                        fn read(ctx: *ReadCtx) void {
                            ctx.ready.markReady();
                            ctx.bytes_read = ctx.conn.read(&ctx.buf) catch |err| {
                                ctx.err = err;
                                return;
                            };
                        }

                        fn write(ctx: *WriteCtx, comptime thread_lib: type) void {
                            thread_lib.Thread.sleep(60 * thread_lib.time.ns_per_ms);
                            io.writeAll(@TypeOf(ctx.conn), &ctx.conn, "ok") catch |err| {
                                ctx.err = err;
                            };
                        }
                    };

                    var ln = try Net.listen(a, .{ .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0) });
                    defer ln.deinit();

                    const port = try test_utils.listenerPort(ln, Net);

                    var cc = try Net.dial(a, .tcp, test_utils.addr4(.{ 127, 0, 0, 1 }, port));
                    defer cc.deinit();

                    var ac = try ln.accept();
                    defer ac.deinit();

                    const accepted = try ac.as(Net.TcpConn);
                    accepted.setReadTimeout(30);

                    var read_ready = ReadyCounter.init(1);
                    var read_ctx = ReadCtx{
                        .ready = &read_ready,
                        .conn = ac,
                    };
                    var read_thread = try Thread.spawn(.{}, Worker.read, .{&read_ctx});

                    read_ready.waitUntilReady();
                    waitUntilReadWaiting(accepted, lib);

                    accepted.setReadTimeout(null);

                    var write_ctx = WriteCtx{ .conn = cc };
                    var writer_thread = try Thread.spawn(.{}, Worker.write, .{ &write_ctx, lib });

                    read_thread.join();
                    writer_thread.join();

                    if (read_ctx.err) |err| return err;
                    if (write_ctx.err) |err| return err;
                    try lib.testing.expectEqual(@as(?usize, 2), read_ctx.bytes_read);
                    try lib.testing.expectEqualStrings("ok", read_ctx.buf[0..2]);
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
