const context_mod = @import("context");
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
                fn call(a: std.mem.Allocator) !void {
                    const Net = net;
                    const Context = context_mod.make(std, net.time);
                    const Thread = std.Thread;
                    const ReadyCounter = test_utils.ReadyCounter(std);

                    const WriteCtx = struct {
                        ready: *ReadyCounter,
                        conn: *Net.TcpConn,
                        err: ?anyerror = null,
                    };

                    const Worker = struct {
                        fn write(ctx: *WriteCtx) void {
                            var chunk: [65536]u8 = @splat(0x63);
                            ctx.ready.markReady();
                            while (true) {
                                _ = ctx.conn.write(&chunk) catch |err| {
                                    ctx.err = err;
                                    return;
                                };
                            }
                        }
                    };

                    var ctx_api = try Context.init(a);
                    defer ctx_api.deinit();

                    var io_ctx = try ctx_api.withCancel(ctx_api.background());
                    defer io_ctx.deinit();

                    var ln = try Net.listen(a, .{ .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0) });
                    defer ln.deinit();

                    const port = try test_utils.listenerPort(ln, Net);

                    var cc = try Net.dial(a, .tcp, test_utils.addr4(.{ 127, 0, 0, 1 }, port));
                    defer cc.deinit();

                    var ac = try ln.accept();
                    defer ac.deinit();

                    const client = try cc.as(Net.TcpConn);
                    try client.setWriteContext(io_ctx);

                    var ready = ReadyCounter.init(1);
                    var write_ctx = WriteCtx{
                        .ready = &ready,
                        .conn = client,
                    };
                    var write_thread = try Thread.spawn(.{}, Worker.write, .{&write_ctx});

                    ready.waitUntilReady();

                    var cancel_thread = try Thread.spawn(.{}, struct {
                        fn run(ctx: context_mod.Context, comptime thread_lib: type) void {
                            thread_lib.Thread.sleep(@intCast(30 * net.time.duration.MilliSecond));
                            ctx.cancel();
                        }
                    }.run, .{ io_ctx, std });

                    var close_thread = try Thread.spawn(.{}, struct {
                        fn run(conn: *Net.TcpConn, comptime thread_lib: type) void {
                            thread_lib.Thread.sleep(@intCast(200 * net.time.duration.MilliSecond));
                            conn.close();
                        }
                    }.run, .{ client, std });

                    write_thread.join();
                    cancel_thread.join();
                    close_thread.join();

                    try std.testing.expect(write_ctx.err != null);
                    try std.testing.expect(write_ctx.err.? == error.TimedOut);
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
