const embed = @import("embed");
const testing_mod = @import("testing");

pub const background = @import("context/background.zig");
pub const cancel_basic = @import("context/cancel_basic.zig");
pub const cancel_cause = @import("context/cancel_cause.zig");
pub const cancel_propagation = @import("context/cancel_propagation.zig");
pub const deadline = @import("context/deadline.zig");
pub const lifecycle = @import("context/lifecycle.zig");
pub const multi_thread = @import("context/multi_thread.zig");
pub const value = @import("context/value.zig");
pub const wait = @import("context/wait.zig");

pub fn make(comptime lib: type) testing_mod.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_mod.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("background", background.make(lib));
            t.run("cancel/basic", cancel_basic.make(lib));
            t.run("cancel/cause", cancel_cause.make(lib));
            t.run("cancel/propagation", cancel_propagation.make(lib));
            t.run("deadline", deadline.make(lib));
            t.run("lifecycle", lifecycle.make(lib));
            t.run("multi_thread", multi_thread.make(lib));
            t.run("value", value.make(lib));
            t.run("wait", wait.make(lib));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_mod.TestRunner.make(Runner).new(&Holder.runner);
}
