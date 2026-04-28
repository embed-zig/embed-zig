//! Bitmap integration runner — aggregates per-case bitmap checks.

const glib = @import("glib");
const embed = @import("embed");
const display_api = embed.drivers;
const CaseRunner = @import("bitmap/test_utils/CaseRunner.zig");
const basic = @import("bitmap/basic.zig");
const label = @import("bitmap/label.zig");
const button = @import("bitmap/button.zig");
const anim = @import("bitmap/anim.zig");

const Display = display_api.Display;

pub fn make(comptime grt: type, output: ?*Display) glib.testing.TestRunner {
    const Runner = struct {
        output: ?*Display,

        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = allocator;

            t.run("basic", CaseRunner.make(grt, basic.Case, .{}, self.output));
            t.run("label", CaseRunner.make(grt, label.Case, .{}, self.output));
            t.run("button", CaseRunner.make(grt, button.Case, .{}, self.output));
            t.run("anim", CaseRunner.make(grt, anim.Case, .{}, self.output));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = allocator;
            grt.std.testing.allocator.destroy(self);
        }
    };

    const runner = grt.std.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{ .output = output };
    return glib.testing.TestRunner.make(Runner).new(runner);
}
