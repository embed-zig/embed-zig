const embed = @import("embed");
const testing_mod = @import("testing");

pub const thread = @import("embed/thread.zig");
pub const log = @import("embed/log.zig");
pub const posix = @import("embed/posix.zig");
pub const time = @import("embed/time.zig");
pub const atomic = @import("embed/atomic.zig");
pub const mem = @import("embed/mem.zig");
pub const fmt = @import("embed/fmt.zig");
pub const json = @import("embed/json.zig");
pub const testing_helpers = @import("embed/testing.zig");
pub const collections = @import("embed/collections.zig");
pub const crypto = @import("embed/crypto.zig");
pub const random = @import("embed/random.zig");

pub fn make(comptime lib: type) testing_mod.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_mod.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.parallel();

            t.run("thread", thread.make(lib));
            t.run("log", log.make(lib));
            t.run("posix", posix.make(lib));
            t.run("time", time.make(lib));
            t.run("atomic", atomic.make(lib));
            t.run("mem", mem.make(lib));
            t.run("fmt", fmt.make(lib));
            t.run("json", json.make(lib));
            t.run("testing", testing_helpers.make(lib));
            t.run("collections", collections.make(lib));
            t.run("crypto", crypto.make(lib));
            t.run("random", random.make(lib));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_mod.TestRunner.make(Runner).new(runner);
}
