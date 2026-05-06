//! Aggregates `TestRunner(comptime grt: type)` entrypoints from `src/*` and display helpers.

const glib = @import("glib");
const embed = @import("embed");

const binding = @import("../src/binding.zig");
const types_mod = @import("../src/types.zig");
const Color = @import("../src/Color.zig");
const Point = @import("../src/Point.zig");
const Area = @import("../src/Area.zig");
const Style = @import("../src/Style.zig");
const Display = @import("../src/Display.zig");
const Indev = @import("../src/Indev.zig");
const Tick = @import("../src/Tick.zig");
const Event = @import("../src/Event.zig");
const Anim = @import("../src/Anim.zig");
const Subject = @import("../src/Subject.zig");
const Observer = @import("../src/Observer.zig");
const Obj = @import("../src/object/Obj.zig");
const Tree = @import("../src/object/Tree.zig");
const Flags = @import("../src/object/Flags.zig");
const State = @import("../src/object/State.zig");
const Label = @import("../src/widget/Label.zig");
const Button = @import("../src/widget/Button.zig");
const Bar = @import("../src/widget/Bar.zig");
const TestingDisplay = @import("integration/bitmap/test_utils/TestingDisplay.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("binding", binding.TestRunner(grt));
            t.run("types", types_mod.TestRunner(grt));
            t.run("Color", Color.TestRunner(grt));
            t.run("Point", Point.TestRunner(grt));
            t.run("Area", Area.TestRunner(grt));
            t.run("Style", Style.TestRunner(grt));
            t.run("Display", Display.TestRunner(grt));
            t.run("Indev", Indev.TestRunner(grt));
            t.run("Tick", Tick.TestRunner(grt));
            t.run("Event", Event.TestRunner(grt));
            t.run("Anim", Anim.TestRunner(grt));
            t.run("Subject", Subject.TestRunner(grt));
            t.run("Observer", Observer.TestRunner(grt));
            t.run("object/Obj", Obj.TestRunner(grt));
            t.run("object/Tree", Tree.TestRunner(grt));
            t.run("object/Flags", Flags.TestRunner(grt));
            t.run("object/State", State.TestRunner(grt));
            t.run("widget/Label", Label.TestRunner(grt));
            t.run("widget/Button", Button.TestRunner(grt));
            t.run("widget/Bar", Bar.TestRunner(grt));
            t.run("display/TestingDisplay", TestingDisplay.TestRunner(grt));

            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = allocator;
            grt.std.testing.allocator.destroy(self);
        }
    };

    const runner = grt.std.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return glib.testing.TestRunner.make(Runner).new(runner);
}
