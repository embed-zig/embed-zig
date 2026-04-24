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
                fn call(a: lib.mem.Allocator) !void {
                    const Net = net;
                    const Thread = lib.Thread;
                    const ReadyCounter = test_utils.ReadyCounter(lib);
                    const AtomicBool = lib.atomic.Value(bool);
                    const AtomicUsize = lib.atomic.Value(usize);
                    const chunk_len = 64 * 1024;
                    const target_bytes = 16 * 1024 * 1024;
                    const initial_timeout_ms = 200;

                    const WriteCtx = struct {
                        ready: *ReadyCounter,
                        conn: *Net.TcpConn,
                        bytes_written: AtomicUsize = AtomicUsize.init(0),
                        done: AtomicBool = AtomicBool.init(false),
                        err: ?anyerror = null,
                    };

                    const Worker = struct {
                        fn write(ctx: *WriteCtx) void {
                            var chunk: [chunk_len]u8 = undefined;
                            test_utils.fillPattern(&chunk, 0x42);
                            var total: usize = 0;
                            ctx.ready.markReady();
                            while (total < target_bytes) {
                                const to_write = @min(chunk.len, target_bytes - total);
                                const n = ctx.conn.write(chunk[0..to_write]) catch |err| {
                                    ctx.err = err;
                                    return;
                                };
                                total += n;
                                ctx.bytes_written.store(total, .seq_cst);
                            }
                            ctx.done.store(true, .seq_cst);
                        }
                    };

                    var ln = try Net.listen(a, .{ .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0) });
                    defer ln.deinit();

                    const port = try test_utils.listenerPort(ln, Net);

                    var client = try Net.dial(a, .tcp, test_utils.addr4(.{ 127, 0, 0, 1 }, port));
                    defer client.deinit();

                    var server = try ln.accept();
                    defer server.deinit();

                    client.setWriteTimeout(initial_timeout_ms);

                    var ready = ReadyCounter.init(1);
                    var write_ctx = WriteCtx{
                        .ready = &ready,
                        .conn = try client.as(Net.TcpConn),
                    };
                    var write_thread = try Thread.spawn(.{}, Worker.write, .{&write_ctx});

                    ready.waitUntilReady();

                    var stalled = false;
                    var prev = write_ctx.bytes_written.load(.seq_cst);
                    for (0..20) |_| {
                        Thread.sleep(10 * lib.time.ns_per_ms);
                        const current = write_ctx.bytes_written.load(.seq_cst);
                        if (!write_ctx.done.load(.seq_cst) and current == prev) {
                            stalled = true;
                            break;
                        }
                        prev = current;
                    }
                    try lib.testing.expect(stalled);

                    client.setWriteTimeout(null);

                    // Wait past the original deadline before draining to ensure the
                    // blocked write re-evaluates the cleared timeout rather than the
                    // stale deadline it started with.
                    Thread.sleep((initial_timeout_ms + 50) * lib.time.ns_per_ms);

                    var recv_buf: [chunk_len]u8 = undefined;
                    var total_read: usize = 0;
                    while (total_read < target_bytes) {
                        const to_read = @min(recv_buf.len, target_bytes - total_read);
                        total_read += try server.read(recv_buf[0..to_read]);
                    }

                    write_thread.join();

                    if (write_ctx.err) |err| return err;
                    try lib.testing.expect(write_ctx.done.load(.seq_cst));
                    try lib.testing.expectEqual(@as(usize, target_bytes), total_read);
                    try lib.testing.expectEqual(@as(usize, target_bytes), write_ctx.bytes_written.load(.seq_cst));
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
