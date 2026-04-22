const stdz = @import("stdz");
const net_mod = @import("../../../../net.zig");
const test_utils = @import("../tcp/test_utils.zig");
const testing_api = @import("testing");

pub fn make(comptime lib: type) testing_api.TestRunner {
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
                    const Net = net_mod.make(lib);
                    const ReadyCounter = test_utils.ReadyCounter(lib);
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

                    var pc = try Net.listenPacket(.{
                        .allocator = a,
                        .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0),
                    });
                    defer pc.deinit();

                    var error_slot = ErrorSlot{};
                    var ready = ReadyCounter.init(1);
                    const read_thread = try Thread.spawn(.{}, struct {
                        fn run(pc_value: net_mod.PacketConn, ready_counter: *ReadyCounter, slot: *ErrorSlot) void {
                            var buf: [16]u8 = undefined;
                            ready_counter.markReady();
                            _ = pc_value.readFrom(&buf) catch |err| {
                                if (err == error.Closed) return;
                                slot.store(err);
                                return;
                            };
                            slot.store(error.ExpectedPacketConnReadToWakeClosed);
                        }
                    }.run, .{ pc, &ready, &error_slot });

                    ready.waitUntilReady();
                    pc.close();
                    read_thread.join();

                    if (error_slot.load()) |err| return err;
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
