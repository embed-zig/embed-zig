const embed = @import("embed");
const fd_mod = @import("../../../fd.zig");
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
                    var listener = try Harness.listenLoopback();
                    defer listener.deinit();

                    var stream = try Stream.initSocket(posix.AF.INET);
                    defer stream.deinit();
                    try stream.connect(listener.addr());

                    const peer = try Harness.accept(listener.fd);
                    defer posix.close(peer);

                    Harness.setSocketBuffer(stream.fd, posix.SO.SNDBUF, 4096);

                    const payload = try a.alloc(u8, 512 * 1024);
                    defer a.free(payload);
                    @memset(payload, 'w');

                    const reader = try Thread.spawn(.{}, struct {
                        fn run(fd: posix.socket_t, expected: usize, comptime thread_lib: type) void {
                            thread_lib.Thread.sleep(40 * thread_lib.time.ns_per_ms);

                            var received: usize = 0;
                            var buf: [4096]u8 = undefined;
                            while (received < expected) {
                                const n = thread_lib.posix.recv(fd, &buf, 0) catch break;
                                if (n == 0) break;
                                received += n;
                            }
                        }
                    }.run, .{ peer, payload.len, lib });
                    defer reader.join();

                    stream.setWriteDeadline(lib.time.milliTimestamp() + 1000);
                    try Harness.writeAll(&stream, payload);
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
