const embed = @import("embed");
const testing_api = @import("testing");
const net_mod = @import("../../../../net.zig");
const test_utils = @import("test_utils.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        spawn_config: embed.Thread.SpawnConfig = .{ .stack_size = 1024 * 1024 },

        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            const Body = struct {
                fn call(a: lib.mem.Allocator) !void {
                    const Net = net_mod.make(lib);
                    try test_utils.runLoopbackCase(
                        lib,
                        a,
                        Net,
                        .tls_1_2,
                        .tls_1_2,
                        .tls_1_2,
                        .TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
                        null,
                        null,
                    );
                    try test_utils.runLoopbackCase(lib, a, Net, .tls_1_2, .tls_1_3, .tls_1_3, null, null, null);
                    try test_utils.runLoopbackCase(lib, a, Net, .tls_1_3, .tls_1_3, .tls_1_3, null, null, null);
                }
            };
            Body.call(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
