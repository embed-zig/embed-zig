const embed = @import("embed");
const fd_mod = @import("../../../fd.zig");
const netip = @import("../../../netip.zig");
const testing_api = @import("testing");

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
                    const ReadyCounter = @import("../tcp/test_utils.zig").ReadyCounter(lib);
                    const Listener = fd_mod.Listener(lib);
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

                    var listener = try Listener.init(AddrPort.from4(.{ 127, 0, 0, 1 }, 0), true);
                    defer listener.deinit();
                    try listener.listen(4);

                    var error_slot = ErrorSlot{};
                    var ready = ReadyCounter.init(1);
                    const accept_thread = try Thread.spawn(.{}, struct {
                        fn run(listener_ptr: *Listener, ready_counter: *ReadyCounter, slot: *ErrorSlot) void {
                            ready_counter.markReady();
                            _ = listener_ptr.accept() catch |err| {
                                if (err == error.Closed) return;
                                slot.store(err);
                                return;
                            };
                            slot.store(error.ExpectedAcceptToWakeClosed);
                        }
                    }.run, .{ &listener, &ready, &error_slot });

                    ready.waitUntilReady();
                    listener.close();
                    accept_thread.join();

                    if (error_slot.load()) |err| return err;
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
