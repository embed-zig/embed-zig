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
                fn waitUntilAcceptWaiting(listener: *net.TcpListener, comptime thread_lib: type) void {
                    while (true) {
                        listener.state_mu.lock();
                        const waiting = listener.accept_waiting;
                        listener.state_mu.unlock();
                        if (waiting) return;
                        thread_lib.Thread.sleep(@intCast(net.time.duration.MilliSecond));
                    }
                }

                fn call(a: std.mem.Allocator) !void {
                    const Net = net;
                    const ReadyCounter = test_utils.ReadyCounter(std);
                    const Thread = std.Thread;

                    var ln = try Net.listen(a, .{ .address = test_utils.addr4(.{ 127, 0, 0, 1 }, 0) });
                    defer ln.deinit();

                    const listener = try ln.as(Net.TcpListener);
                    var ready = ReadyCounter.init(1);
                    var accept_err: ?anyerror = null;

                    const accept_thread = try Thread.spawn(.{}, struct {
                        fn run(listener_ptr: *Net.TcpListener, ready_counter: *ReadyCounter, err_slot: *?anyerror) void {
                            ready_counter.markReady();
                            var conn = listener_ptr.accept() catch |err| {
                                if (err == error.Closed) return;
                                err_slot.* = err;
                                return;
                            };
                            conn.deinit();
                            err_slot.* = error.ExpectedAcceptToWakeClosed;
                        }
                    }.run, .{ listener, &ready, &accept_err });

                    ready.waitUntilReady();
                    waitUntilAcceptWaiting(listener, std);
                    listener.close();
                    accept_thread.join();

                    if (accept_err) |err| return err;
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
