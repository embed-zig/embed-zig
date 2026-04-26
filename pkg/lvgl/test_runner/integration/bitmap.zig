//! Bitmap integration runner — aggregates per-case bitmap checks.

const display_api = @import("drivers");
const embed = @import("embed");
const testing = @import("testing");
const CaseRunner = @import("bitmap/test_utils/CaseRunner.zig");
const basic = @import("bitmap/basic.zig");
const label = @import("bitmap/label.zig");
const button = @import("bitmap/button.zig");
const anim = @import("bitmap/anim.zig");

const Display = display_api.Display;

pub fn make(comptime lib: type, output: ?*Display) testing.TestRunner {
    const Runner = struct {
        output: ?*Display,

        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing.T, allocator: embed.mem.Allocator) bool {
            _ = allocator;

            t.run("basic", CaseRunner.make(lib, basic.Case, .{}, self.output));
            t.run("label", CaseRunner.make(lib, label.Case, .{}, self.output));
            t.run("button", CaseRunner.make(lib, button.Case, .{}, self.output));
            t.run("anim", CaseRunner.make(lib, anim.Case, .{}, self.output));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{ .output = output };
    return testing.TestRunner.make(Runner).new(runner);
}
