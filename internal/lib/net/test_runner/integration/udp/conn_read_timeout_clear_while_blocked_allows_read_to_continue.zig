const stdz = @import("stdz");
const testing_api = @import("testing");
const test_utils = @import("../tcp/test_utils.zig");

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
                fn waitUntilReadWaiting(impl: *net.UdpConn, comptime thread_lib: type) void {
                    while (true) {
                        impl.read_mu.lock();
                        const waiting = impl.read_waiting;
                        impl.read_mu.unlock();
                        if (waiting) return;
                        thread_lib.Thread.sleep(thread_lib.time.ns_per_ms);
                    }
                }

                fn call(a: lib.mem.Allocator) !void {
                    const ReadyCounter = test_utils.ReadyCounter(lib);
                    const Thread = lib.Thread;

                    const ReadCtx = struct {
                        ready: *ReadyCounter,
                        conn: net.Conn,
                        buf: [8]u8 = undefined,
                        bytes_read: ?usize = null,
                        err: ?anyerror = null,
                    };

                    const WriteCtx = struct {
                        conn: net.PacketConn,
                        dest: net.netip.AddrPort,
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
                            _ = ctx.conn.writeTo("ok", ctx.dest) catch |err| {
                                ctx.err = err;
                            };
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
                    const conn_addr = test_utils.addr4(.{ 127, 0, 0, 1 }, try conn_impl.boundPort());

                    conn.setReadTimeout(30);

                    var ready = ReadyCounter.init(1);
                    var read_ctx = ReadCtx{
                        .ready = &ready,
                        .conn = conn,
                    };
                    var read_thread = try Thread.spawn(.{}, Worker.read, .{&read_ctx});

                    ready.waitUntilReady();
                    waitUntilReadWaiting(conn_impl, lib);

                    conn.setReadTimeout(null);

                    var write_ctx = WriteCtx{
                        .conn = server_pc,
                        .dest = conn_addr,
                    };
                    var write_thread = try Thread.spawn(.{}, Worker.write, .{ &write_ctx, lib });

                    read_thread.join();
                    write_thread.join();

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
