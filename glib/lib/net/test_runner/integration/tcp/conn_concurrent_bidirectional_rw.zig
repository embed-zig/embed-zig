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
                    const StartGate = test_utils.StartGate(lib);

                    const ReadCtx = struct {
                        gate: *StartGate,
                        conn: net.Conn,
                        buf: []u8,
                        result: ?anyerror = null,
                    };

                    const WriteCtx = struct {
                        gate: *StartGate,
                        conn: net.Conn,
                        buf: []const u8,
                        result: ?anyerror = null,
                    };

                    const Worker = struct {
                        fn read(ctx: *ReadCtx) void {
                            ctx.gate.wait();
                            io.readFull(@TypeOf(ctx.conn), &ctx.conn, ctx.buf) catch |err| {
                                ctx.result = err;
                            };
                        }

                        fn write(ctx: *WriteCtx) void {
                            ctx.gate.wait();
                            io.writeAll(@TypeOf(ctx.conn), &ctx.conn, ctx.buf) catch |err| {
                                ctx.result = err;
                            };
                        }
                    };

                    var ln = try Net.listen(a, .{ .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0) });
                    defer ln.deinit();

                    const port = try test_utils.listenerPort(ln, Net);
                    const dest = test_utils.addr4(.{ 127, 0, 0, 1 }, port);

                    var cc = try Net.dial(a, .tcp, dest);
                    defer cc.deinit();
                    var ac = try ln.accept();
                    defer ac.deinit();

                    cc.setReadTimeout(10_000);
                    cc.setWriteTimeout(10_000);
                    ac.setReadTimeout(10_000);
                    ac.setWriteTimeout(10_000);

                    const client_len = 128 * 1024 + 257;
                    const server_len = 96 * 1024 + 113;

                    const client_payload = try a.alloc(u8, client_len);
                    defer a.free(client_payload);
                    test_utils.fillPattern(client_payload, 17);

                    const server_payload = try a.alloc(u8, server_len);
                    defer a.free(server_payload);
                    test_utils.fillPattern(server_payload, 91);

                    const client_received = try a.alloc(u8, server_len);
                    defer a.free(client_received);

                    const server_received = try a.alloc(u8, client_len);
                    defer a.free(server_received);

                    var gate = StartGate.init(4);
                    var client_reader = ReadCtx{ .gate = &gate, .conn = cc, .buf = client_received };
                    var client_writer = WriteCtx{ .gate = &gate, .conn = cc, .buf = client_payload };
                    var server_reader = ReadCtx{ .gate = &gate, .conn = ac, .buf = server_received };
                    var server_writer = WriteCtx{ .gate = &gate, .conn = ac, .buf = server_payload };

                    var client_reader_thread = try Thread.spawn(.{}, Worker.read, .{&client_reader});
                    var client_writer_thread = try Thread.spawn(.{}, Worker.write, .{&client_writer});
                    var server_reader_thread = try Thread.spawn(.{}, Worker.read, .{&server_reader});
                    var server_writer_thread = try Thread.spawn(.{}, Worker.write, .{&server_writer});
                    client_reader_thread.join();
                    client_writer_thread.join();
                    server_reader_thread.join();
                    server_writer_thread.join();

                    if (client_reader.result) |err| return err;
                    if (client_writer.result) |err| return err;
                    if (server_reader.result) |err| return err;
                    if (server_writer.result) |err| return err;

                    try lib.testing.expectEqualSlices(u8, server_payload, client_received);
                    try lib.testing.expectEqualSlices(u8, client_payload, server_received);
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
