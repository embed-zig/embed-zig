const stdz = @import("stdz");
const io = @import("io");
const testing_api = @import("testing");
const test_utils = @import("test_utils.zig");

pub fn make(comptime lib: type, comptime net: type) testing_api.TestRunner {
    const Runner = struct {
        spawn_config: stdz.Thread.SpawnConfig = .{ .stack_size = 320 * 1024 },

        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            const Body = struct {
                fn call(a: lib.mem.Allocator) !void {
                    const Net = net;
                    const Thread = lib.Thread;
                    const ReadyCounter = test_utils.ReadyCounter(lib);

                    const client_msg_len = "client1".len;

                    const AcceptCtx = struct {
                        ready: *ReadyCounter,
                        listener: net.Listener,
                        result: ?anyerror = null,
                        len: usize = 0,
                        payload: [16]u8 = [_]u8{0} ** 16,
                    };

                    const Worker = struct {
                        fn accept(ctx: *AcceptCtx) void {
                            ctx.ready.markReady();
                            var conn = ctx.listener.accept() catch |err| {
                                ctx.result = err;
                                return;
                            };
                            defer conn.deinit();

                            conn.setReadTimeout(10_000);
                            conn.setWriteTimeout(10_000);

                            io.readFull(@TypeOf(conn), &conn, ctx.payload[0..client_msg_len]) catch |err| {
                                ctx.result = err;
                                return;
                            };
                            ctx.len = client_msg_len;

                            io.writeAll(@TypeOf(conn), &conn, "ack") catch |err| {
                                ctx.result = err;
                            };
                        }
                    };

                    var ln = try Net.listen(a, .{ .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0) });
                    defer ln.deinit();

                    const port = try test_utils.listenerPort(ln, Net);
                    const dest = test_utils.addr4(.{ 127, 0, 0, 1 }, port);

                    var ready = ReadyCounter.init(2);
                    var accept1 = AcceptCtx{ .ready = &ready, .listener = ln };
                    var accept2 = AcceptCtx{ .ready = &ready, .listener = ln };

                    var t1 = try Thread.spawn(.{}, Worker.accept, .{&accept1});
                    var t2 = try Thread.spawn(.{}, Worker.accept, .{&accept2});

                    ready.waitUntilReady();

                    var c1 = try Net.dial(a, .tcp, dest);
                    defer c1.deinit();
                    var c2 = try Net.dial(a, .tcp, dest);
                    defer c2.deinit();

                    c1.setReadTimeout(10_000);
                    c1.setWriteTimeout(10_000);
                    c2.setReadTimeout(10_000);
                    c2.setWriteTimeout(10_000);

                    try io.writeAll(@TypeOf(c1), &c1, "client1");
                    try io.writeAll(@TypeOf(c2), &c2, "client2");

                    var ack: [3]u8 = undefined;
                    try io.readFull(@TypeOf(c1), &c1, &ack);
                    try lib.testing.expectEqualStrings("ack", &ack);
                    try io.readFull(@TypeOf(c2), &c2, &ack);
                    try lib.testing.expectEqualStrings("ack", &ack);

                    t1.join();
                    t2.join();

                    if (accept1.result) |err| return err;
                    if (accept2.result) |err| return err;

                    const got1 = accept1.payload[0..accept1.len];
                    const got2 = accept2.payload[0..accept2.len];
                    const ok =
                        (lib.mem.eql(u8, got1, "client1") and lib.mem.eql(u8, got2, "client2")) or
                        (lib.mem.eql(u8, got1, "client2") and lib.mem.eql(u8, got2, "client1"));
                    try lib.testing.expect(ok);
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
