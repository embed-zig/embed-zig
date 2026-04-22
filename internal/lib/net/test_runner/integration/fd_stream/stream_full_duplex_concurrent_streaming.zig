const embed = @import("embed");
const fd_mod = @import("../../../fd.zig");
const netip = @import("../../../netip.zig");
const testing_api = @import("testing");
const test_utils = @import("test_utils.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        spawn_config: embed.Thread.SpawnConfig = .{ .stack_size = 192 * 1024 },

        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            const Body = struct {
                fn call(a: lib.mem.Allocator) !void {
                    const Harness = test_utils.Harness(lib);
                    const Stream = fd_mod.Stream(lib);
                    const posix = lib.posix;
                    const Thread = lib.Thread;
                    const testing = lib.testing;
                    var listener = try Harness.listenLoopback();
                    defer listener.deinit();

                    var client = try Stream.initSocket(posix.AF.INET);
                    defer client.deinit();
                    try client.connect(listener.addr());

                    var server = try Harness.acceptStream(listener.fd);
                    defer server.deinit();

                    Harness.setSocketBuffer(client.fd, posix.SO.SNDBUF, 4096);
                    Harness.setSocketBuffer(server.fd, posix.SO.SNDBUF, 4096);
                    client.setDeadline(lib.time.milliTimestamp() + 3000);
                    server.setDeadline(lib.time.milliTimestamp() + 3000);

                    const client_send = try a.alloc(u8, 128 * 1024);
                    defer a.free(client_send);
                    const server_send = try a.alloc(u8, 128 * 1024);
                    defer a.free(server_send);
                    const client_recv = try a.alloc(u8, server_send.len);
                    defer a.free(client_recv);
                    const server_recv = try a.alloc(u8, client_send.len);
                    defer a.free(server_recv);

                    test_utils.fillPattern(client_send, 11);
                    test_utils.fillPattern(server_send, 29);

                    var slot = Harness.ErrorSlot{};

                    const client_writer = try Thread.spawn(.{}, struct {
                        fn run(err_slot: *Harness.ErrorSlot, stream: *Stream, buf: []const u8) void {
                            Harness.writeAll(stream, buf) catch |err| err_slot.store(err);
                        }
                    }.run, .{ &slot, &client, client_send });

                    const client_reader = try Thread.spawn(.{}, struct {
                        fn run(err_slot: *Harness.ErrorSlot, stream: *Stream, buf: []u8) void {
                            Harness.readExact(stream, buf) catch |err| err_slot.store(err);
                        }
                    }.run, .{ &slot, &client, client_recv });

                    const server_writer = try Thread.spawn(.{}, struct {
                        fn run(err_slot: *Harness.ErrorSlot, stream: *Stream, buf: []const u8) void {
                            Harness.writeAll(stream, buf) catch |err| err_slot.store(err);
                        }
                    }.run, .{ &slot, &server, server_send });

                    const server_reader = try Thread.spawn(.{}, struct {
                        fn run(err_slot: *Harness.ErrorSlot, stream: *Stream, buf: []u8) void {
                            Harness.readExact(stream, buf) catch |err| err_slot.store(err);
                        }
                    }.run, .{ &slot, &server, server_recv });

                    client_writer.join();
                    client_reader.join();
                    server_writer.join();
                    server_reader.join();

                    if (slot.load()) |err| return err;

                    try testing.expectEqualSlices(u8, server_send, client_recv);
                    try testing.expectEqualSlices(u8, client_send, server_recv);
                }
            };
            Body.call(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}
