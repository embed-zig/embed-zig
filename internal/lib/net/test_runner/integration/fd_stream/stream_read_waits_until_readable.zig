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
                    const Stream = fd_mod.Stream(lib);
                    const posix = lib.posix;
                    const Thread = lib.Thread;
                    const testing = lib.testing;
                    var listener = try Harness.listenLoopback();
                    defer listener.deinit();

                    var stream = try Stream.initSocket(posix.AF.INET);
                    defer stream.deinit();
                    try stream.connect(listener.addr());

                    const peer = try Harness.accept(listener.fd);
                    defer posix.close(peer);

                    const writer = try Thread.spawn(.{}, struct {
                        fn run(fd: posix.socket_t, comptime thread_lib: type) void {
                            thread_lib.Thread.sleep(30 * thread_lib.time.ns_per_ms);
                            _ = thread_lib.posix.send(fd, "ping", 0) catch {};
                        }
                    }.run, .{ peer, lib });
                    defer writer.join();

                    var buf: [8]u8 = undefined;
                    const n = try stream.read(&buf);
                    try testing.expectEqual(@as(usize, 4), n);
                    try testing.expectEqualStrings("ping", buf[0..n]);
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
