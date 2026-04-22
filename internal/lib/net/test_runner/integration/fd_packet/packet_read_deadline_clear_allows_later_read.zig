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
                    var receiver = try Harness.bindLoopback(AddrPort.from4(.{ 127, 0, 0, 1 }, 0));
                    defer receiver.deinit();
                    var sender = try Harness.bindLoopback(AddrPort.from4(.{ 127, 0, 0, 1 }, 0));
                    defer sender.deinit();

                    receiver.setReadDeadline(lib.time.milliTimestamp() + 20);
                    var buf: [8]u8 = undefined;
                    try testing.expectError(error.TimedOut, receiver.readFrom(&buf));

                    receiver.setReadDeadline(null);
                    const dest = try Harness.localAddr(&receiver);
                    const writer = try Thread.spawn(.{}, struct {
                        fn run(packet: *Packet, addr: AddrPort, comptime thread_lib: type) void {
                            thread_lib.Thread.sleep(30 * thread_lib.time.ns_per_ms);
                            _ = packet.writeTo("after", addr) catch {};
                        }
                    }.run, .{ &sender, dest, lib });
                    defer writer.join();

                    const recv = try receiver.readFrom(&buf);
                    try testing.expectEqualStrings("after", buf[0..recv.bytes_read]);
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
