const glib = @import("glib");

const Color = @import("../Color.zig");
const Frame = @import("../Frame.zig");
const Transition = @import("../Transition.zig");
const Animator = @import("../Animator.zig");
const LedStrip = @import("../LedStrip.zig");
const animator_runner = @import("animator.zig");

pub fn make(comptime lib: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.parallel();
            t.run("Color", Color.TestRunner(lib));
            t.run("Frame", Frame.TestRunner(lib));
            t.run("Transition", Transition.TestRunner(lib));
            t.run("Animator", Animator.TestRunner(lib));
            t.run("LedStrip", LedStrip.TestRunner(lib));
            t.run("animator", animator_runner.make(lib));
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
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
