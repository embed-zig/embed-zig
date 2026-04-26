const glib = @import("glib");

const Color = @import("../Color.zig");
const Frame = @import("../Frame.zig");
const Transition = @import("../Transition.zig");
const Animator = @import("../Animator.zig");
const LedStrip = @import("../LedStrip.zig");
const animator_runner = @import("animator.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.parallel();
            t.run("Color", Color.TestRunner(grt));
            t.run("Frame", Frame.TestRunner(grt));
            t.run("Transition", Transition.TestRunner(grt));
            t.run("Animator", Animator.TestRunner(grt));
            t.run("LedStrip", LedStrip.TestRunner(grt));
            t.run("animator", animator_runner.make(grt));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
