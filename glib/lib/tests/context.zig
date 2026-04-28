const builtin = @import("builtin");
const stdz = @import("stdz");
const testing_mod = @import("testing");

pub const background = @import("context/background.zig");
pub const bind_fd = @import("context/bind_fd.zig");
pub const cancel_basic = @import("context/cancel_basic.zig");
pub const cancel_cause = @import("context/cancel_cause.zig");
pub const cancel_propagation = @import("context/cancel_propagation.zig");
pub const deadline = @import("context/deadline.zig");
pub const lifecycle = @import("context/lifecycle.zig");
pub const multi_thread = @import("context/multi_thread.zig");
pub const value = @import("context/value.zig");
pub const wait = @import("context/wait.zig");

pub fn make(comptime std: type, comptime time: type) testing_mod.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_mod.T, allocator: stdz.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("background", background.make(std, time));
            if (builtin.target.os.tag != .windows) {
                t.run("bind_fd", bind_fd.make(std, time));
            }
            t.run("cancel/basic", cancel_basic.make(std, time));
            t.run("cancel/cause", cancel_cause.make(std, time));
            t.run("cancel/propagation", cancel_propagation.make(std, time));
            t.run("deadline", deadline.make(std, time));
            t.run("lifecycle", lifecycle.make(std, time));
            t.run("multi_thread", multi_thread.make(std, time));
            t.run("value", value.make(std, time));
            t.run("wait", wait.make(std, time));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_mod.TestRunner.make(Runner).new(&Holder.runner);
}
