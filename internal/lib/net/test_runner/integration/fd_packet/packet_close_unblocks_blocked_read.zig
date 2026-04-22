const stdz = @import("stdz");
const fd_mod = @import("../../../fd.zig");
const netip = @import("../../../netip.zig");
const testing_api = @import("testing");
const test_utils = @import("test_utils.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        spawn_config: stdz.Thread.SpawnConfig = .{ .stack_size = 192 * 1024 },

        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            const Body = struct {
                fn call() !void {
                    const Harness = test_utils.Harness(lib);
                    const ReadyCounter = test_utils.ReadyCounter(lib);
                    const Packet = fd_mod.Packet(lib);
                    const AddrPort = netip.AddrPort;
                    const Thread = lib.Thread;

                    const ErrorSlot = struct {
                        mutex: Thread.Mutex = .{},
                        err: ?anyerror = null,

                        fn store(slot: *@This(), err: anyerror) void {
                            slot.mutex.lock();
                            defer slot.mutex.unlock();
                            if (slot.err == null) slot.err = err;
                        }

                        fn load(slot: *@This()) ?anyerror {
                            slot.mutex.lock();
                            defer slot.mutex.unlock();
                            return slot.err;
                        }
                    };

                    var packet = try Harness.bindLoopback(AddrPort.from4(.{ 127, 0, 0, 1 }, 0));
                    defer packet.deinit();

                    var error_slot = ErrorSlot{};
                    var ready = ReadyCounter.init(1);
                    const reader = try Thread.spawn(.{}, struct {
                        fn run(packet_ptr: *Packet, ready_counter: *ReadyCounter, slot: *ErrorSlot) void {
                            var buf: [16]u8 = undefined;
                            ready_counter.markReady();
                            _ = packet_ptr.readFrom(&buf) catch |err| {
                                if (err == error.Closed) return;
                                slot.store(err);
                                return;
                            };
                            slot.store(error.ExpectedPacketReadToWakeClosed);
                        }
                    }.run, .{ &packet, &ready, &error_slot });

                    ready.waitUntilReady();
                    packet.close();
                    reader.join();

                    if (error_slot.load()) |err| return err;
                }
            };

            Body.call() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}
