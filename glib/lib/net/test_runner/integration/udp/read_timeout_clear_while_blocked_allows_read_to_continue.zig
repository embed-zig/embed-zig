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
                    const Thread = lib.Thread;
                    const ReadyCounter = test_utils.ReadyCounter(lib);

                    const ReadCtx = struct {
                        ready: *ReadyCounter,
                        conn: net.PacketConn,
                        buf: [8]u8 = undefined,
                        result: ?net.PacketConn.ReadFromResult = null,
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
                            ctx.result = ctx.conn.readFrom(&ctx.buf) catch |err| {
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

                    var receiver = try net.listenPacket(.{
                        .allocator = a,
                        .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0),
                    });
                    defer receiver.deinit();

                    var sender = try net.listenPacket(.{
                        .allocator = a,
                        .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0),
                    });
                    defer sender.deinit();

                    const receiver_impl = try receiver.as(net.UdpConn);
                    const dest = test_utils.addr4(.{ 127, 0, 0, 1 }, try receiver_impl.boundPort());

                    receiver.setReadTimeout(30);

                    var ready = ReadyCounter.init(1);
                    var read_ctx = ReadCtx{
                        .ready = &ready,
                        .conn = receiver,
                    };
                    var read_thread = try Thread.spawn(.{}, Worker.read, .{&read_ctx});

                    ready.waitUntilReady();
                    waitUntilReadWaiting(receiver_impl, lib);

                    receiver.setReadTimeout(null);

                    var write_ctx = WriteCtx{
                        .conn = sender,
                        .dest = dest,
                    };
                    var write_thread = try Thread.spawn(.{}, Worker.write, .{ &write_ctx, lib });

                    read_thread.join();
                    write_thread.join();

                    if (read_ctx.err) |err| return err;
                    if (write_ctx.err) |err| return err;
                    const result = read_ctx.result orelse return error.ExpectedReadResult;
                    try lib.testing.expectEqual(@as(usize, 2), result.bytes_read);
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
