const testing_api = @import("testing");

const bidirectional_streaming = @import("cmux/bidirectional_streaming.zig");
const close_reopen_different_dlci = @import("cmux/close_reopen_different_dlci.zig");
const close_reopen_reuse_dlci = @import("cmux/close_reopen_reuse_dlci.zig");
const concurrent_requests = @import("cmux/concurrent_requests.zig");

pub fn make(comptime lib: type, comptime net: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(_: *@This(), _: lib.mem.Allocator) !void {}

        pub fn run(_: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = allocator;

            t.run("concurrentRequests", concurrent_requests.make(lib, net));
            t.run("bidirectionalStreaming", bidirectional_streaming.make(lib, net));
            t.run("closeReopenDifferentDlci", close_reopen_different_dlci.make(lib, net));
            t.run("closeReopenReuseDlci", close_reopen_reuse_dlci.make(lib, net));
            return t.wait();
        }

        pub fn deinit(_: *@This(), _: lib.mem.Allocator) void {}
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
