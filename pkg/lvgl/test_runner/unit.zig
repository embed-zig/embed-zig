//! Aggregates `TestRunner(comptime lib: type)` entrypoints from `src/*` and display helpers.

const embed = @import("embed");
const testing = @import("testing");

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
const TestingDisplay = @import("integration/bitmap/test_utils/TestingDisplay.zig").TestingDisplay;

pub fn make(comptime lib: type) testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("binding", binding.TestRunner(lib));
            t.run("types", types_mod.TestRunner(lib));
            t.run("Color", Color.TestRunner(lib));
            t.run("Point", Point.TestRunner(lib));
            t.run("Area", Area.TestRunner(lib));
            t.run("Style", Style.TestRunner(lib));
            t.run("Display", Display.TestRunner(lib));
            t.run("Indev", Indev.TestRunner(lib));
            t.run("Tick", Tick.TestRunner(lib));
            t.run("Event", Event.TestRunner(lib));
            t.run("Anim", Anim.TestRunner(lib));
            t.run("Subject", Subject.TestRunner(lib));
            t.run("Observer", Observer.TestRunner(lib));
            t.run("object/Obj", Obj.TestRunner(lib));
            t.run("object/Tree", Tree.TestRunner(lib));
            t.run("object/Flags", Flags.TestRunner(lib));
            t.run("object/State", State.TestRunner(lib));
            t.run("widget/Label", Label.TestRunner(lib));
            t.run("widget/Button", Button.TestRunner(lib));
            t.run("display/TestingDisplay", TestingDisplay.TestRunner(lib));

            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing.TestRunner.make(Runner).new(runner);
}
