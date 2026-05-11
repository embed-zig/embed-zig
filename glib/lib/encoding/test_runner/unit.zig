const base64 = @import("../base64.zig");
const base32 = @import("../base32.zig");
const base58 = @import("../base58.zig");

pub fn make(comptime lib: type) @import("testing").TestRunner {
    const testing_api = @import("testing");

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("base64", base64.TestRunner(lib));
            t.run("base58/btc", base58.btc.TestRunner(lib));
            t.run("base32/crockford", base32.crockford.TestRunner(lib));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
