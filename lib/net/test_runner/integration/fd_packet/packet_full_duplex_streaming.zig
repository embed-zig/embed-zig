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
            _ = allocator;
            const Body = struct {
                fn call() !void {
                    const Harness = test_utils.Harness(lib);
                    const Packet = fd_mod.Packet(lib);
                    const AddrPort = netip.AddrPort;
                    const Thread = lib.Thread;
                    const testing = lib.testing;
                    var a = try Harness.bindLoopback(AddrPort.from4(.{ 127, 0, 0, 1 }, 0));
                    defer a.deinit();
                    var b = try Harness.bindLoopback(AddrPort.from4(.{ 127, 0, 0, 1 }, 0));
                    defer b.deinit();

                    const a_addr = try Harness.localAddr(&a);
                    const b_addr = try Harness.localAddr(&b);
                    try a.connect(b_addr);
                    try b.connect(a_addr);

                    a.setDeadline(lib.time.milliTimestamp() + 1500);
                    b.setDeadline(lib.time.milliTimestamp() + 1500);

                    const a_writer = try Thread.spawn(.{}, struct {
                        fn run(packet: *Packet) void {
                            var i: usize = 0;
                            while (i < 64) : (i += 1) {
                                var msg: [16]u8 = undefined;
                                const len = Harness.makeIndexedMessage(&msg, 'a', i);
                                _ = packet.write(msg[0..len]) catch return;
                            }
                        }
                    }.run, .{&a});
                    defer a_writer.join();

                    const b_writer = try Thread.spawn(.{}, struct {
                        fn run(packet: *Packet) void {
                            var i: usize = 0;
                            while (i < 64) : (i += 1) {
                                var msg: [16]u8 = undefined;
                                const len = Harness.makeIndexedMessage(&msg, 'b', i);
                                _ = packet.write(msg[0..len]) catch return;
                            }
                        }
                    }.run, .{&b});
                    defer b_writer.join();

                    var a_recv: usize = 0;
                    var b_recv: usize = 0;
                    var buf: [16]u8 = undefined;
                    while (a_recv < 64 or b_recv < 64) {
                        if (a_recv < 64) {
                            const n = try a.read(&buf);
                            try testing.expectEqual(@as(u8, 'b'), buf[0]);
                            try testing.expect(n >= 2);
                            a_recv += 1;
                        }
                        if (b_recv < 64) {
                            const n = try b.read(&buf);
                            try testing.expectEqual(@as(u8, 'a'), buf[0]);
                            try testing.expect(n >= 2);
                            b_recv += 1;
                        }
                    }
                }
            };
            Body.call() catch |err| {
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
