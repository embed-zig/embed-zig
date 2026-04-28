const builtin = @import("builtin");
const stdz = @import("stdz");
const testing_mod = @import("testing");

pub const thread = @import("stdz/thread.zig");
pub const log = @import("stdz/log.zig");
pub const posix = @import("stdz/posix.zig");
pub const atomic = @import("stdz/atomic.zig");
pub const heap = @import("stdz/heap.zig");
pub const mem = @import("stdz/mem.zig");
pub const fmt = @import("stdz/fmt.zig");
pub const json = @import("stdz/json.zig");
pub const testing_helpers = @import("stdz/testing.zig");
pub const collections = @import("stdz/collections.zig");
pub const crypto = @import("stdz/crypto.zig");
pub const random = @import("stdz/random.zig");

pub fn make(comptime std: type) testing_mod.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_mod.T, allocator: stdz.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.parallel();

            t.run("thread", thread.make(std));
            t.run("log", log.make(std));
            if (builtin.target.os.tag != .windows) {
                t.run("posix", posix.make(std));
            }
            t.run("atomic", atomic.make(std));
            t.run("heap", heap.make(std));
            t.run("mem", mem.make(std));
            t.run("fmt", fmt.make(std));
            t.run("json", json.make(std));
            t.run("testing", testing_helpers.make(std));
            t.run("collections", collections.make(std));
            t.run("crypto", crypto.make(std));
            t.run("random", random.make(std));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = allocator;
            std.testing.allocator.destroy(self);
        }
    };

    const runner = std.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_mod.TestRunner.make(Runner).new(runner);
}
